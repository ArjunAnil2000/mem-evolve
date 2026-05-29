#!/usr/bin/env python3
"""CLI entry point for the evolution loop.

    python3 evolve.py <config.toml>
    python3 evolve.py <config.toml> --rounds 5 --resume

All real work lives in `evolution.loop.evolve`. This file just loads TOML
and applies CLI overrides.
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import Any, Dict

try:
    import tomllib  # Python ≥ 3.11
except ImportError:                             # pragma: no cover
    import tomli as tomllib                     # type: ignore


def load_config(toml_path: str, args: argparse.Namespace) -> Dict[str, Any]:
    with open(toml_path, "rb") as f:
        cfg = tomllib.load(f)

    config_dir = os.path.dirname(os.path.abspath(toml_path))

    def _resolve(p: str) -> str:
        return os.path.abspath(os.path.join(config_dir, p)) if p and not os.path.isabs(p) else p

    for key in ("source_dir", "benchmark", "output_dir",
                "mutator_prompt", "seeds_dir"):
        if cfg.get(key):
            cfg[key] = _resolve(cfg[key])

    # CLI overrides
    if args.rounds is not None:
        cfg["rounds"] = args.rounds
    if args.output_dir:
        cfg["output_dir"] = args.output_dir
    if args.resume:
        cfg["resume"] = True
    if args.no_planner:
        cfg["use_planner"] = False
    if args.calibrate_runs is not None:
        cfg["calibrate_runs"] = args.calibrate_runs
    if args.no_calibrate:
        cfg["auto_calibrate"] = False

    # Defaults
    cfg.setdefault("rounds", 20)
    cfg.setdefault("timeout", 180)
    cfg.setdefault("output_dir", "runs/")
    cfg.setdefault("workers", [])
    cfg.setdefault("use_planner", True)
    cfg.setdefault("resume", False)
    cfg.setdefault("tree_file", "evolution_tree.json")
    cfg.setdefault("auto_calibrate", True)
    cfg.setdefault("calibrate_runs", 3)

    cfg.setdefault("llm", {})
    cfg["llm"].setdefault("mutator", {})
    cfg["llm"]["mutator"].setdefault("model", "claude-sonnet-4-6")
    cfg["llm"]["mutator"].setdefault("provider", "anthropic")
    cfg["llm"]["mutator"].setdefault("api_key_env", "ANTHROPIC_API_KEY")
    cfg["llm"]["mutator"].setdefault("temperature", 0.85)
    # planner is optional; falls back to mutator inside loop.py

    cfg.setdefault("evolution", {})
    return cfg


def main() -> None:
    ap = argparse.ArgumentParser(description="Evolve cache_ext BPF policies.")
    ap.add_argument("config", help="TOML config")
    ap.add_argument("--rounds", type=int, default=None)
    ap.add_argument("--output-dir", default=None)
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--no-planner", action="store_true",
                    help="Skip the planner and use config `seeds` directly")
    ap.add_argument("--calibrate", type=int, default=None, metavar="N",
                    help="Skip evolution: run each seed N times against the "
                         "workers to seed normalization stats, then exit. "
                         "Persists <output_dir>/normalization.json.")
    ap.add_argument("--calibrate-runs", type=int, default=None, metavar="N",
                    help="Override the number of calibration runs per seed "
                         "(default 3, set in TOML via `calibrate_runs`). "
                         "Auto-calibration runs at startup unless --no-calibrate.")
    ap.add_argument("--no-calibrate", action="store_true",
                    help="Skip the automatic pre-evolution calibration pass.")
    ap.add_argument("--preflight", action="store_true",
                    help="Query each worker's setup.sh check for the "
                         "configured benchmark, print a per-worker readiness "
                         "table, then exit. Use to verify a fresh node pool "
                         "has everything the workload needs.")
    ap.add_argument("--setup-workers", action="store_true",
                    help="Run each worker's setup.sh setup remotely, then "
                         "exit. Idempotent — assumes the shared base "
                         "(start_workers.sh --install-bench) already ran.")
    ap.add_argument("--no-preflight", action="store_true",
                    help="Skip the auto-preflight check that runs at "
                         "startup before calibration. Useful when iterating "
                         "on the setup script itself.")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%H:%M:%S",
    )
    # Silence per-request HTTP chatter from the SDK clients — these fire on
    # every LLM call from every branch and shred the tqdm progress bar.
    for noisy in ("httpx", "httpcore", "openai", "anthropic"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    cfg = load_config(args.config, args)

    print(f"Config:       {args.config}")
    print(f"Source dir:   {cfg.get('source_dir')}")
    print(f"Benchmark:    {cfg.get('benchmark')}")
    print(f"Output dir:   {cfg['output_dir']}")
    print(f"Rounds:       {cfg['rounds']}  timeout={cfg['timeout']}s")
    print(f"Mutator LLM:  {cfg['llm']['mutator']['model']}")
    if cfg['llm'].get('planner'):
        print(f"Planner LLM:  {cfg['llm']['planner']['model']}")
    workers = cfg.get("workers") or []
    print(f"Workers:      {len(workers)} ({'local' if not workers else 'http'})")
    print(f"Use planner:  {cfg['use_planner']}")
    print(f"Auto-calibrate: {cfg['auto_calibrate']} ({cfg['calibrate_runs']} runs/seed)")
    if cfg.get("resume"):
        print("Mode:         RESUME")

    # Make sibling packages importable when invoked directly.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    if args.preflight:
        ok = run_workload_command(cfg, "preflight")
        sys.exit(0 if ok else 1)

    if args.setup_workers:
        ok = run_workload_command(cfg, "setup")
        sys.exit(0 if ok else 1)

    if args.calibrate is not None:
        from evolution.loop import calibrate
        calibrate(cfg, args.calibrate)
        return

    if not args.no_preflight:
        if not run_workload_command(cfg, "preflight", quiet_on_success=True):
            print(
                "\n  Preflight failed on at least one worker — refusing to start.\n"
                "  Run `python3 evolve.py <config> --setup-workers` to install\n"
                "  any missing per-workload pieces, or `--no-preflight` to skip.",
                file=sys.stderr,
            )
            sys.exit(1)

    from evolution.loop import evolve
    evolve(cfg)


def run_workload_command(cfg: Dict[str, Any], action: str,
                         quiet_on_success: bool = False) -> bool:
    """Fan out preflight/setup over the worker pool. Returns True iff all OK.

    `action` is "preflight" or "setup". Local-only configs (no http workers)
    fall back to running the script in-process — useful when iterating on
    setup.sh from the coordinator itself.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed
    from evolution.worker import build_workers, HTTPWorker

    benchmark = cfg.get("benchmark")
    if not benchmark:
        print("ERROR: config has no `benchmark` set", file=sys.stderr)
        return False

    workers = build_workers(cfg)
    http_workers = [w for w in workers if isinstance(w, HTTPWorker)]
    if not http_workers:
        return _run_workload_command_local(benchmark, action)

    label = "Preflight" if action == "preflight" else "Setup"
    timeout = 60 if action == "preflight" else 1800
    print(f"\n  {label}: {len(http_workers)} worker(s), benchmark={benchmark}")

    results: list[tuple[str, Dict[str, Any]]] = []
    with ThreadPoolExecutor(max_workers=len(http_workers)) as pool:
        future_to_worker = {
            pool.submit(
                w.preflight if action == "preflight" else w.setup,
                benchmark, timeout,
            ): w for w in http_workers
        }
        for fut in as_completed(future_to_worker):
            w = future_to_worker[fut]
            try:
                results.append((w.url, fut.result()))
            except Exception as e:
                results.append((w.url, {"ok": False, "error": str(e)}))

    results.sort(key=lambda kv: kv[0])
    all_ok = True
    for url, res in results:
        ok = bool(res.get("ok"))
        all_ok = all_ok and ok
        marker = "OK " if ok else "FAIL"
        if ok and quiet_on_success:
            continue
        print(f"  [{marker}] {url}")
        if res.get("error"):
            print(f"         error: {res['error']}")
        for stream in ("stdout", "stderr"):
            text = (res.get(stream) or "").strip()
            if text:
                for line in text.splitlines():
                    print(f"         {stream[:3]}: {line}")
    if all_ok and quiet_on_success:
        print(f"  All {len(results)} workers OK.")
    elif all_ok:
        print(f"\n  {label} OK on all {len(results)} workers.")
    else:
        n_fail = sum(1 for _, r in results if not r.get("ok"))
        print(f"\n  {label} FAILED on {n_fail}/{len(results)} workers.")
    return all_ok


def _run_workload_command_local(benchmark: str, action: str) -> bool:
    """Fallback for local-only (no http workers) mode."""
    import subprocess
    setup_sh = os.path.join(os.path.dirname(benchmark), "setup.sh")
    if not os.path.isfile(setup_sh):
        print(f"ERROR: no setup.sh next to benchmark: {setup_sh}", file=sys.stderr)
        return False
    sub = "check" if action == "preflight" else "setup"
    print(f"  Local {action}: bash {setup_sh} {sub}")
    cp = subprocess.run(["bash", setup_sh, sub])
    return cp.returncode == 0


if __name__ == "__main__":
    main()
