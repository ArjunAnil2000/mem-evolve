"""Main evolution loop.

One code path for both modes:

  - `workers = []`   →  LocalWorker only, `num_branches = 1`  (serial, single
                        machine — matches "just evaluate on the current
                        machine").
  - `workers = [...]` → one HTTPWorker per entry, `num_branches` defaults
                        to len(workers).

Per round, each branch runs in its own thread; the branch's worker does
the compile + benchmark. The main thread collects BranchStepResults and
mutates the EvolutionTree sequentially. Every `checkpoint_interval`
rounds a smart-LLM frontier review reshapes the branch set.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Dict, List, Optional

from evaluator import compile_policy
from evolution.branch import (
    Branch, BranchStepResult, make_branch, step_branch,
)
from evolution.frontier import run_frontier_checkpoint
from evolution.normalization import NormalizationState, extract_raw_values
from evolution.planner import load_seeds, pick_seeds
from evolution.tree import EvolutionTree
from evolution.worker import Worker, build_workers
from llm_adapter import create_llm_client

try:
    from tqdm import tqdm
    _HAVE_TQDM = True
except ImportError:                           # pragma: no cover
    _HAVE_TQDM = False

log = logging.getLogger(__name__)


def _read(path: str) -> str:
    with open(path) as f:
        return f.read()


def _choose_branches(
    cfg: Dict[str, Any],
    tree: EvolutionTree,
    seeds_dir: str,
    num_branches: int,
    client_planner: Any,
    planner_model: str,
    planner_temp: float,
    workload_description: str,
) -> List[Branch]:
    """Run planner → create K seed root nodes in the tree → K Branches."""
    use_planner = cfg.get("use_planner", True)
    seeds = load_seeds(seeds_dir)
    # Don't let the planner pick the calibration baseline as an evolution seed —
    # it has nothing meaningful to mutate from.
    baseline = cfg.get("calibrate_baseline")
    if baseline:
        seeds = {k: v for k, v in seeds.items() if k != baseline}

    if use_planner:
        log.info("Running planner to pick %d branches…", num_branches)
        assignments = pick_seeds(
            client_planner, planner_model, planner_temp,
            workload_description, seeds_dir, num_branches,
        )
    else:
        # Config-provided seeds list, cycled to K.
        names = list(cfg.get("seeds") or seeds.keys())
        if not names:
            raise RuntimeError("no seeds configured and planner disabled")
        from evolution.planner import BranchAssignment
        assignments = [
            BranchAssignment(
                seed=names[i % len(names)],
                rationale="(planner disabled)",
                focus_hint="Propose a small, well-motivated change to the seed.",
            )
            for i in range(num_branches)
        ]

    branches: List[Branch] = []
    for i, a in enumerate(assignments):
        code = seeds.get(a.seed)
        if code is None:
            raise RuntimeError(f"planner/config asked for missing seed '{a.seed}'")
        root = tree.add_node(
            parent_id=None,
            code=code,
            score=0.0,
            details={},
            error="",
            strategy="seed",
            mutation_description=f"seed={a.seed}; {a.rationale}",
            seed_origin=a.seed,
            round_num=0,
        )
        branches.append(make_branch(i, root, focus_hint=a.focus_hint))
        log.info("  b%d ← seed=%s  hint=%s", i, a.seed, a.focus_hint[:80])
    return branches


def _progress_iter(it, *, total: int, desc: str):
    """Wrap an iterator with a tqdm bar if tqdm is installed."""
    if not _HAVE_TQDM:
        return it
    return tqdm(
        it, total=total, desc=desc, leave=False,
        bar_format="  {desc} |{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )


def _load_norm_state(cfg: Dict[str, Any], path: Path) -> NormalizationState:
    """Load persistent normalization state, or build a fresh one from cfg."""
    scoring = cfg.get("scoring", {}) or {}
    existing = NormalizationState.load(str(path))
    if existing is not None:
        # Honor cfg overrides for squash / min_n on resume.
        if "squash" in scoring:
            existing.squash = scoring["squash"]
        if "min_n" in scoring:
            existing.min_n = int(scoring["min_n"])
        return existing
    return NormalizationState(
        squash=scoring.get("squash", "tanh"),
        min_n=int(scoring.get("min_n", 2)),
    )


def _normalized_score(
    norm: NormalizationState,
    eval_dict: Dict[str, Any],
    weights: Dict[str, float],
) -> Dict[str, Any]:
    """Score one EvaluationResult dict using the running norm state.

    Returns the same dict shape as `NormalizationState.score`. If the eval
    failed (no probes, error string), returns score=0.0 and empty components.
    """
    if not eval_dict.get("ok"):
        return {"score": 0.0, "components": {}, "skipped": []}
    probes = eval_dict.get("probes") or {}
    return norm.score(probes, weights)


def calibrate(cfg: Dict[str, Any], n_runs: int) -> Dict[str, Dict[str, Any]]:
    """Run each seed `n_runs` times to seed NormalizationState — no LLM, no tree.

    Compiles each seed once, then dispatches the compiled binary across all
    workers in a round-robin fashion. Persists `<output_dir>/normalization.json`.

    Returns `{seed_name: {"attempted": int, "succeeded": int, "errors": [str]}}`
    so callers (the auto-calibration path in `evolve()`) can fail fast if the
    workload itself is broken before burning LLM credits.
    """
    if n_runs < 1:
        raise ValueError("calibrate requires n_runs >= 1")

    output_dir = Path(cfg["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    norm_path = output_dir / "normalization.json"

    workers: List[Worker] = build_workers(cfg)
    log.info("Calibration workers: %s", [w.name for w in workers])

    seeds_dir = cfg.get("seeds_dir") or str(Path(__file__).parent.parent / "seeds")
    seeds = load_seeds(seeds_dir)
    if not seeds:
        raise RuntimeError(f"no seeds found in {seeds_dir}")

    # Restrict to the configured baseline seed (preferred — frozen baseline
    # against vanilla Linux), or to a list, or fall back to the full seed set.
    baseline = cfg.get("calibrate_baseline")
    if baseline:
        if baseline not in seeds:
            raise RuntimeError(
                f"calibrate_baseline={baseline!r} not found in {seeds_dir}"
            )
        seeds = {baseline: seeds[baseline]}
    else:
        requested = cfg.get("calibrate_seeds") or cfg.get("seeds")
        if requested:
            seeds = {k: v for k, v in seeds.items() if k in requested}
            if not seeds:
                raise RuntimeError(f"calibrate_seeds={requested} matched no seeds")

    log.info("Calibrating across %d seed(s) × %d run(s) = %d evaluations",
             len(seeds), n_runs, len(seeds) * n_runs)

    norm_state = _load_norm_state(cfg, norm_path)
    policies_dir = os.path.join(cfg["source_dir"], "policies")
    binary_cache_dir = output_dir / "calibration_binaries"
    binary_cache_dir.mkdir(parents=True, exist_ok=True)
    benchmark = cfg["benchmark"]
    timeout = int(cfg.get("timeout", 180))

    # Compile each seed once.
    snapshots: Dict[str, str] = {}
    compile_lock = threading.Lock()
    for seed_name, seed_code in seeds.items():
        with compile_lock:
            cres = compile_policy(seed_code, policies_dir)
        if not cres.ok or not cres.binary_path:
            log.warning("seed %s failed to compile: %s — skipping",
                        seed_name, cres.error)
            continue
        snap = str(binary_cache_dir / f"{seed_name}.out")
        shutil.copy2(cres.binary_path, snap)
        os.chmod(snap, 0o755)
        snapshots[seed_name] = snap

    if not snapshots:
        raise RuntimeError("no seeds compiled — cannot calibrate")

    # Build the (seed, run_idx, worker) job list.
    jobs = []
    for run_idx in range(n_runs):
        for i, (seed_name, snap) in enumerate(snapshots.items()):
            w = workers[(run_idx * len(snapshots) + i) % len(workers)]
            jobs.append((seed_name, run_idx, snap, w))

    print(f"\n{'='*60}\n  Calibration: {len(jobs)} runs across {len(workers)} worker(s)\n{'='*60}")

    # Per-run log — one JSON object per line. Truncated at the start of every
    # calibrate() call so it always reflects the most recent calibration. Use
    # `jq` or a quick python one-liner to inspect distribution / outliers /
    # per-worker bimodality after the run.
    runs_log_path = output_dir / "calibration_runs.jsonl"
    runs_log_path.write_text("")  # truncate
    runs_log_lock = threading.Lock()
    all_runs: List[Dict[str, Any]] = []

    def _run_one(seed_name: str, run_idx: int, snap: str, w: Worker):
        try:
            return seed_name, run_idx, w.name, w.evaluate(snap, benchmark, timeout)
        except Exception as e:
            return seed_name, run_idx, w.name, {
                "ok": False, "error": f"worker crashed: {e}",
                "score": 0.0, "wallclock_sec": 0.0, "probes": {},
                "stdout_tail": "", "stderr_tail": "",
            }

    per_seed: Dict[str, Dict[str, Any]] = {
        sn: {"attempted": 0, "succeeded": 0, "errors": []}
        for sn in snapshots
    }
    completed = 0
    successes = 0
    with ThreadPoolExecutor(max_workers=len(workers)) as pool:
        futures = [
            pool.submit(_run_one, sn, ri, snap, w)
            for sn, ri, snap, w in jobs
        ]
        iterator = _progress_iter(
            as_completed(futures), total=len(futures), desc="calibrate",
        )
        for fut in iterator:
            seed_name, run_idx, worker_name, eval_dict = fut.result()
            completed += 1
            per_seed[seed_name]["attempted"] += 1
            if eval_dict.get("ok"):
                successes += 1
                per_seed[seed_name]["succeeded"] += 1
                norm_state.update(extract_raw_values(eval_dict.get("probes") or {}))
                # Persist incrementally so a Ctrl-C still leaves usable state.
                norm_state.save(str(norm_path))
            else:
                err = eval_dict.get("error", "?")
                per_seed[seed_name]["errors"].append(err)
                log.warning("[calibrate] %s run %d on %s failed: %s",
                            seed_name, run_idx, worker_name, err)

            # Build a compact per-run record. Keep probe values + summaries
            # but drop verbose details so the JSONL stays grep-friendly.
            probes = eval_dict.get("probes") or {}
            probe_summary = {
                name: {
                    "value": p.get("value", 0.0),
                    "unit": p.get("unit", ""),
                    "summary": p.get("summary", ""),
                }
                for name, p in probes.items()
            }
            record = {
                "seed": seed_name,
                "run_idx": run_idx,
                "worker": worker_name,
                "ok": bool(eval_dict.get("ok")),
                "error": eval_dict.get("error", ""),
                "score": eval_dict.get("score", 0.0),
                "wallclock_sec": eval_dict.get("wallclock_sec", 0.0),
                "probes": probe_summary,
            }
            all_runs.append(record)
            with runs_log_lock:
                with open(runs_log_path, "a") as f:
                    f.write(json.dumps(record) + "\n")

    print(f"\n  Calibration complete: {successes}/{completed} runs succeeded")
    print(f"  Per-seed:")
    for sn, s in sorted(per_seed.items()):
        marker = "ok " if s["succeeded"] > 0 else "FAIL"
        print(f"    [{marker}] {sn:14s}  {s['succeeded']}/{s['attempted']}")

    # Per-run table: seed, run_idx, worker, ok, score, wall, and each probe
    # value. Sorted by (seed, run_idx) so successive lines for the same
    # baseline are easy to eyeball-diff.
    probe_names = sorted({n for r in all_runs for n in r["probes"]})
    if all_runs:
        print(f"  Per-run probe values (logged to {runs_log_path}):")
        header = f"    {'seed':12s} {'run':>3s} {'worker':28s} {'ok':>3s} {'wall':>7s}"
        for pn in probe_names:
            header += f" {pn:>20s}"
        print(header)
        for r in sorted(all_runs, key=lambda x: (x["seed"], x["run_idx"])):
            row = (
                f"    {r['seed']:12s} {r['run_idx']:>3d} "
                f"{r['worker'][:28]:28s} {('Y' if r['ok'] else 'N'):>3s} "
                f"{r['wallclock_sec']:>7.2f}"
            )
            for pn in probe_names:
                v = r["probes"].get(pn, {}).get("value", float("nan"))
                row += f" {v:>20.3f}"
            print(row)

        # Per-(seed, worker) cluster stats — surfaces machine-specific
        # outliers (one host slower / hotter / different disk).
        print(f"  Per-seed × worker stats:")
        groups: Dict[tuple, List[Dict[str, Any]]] = {}
        for r in all_runs:
            if not r["ok"]:
                continue
            groups.setdefault((r["seed"], r["worker"]), []).append(r)
        for (sn, wn), rs in sorted(groups.items()):
            line = f"    {sn:12s} on {wn[:28]:28s}  n={len(rs):2d}"
            for pn in probe_names:
                vals = [r["probes"].get(pn, {}).get("value") for r in rs
                        if isinstance(r["probes"].get(pn, {}).get("value"), (int, float))]
                if not vals:
                    continue
                m = sum(vals) / len(vals)
                if len(vals) > 1:
                    var = sum((v - m) ** 2 for v in vals) / (len(vals) - 1)
                    sd = var ** 0.5
                else:
                    sd = 0.0
                line += f"  {pn}: μ={m:.3g} σ={sd:.3g}"
            print(line)

    print(f"  Per-probe stats:")
    for name, w in sorted(norm_state.probes.items()):
        print(f"    - {name:20s}  n={w.n:3d}  μ={w.mean:14.3f}  σ={w.stddev:14.3f}")
    print(f"  Saved: {norm_path}")
    print(f"  Per-run log: {runs_log_path}")
    return per_seed


def evolve(cfg: Dict[str, Any]) -> None:
    # ---- Paths & output ----
    output_dir = Path(cfg["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    tree_path = output_dir / cfg.get("tree_file", "evolution_tree.json")
    norm_path = output_dir / "normalization.json"

    # ---- LLM clients (mutator + planner) ----
    mutator_cfg = cfg["llm"]["mutator"]
    planner_cfg = cfg["llm"].get("planner") or mutator_cfg
    mutator_client = create_llm_client(mutator_cfg)
    planner_client = (
        mutator_client if planner_cfg is mutator_cfg
        else create_llm_client(planner_cfg)
    )

    # ---- System prompt for mutator branches ----
    prompt_path = cfg.get("mutator_prompt") or str(
        Path(__file__).parent / "prompts" / "mutator.txt"
    )
    mutator_prompt = _read(prompt_path)

    # ---- Workers ----
    workers: List[Worker] = build_workers(cfg)
    log.info("Workers: %s", [w.name for w in workers])

    # ---- Normalization (z-score + tanh squash, persisted) ----
    norm_state = _load_norm_state(cfg, norm_path)
    scoring_cfg = cfg.get("scoring", {}) or {}
    weights = scoring_cfg.get("weights") or {
        "cgroup_iostat": 1.0, "cgroup_memstat": 0.5, "wallclock": 0.5,
    }
    # Frozen baseline (default): calibrate against a fixed reference (typically
    # the noop / default-Linux seed) and never update stats during evolution,
    # so scores stay comparable across rounds. Set update_during_evolution=true
    # to restore the original "running stats" behavior.
    update_during_evolution = bool(scoring_cfg.get("update_during_evolution", False))
    log.info(
        "Normalization: squash=%s min_n=%d weights=%s pre-loaded probes=%d "
        "update_during_evolution=%s",
        norm_state.squash, norm_state.min_n, weights, len(norm_state.probes),
        update_during_evolution,
    )

    # ---- Auto-calibration: run each seed N times before evolution ----
    # Doubles as a workload health check — if any seed crashes, abort before
    # burning LLM credits on a broken benchmark.
    auto_calibrate = bool(cfg.get("auto_calibrate", True))
    n_calib = int(cfg.get("calibrate_runs", 3))
    have_state = bool(norm_state.probes) and min(
        (w.n for w in norm_state.probes.values()), default=0
    ) >= n_calib
    if auto_calibrate and not have_state:
        print(f"\n  Auto-calibrating ({n_calib} runs/seed) — also smoke-tests "
              f"the workload before evolution starts.")
        per_seed = calibrate(cfg, n_calib)
        crashed = [sn for sn, s in per_seed.items() if s["succeeded"] == 0]
        if crashed:
            sample = per_seed[crashed[0]]["errors"][:1]
            raise RuntimeError(
                f"Calibration: seeds with zero successful runs: {crashed}. "
                f"The workload appears broken — refusing to start evolution. "
                f"First error from {crashed[0]}: {sample}"
            )
        # Reload — calibrate() persists incrementally and we want to see
        # any updates that happened after our initial _load_norm_state.
        norm_state = _load_norm_state(cfg, norm_path)
    elif auto_calibrate:
        log.info("Skipping auto-calibration: existing state has ≥%d samples/probe",
                 n_calib)

    evo_cfg = cfg.get("evolution", {}) or {}
    num_branches = int(
        evo_cfg.get("num_branches") or len(workers)
    )
    checkpoint_interval = int(evo_cfg.get("checkpoint_interval", 5))
    max_spawn = int(evo_cfg.get("max_spawn", 2))
    top_k = int(evo_cfg.get("top_k_for_checkpoint", 10))
    checkpoint_temp = float(evo_cfg.get("checkpoint_temperature", 0.5))

    # ---- Tree / resume ----
    seeds_dir = cfg.get("seeds_dir") or str(Path(__file__).parent.parent / "seeds")
    workload_description = cfg.get("workload_description") or (
        "(no workload description provided)"
    )

    if tree_path.exists() and cfg.get("resume"):
        log.info("Resuming from %s", tree_path)
        tree = EvolutionTree.load(str(tree_path))
        # Re-derive branches from the last-saved set of frontier leaves.
        leaves = tree.get_frontier()[:num_branches]
        branches = [
            make_branch(i, n, focus_hint="(resumed)") for i, n in enumerate(leaves)
        ] or _choose_branches(
            cfg, tree, seeds_dir, num_branches,
            planner_client, planner_cfg["model"],
            float(planner_cfg.get("temperature", 0.5)),
            workload_description,
        )
    else:
        tree = EvolutionTree(metadata={"llm": cfg["llm"], "mode": "parallel"})
        branches = _choose_branches(
            cfg, tree, seeds_dir, num_branches,
            planner_client, planner_cfg["model"],
            float(planner_cfg.get("temperature", 0.5)),
            workload_description,
        )

    next_branch_idx = num_branches
    best_score = (
        tree.nodes[tree.best_node_id].score if tree.best_node_id else float("-inf")
    )

    # ---- Round loop ----
    rounds = int(cfg["rounds"])
    timeout = int(cfg["timeout"])
    benchmark = cfg["benchmark"]
    mutator_model = mutator_cfg["model"]
    mutator_temp = float(mutator_cfg.get("temperature", 0.85))

    # Cache seed codes for the initial prompts (planner already read them;
    # re-reading the file is still easy and keeps branch.step_branch simple).
    all_seeds = load_seeds(seeds_dir)

    # Compile serialisation + binary snapshot cache. All branches share the
    # single `cache_ext/policies/` dir on the coordinator, so compile must
    # hold a lock; once compiled, the .out is snapshotted to a per-round
    # path so the worker can run it independently.
    compile_lock = threading.Lock()
    policies_dir = os.path.join(cfg["source_dir"], "policies")
    binary_cache_dir = str(output_dir / "binaries")

    for round_num in range(1, rounds + 1):
        print(f"\n{'='*60}")
        print(f"  Round {round_num}/{rounds}  |  {len(branches)} branches")
        print(f"{'='*60}")

        assignments = [
            (b, workers[i % len(workers)]) for i, b in enumerate(branches)
        ]

        results: List[BranchStepResult] = []
        with ThreadPoolExecutor(max_workers=len(branches)) as pool:
            futures = {}
            for b, w in assignments:
                seed_code = all_seeds.get(b.seed_origin, "")
                fut = pool.submit(
                    step_branch,
                    b, tree,
                    round_num=round_num,
                    client=mutator_client,
                    model=mutator_model,
                    system_prompt=mutator_prompt,
                    temperature=mutator_temp,
                    seed_code=seed_code,
                    seed_name=b.seed_origin,
                    worker=w,
                    benchmark_script=benchmark,
                    timeout=timeout,
                    policies_dir=policies_dir,
                    compile_lock=compile_lock,
                    binary_cache_dir=binary_cache_dir,
                )
                futures[fut] = b

            iterator = _progress_iter(
                as_completed(futures),
                total=len(futures),
                desc=f"round {round_num}/{rounds}",
            )
            for fut in iterator:
                b = futures[fut]
                try:
                    results.append(fut.result())
                except Exception:
                    log.exception("[%s] step_branch crashed", b.branch_id)

        # Main-thread: re-score each result with the running normalization
        # state, then update the state with this round's raw values. We
        # snapshot a frozen state for scoring this round so all branches see
        # the same statistics regardless of order.
        scoring_state = NormalizationState.from_dict(norm_state.to_dict())

        artifacts = []
        for res in results:
            scored = _normalized_score(scoring_state, res.details, weights)
            normalized_score = float(scored["score"])
            # Replace the raw EvaluationResult.score with the normalized one
            # and stash the breakdown for LLM/UI consumption.
            res.score = normalized_score
            if isinstance(res.details, dict):
                res.details["normalized"] = {
                    "score": normalized_score,
                    "components": scored["components"],
                    "skipped": scored["skipped"],
                    "squash": scoring_state.squash,
                }

            # Update running stats from this result's raw probe values, but
            # only if the eval succeeded AND the user opted into evolving
            # z-score (default is frozen baseline, set during calibration).
            if (update_during_evolution
                    and res.details and res.details.get("ok")):
                norm_state.update(extract_raw_values(res.details.get("probes") or {}))

            node = tree.add_node(
                parent_id=res.parent_id,
                code=res.code,
                score=res.score,
                details=res.details,
                error=res.error,
                strategy=res.strategy,
                mutation_description=res.mutation_description,
                seed_origin=res.seed_origin,
                round_num=round_num,
            )
            for b in branches:
                if b.branch_id == res.branch_id:
                    b.current_node_id = node.node_id
                    break
            artifacts.append({
                "branch_id": res.branch_id,
                "node_id": node.node_id,
                "parent_id": res.parent_id,
                "score": res.score,
                "error_short": (res.error[:200] if res.error else ""),
                "worker": res.worker_name,
                "mutation": res.mutation_description,
            })
            print(
                f"  [{res.branch_id:>3}] score={res.score:8.4f}  "
                f"err={'Y' if res.error else 'N'}  worker={res.worker_name}  "
                f"→ {node.node_id}"
            )

        # Best-policy snapshot.
        if tree.best_node_id:
            new_best = tree.nodes[tree.best_node_id].score
            if new_best > best_score:
                best_score = new_best
                (output_dir / "best_policy.c").write_text(
                    tree.nodes[tree.best_node_id].code
                )
                print(f"  ** New best: {best_score:.4f} → {output_dir/'best_policy.c'}")

        (output_dir / f"round_{round_num}.json").write_text(
            json.dumps({
                "round": round_num,
                "branches": artifacts,
                "best_score_so_far": best_score,
            }, indent=2)
        )
        tree.save(str(tree_path))
        if update_during_evolution:
            norm_state.save(str(norm_path))

        # Frontier review.
        do_checkpoint = (
            round_num % checkpoint_interval == 0
            and round_num < rounds
            and branches
        )
        if do_checkpoint:
            print(f"\n  --- Frontier checkpoint (round {round_num}) ---")
            branches = run_frontier_checkpoint(
                client=planner_client,
                model=planner_cfg["model"],
                temperature=checkpoint_temp,
                tree=tree,
                branches=branches,
                round_num=round_num,
                total_rounds=rounds,
                top_k=top_k,
                max_spawn=max_spawn,
                next_branch_idx=next_branch_idx,
            )
            max_b = max(
                (int(b.branch_id.lstrip("b")) for b in branches
                 if b.branch_id.lstrip("b").isdigit()),
                default=next_branch_idx - 1,
            )
            next_branch_idx = max(next_branch_idx, max_b + 1)

            if not branches:
                log.warning("all branches killed; reseeding from best node")
                best = tree.nodes[tree.best_node_id]
                branches = [make_branch(next_branch_idx, best,
                                        focus_hint="(reseeded)")]
                next_branch_idx += 1

    print(f"\n{'='*60}")
    if tree.best_node_id:
        bn = tree.nodes[tree.best_node_id]
        print(f"  Evolution complete. Best score: {bn.score:.4f}")
        print(f"  Best node: {bn.node_id} (depth={bn.depth}, seed={bn.seed_origin})")
    else:
        print("  Evolution complete. No successful evaluations.")
    stats = tree.depth_stats()
    print(f"  Tree: {stats['total_nodes']} nodes, max depth {stats['max_depth']}")
    print(f"  Saved: {tree_path}")
    print(f"{'='*60}")
