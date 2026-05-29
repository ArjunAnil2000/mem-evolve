"""Run a pre-compiled cache policy against a benchmark and measure it.

    evaluate(binary_path, benchmark_script) -> EvaluationResult

The evaluator does NOT compile — compilation is the caller's responsibility
(see `evaluator.compile.compile_policy`). This keeps workers dumb: they
receive a pre-built .out and only need to know how to launch it, not how to
build it.

Steps:
  1. Resolve the benchmark cgroup path (from arg / env / sentinel file).
  2. Run each probe's pre() to snapshot baselines.
  3. Launch the benchmark (bash), passing POLICY_BINARY / CACHE_EXT_CGROUP /
     POLICY_METRICS_OUT / JOB_DIR via environment.
  4. Run each probe's post() after the workload exits (or times out).
  5. Aggregate into an EvaluationResult with a score and LLM-ready text.

CLI:
    python3 -m evaluator.evaluate <binary.out> <launch_script> [--cgroup PATH]
    python3 -m evaluator.evaluate - <launch_script> --json < binary.out
        (the `-` reads the .out bytes from stdin — used by SSHWorker)

Env contract for the launch script:
    POLICY_BINARY        absolute path to the compiled policy loader (.out)
    CACHE_EXT_CGROUP     absolute path to the benchmark cgroup
    POLICY_METRICS_OUT   absolute path where the loader MAY dump counter JSON
    JOB_DIR              per-run scratch directory
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional

_SIGNAL_BY_NAME = {
    "INT":  signal.SIGINT,
    "TERM": signal.SIGTERM,
    "KILL": signal.SIGKILL,
}

_SELF_DIR = os.path.dirname(os.path.abspath(__file__))
_PKG_DIR = os.path.dirname(_SELF_DIR)
if _PKG_DIR not in sys.path:
    sys.path.insert(0, _PKG_DIR)

from evaluator.probes import (
    DEFAULT_PROBES, DEFAULT_WEIGHTS, Probe, ProbeResult,
)


CGROUP_SENTINEL = "/run/evo_cache/cgroup.path"


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------

@dataclass
class EvaluationResult:
    ok: bool
    error: str
    score: float
    wallclock_sec: float
    probes: Dict[str, Dict[str, Any]]
    stdout_tail: str
    stderr_tail: str

    def feedback_text(self) -> str:
        head = (
            f"[{'OK' if self.ok else 'FAIL'}] "
            f"score={self.score:.4f} wall={self.wallclock_sec:.2f}s"
        )
        if not self.ok and self.error:
            head += f"  error={self.error}"
        lines = [head]
        for name in sorted(self.probes):
            r = self.probes[name]
            lines.append(f"  - {name}: {r['summary']}")
        if not self.ok and self.stderr_tail:
            lines.append("stderr tail:")
            lines.append(self.stderr_tail[-800:])
        return "\n".join(lines)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


# ---------------------------------------------------------------------------
# Cgroup resolution
# ---------------------------------------------------------------------------

def resolve_cgroup_path(override: Optional[str] = None) -> str:
    if override:
        return override
    env = os.environ.get("CACHE_EXT_CGROUP")
    if env:
        return env
    if os.path.exists(CGROUP_SENTINEL):
        try:
            with open(CGROUP_SENTINEL) as f:
                return f.read().strip()
        except OSError:
            pass
    raise RuntimeError(
        f"no cgroup path; pass --cgroup, set $CACHE_EXT_CGROUP, or have "
        f"setup_isolation.sh write {CGROUP_SENTINEL}"
    )


# ---------------------------------------------------------------------------
# Binary handling (for `-` / stdin mode)
# ---------------------------------------------------------------------------

def _materialise_binary(binary_arg: str, work_dir: Path) -> str:
    """If binary_arg is `-`, read bytes from stdin and write to a temp file.
    Otherwise return the path unchanged.
    """
    if binary_arg != "-":
        return binary_arg
    out = work_dir / "policy_stdin.out"
    with open(out, "wb") as f:
        shutil.copyfileobj(sys.stdin.buffer, f)
    try:
        os.chmod(out, 0o755)
    except OSError:
        pass
    return str(out)


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def _raw_signed_score(
    results: Dict[str, ProbeResult],
    weights: Dict[str, float],
) -> float:
    """Cheap raw weighted score: ignores units, used only when no
    normalization state is available (calibration / standalone CLI).

    Real evolution runs always score via `evolution.normalization` instead.
    """
    num, den = 0.0, 0.0
    for name, r in results.items():
        if r.direction == "record":
            continue
        w = float(weights.get(name, 0.0))
        if w <= 0.0:
            continue
        v = -r.value if r.direction == "minimize" else r.value
        num += v * w
        den += w
    return num / den if den > 0 else 0.0


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def evaluate(
    binary_path: Optional[str],
    benchmark_script: str,
    *,
    cgroup_path: Optional[str] = None,
    timeout: int = 180,
    probes: Optional[List[Probe]] = None,
    weights: Optional[Dict[str, float]] = None,
    work_dir: Optional[str] = None,
    cwd: Optional[str] = None,
    extra_env: Optional[Dict[str, str]] = None,
    split_phases: bool = False,
    warmup_timeout: Optional[int] = None,
) -> EvaluationResult:
    """Run *binary_path* against *benchmark_script* under the benchmark cgroup.

    The binary MUST already be compiled and executable. Compilation is the
    caller's job (see `evaluator.compile.compile_policy`). Pass
    `binary_path=None` to run the launch script with no policy attached —
    useful for benchmark-only / baseline measurement runs. In that mode
    `$POLICY_BINARY` is unset and the launch script must tolerate its
    absence.

    *cwd* is the working directory for the bash launch script; usually the
    `cache_ext/` source tree so relative paths in the script resolve.

    The returned `score` is a cheap raw weighted sum and SHOULD be ignored
    by long-running evolution loops — those score via the normalization
    layer (see `evolution.normalization`). Workers stay stateless so the
    coordinator can re-score consistently across rounds.

    If *split_phases* is True, the launch script is invoked twice:
      1. once with EVO_PHASE=warmup — probes do NOT wrap this. The launcher
         is expected to set up the cgroup, prime the cache, start the policy
         loader, and write its PID to $JOB_DIR/loader.pid (so the evaluator
         can kill it after the measure phase regardless of which subshell
         owns the process group).
      2. once with EVO_PHASE=measure — probes wrap this. The launcher reads
         $JOB_DIR/loader.pid, runs the actual measured workload, and exits
         WITHOUT killing the loader; the evaluator does that in cleanup.
    The two invocations share JOB_DIR / CACHE_EXT_CGROUP / POLICY_BINARY,
    so any state warmup leaves on disk (DB stamps, generated files,
    populated page cache) is visible to measure.

    With split_phases=False (default), the launcher runs once with
    EVO_PHASE=all and the launcher's own trap is responsible for loader
    teardown — current behavior.
    """
    probes = probes if probes is not None else list(DEFAULT_PROBES)
    weights = weights if weights is not None else dict(DEFAULT_WEIGHTS)

    # --- cgroup ---
    try:
        cg = resolve_cgroup_path(cgroup_path)
    except RuntimeError as e:
        return EvaluationResult(
            ok=False, error=str(e), score=0.0, wallclock_sec=0.0,
            probes={}, stdout_tail="", stderr_tail="",
        )
    # Note: cgroup may not exist yet — the benchmark script is allowed to
    # create it. Probes read from it post-run; _read_memstat/_read_iostat
    # both tolerate a missing file.

    # --- scratch dir ---
    wd = Path(work_dir) if work_dir else Path(tempfile.mkdtemp(prefix="evaluate-"))
    wd.mkdir(parents=True, exist_ok=True)
    policy_metrics_path = str(wd / "policy_metrics.json")

    # --- resolve binary (may come over stdin; may be None for no-policy runs) ---
    if binary_path is not None:
        try:
            binary_path = _materialise_binary(binary_path, wd)
        except Exception as e:
            return EvaluationResult(
                ok=False, error=f"cannot read binary: {e}",
                score=0.0, wallclock_sec=0.0, probes={},
                stdout_tail="", stderr_tail="",
            )
        if not os.path.isfile(binary_path):
            return EvaluationResult(
                ok=False, error=f"binary not found: {binary_path}",
                score=0.0, wallclock_sec=0.0, probes={},
                stdout_tail="", stderr_tail="",
            )
        if not os.access(binary_path, os.X_OK):
            try:
                os.chmod(binary_path, 0o755)
            except OSError:
                pass

    # --- probe context ---
    ctx: Dict[str, Any] = {
        "cgroup_path": cg,
        "policy_metrics_path": policy_metrics_path,
        "work_dir": str(wd),
    }

    # --- env shared across phases ---
    base_env = os.environ.copy()
    base_env.update({
        "CACHE_EXT_CGROUP":    cg,
        "POLICY_METRICS_OUT":  policy_metrics_path,
        "JOB_DIR":             str(wd),
    })
    if binary_path is not None:
        base_env["POLICY_BINARY"] = binary_path
    else:
        base_env.pop("POLICY_BINARY", None)
    if extra_env:
        base_env.update(extra_env)

    bench_cwd = cwd or os.path.dirname(os.path.abspath(benchmark_script)) or None
    loader_pid_file = wd / "loader.pid"

    def _run_phase(phase: str, t_limit: int):
        """Run the launch script with EVO_PHASE=<phase>. Returns
        (returncode, stdout_tail, stderr_tail, err_msg, elapsed)."""
        env = dict(base_env)
        env["EVO_PHASE"] = phase
        t = time.monotonic()
        try:
            proc = subprocess.run(
                ["bash", benchmark_script],
                cwd=bench_cwd,
                env=env,
                timeout=t_limit,
                capture_output=True,
                text=True,
            )
            err = "" if proc.returncode == 0 else f"benchmark[{phase}] returned {proc.returncode}"
            return (
                proc.returncode,
                (proc.stdout or "")[-2000:],
                (proc.stderr or "")[-2000:],
                err,
                time.monotonic() - t,
            )
        except subprocess.TimeoutExpired as e:
            so = ((e.stdout or b"")[-2000:]).decode(errors="replace") if e.stdout else ""
            se = ((e.stderr or b"")[-2000:]).decode(errors="replace") if e.stderr else ""
            return (-1, so, se, f"benchmark[{phase}] timed out after {t_limit}s", time.monotonic() - t)
        except Exception as e:
            return (-1, "", "", f"benchmark[{phase}] launch failed: {e}", time.monotonic() - t)

    def _kill_persisted_loader():
        """Read $JOB_DIR/loader.pid (written by the warmup phase) and tear
        the loader down. Best-effort — never raises."""
        try:
            if not loader_pid_file.exists():
                return
            pid_text = loader_pid_file.read_text().strip()
            if not pid_text:
                return
            pid = int(pid_text)
        except (OSError, ValueError):
            return
        for sig in ("INT", "TERM"):
            try:
                os.kill(pid, _SIGNAL_BY_NAME[sig])
            except (ProcessLookupError, PermissionError, OSError):
                return
            time.sleep(0.5)
            try:
                os.kill(pid, 0)
            except OSError:
                return
        try:
            os.kill(pid, _SIGNAL_BY_NAME["KILL"])
        except OSError:
            pass

    bench_err = ""
    stdout_tail = ""
    stderr_for_result = ""
    wall = 0.0

    try:
        if split_phases:
            # Phase 1: warmup (NO probes wrapped).
            wt = warmup_timeout if warmup_timeout is not None else timeout
            rc_w, so_w, se_w, err_w, dt_w = _run_phase("warmup", wt)
            if err_w:
                # Warmup failed — skip measure entirely, but still run probe
                # post-hooks so the result shape stays consistent.
                bench_err = err_w
                stdout_tail = so_w
                stderr_for_result = se_w
                # Best-effort probe.pre to give post() a baseline; if these
                # fail we still want to return the warmup error.
                for p in probes:
                    try:
                        p.pre(ctx)
                    except Exception:
                        pass
                wall = dt_w
            else:
                # probes.pre AFTER warmup so deltas exclude setup/init noise.
                for p in probes:
                    try:
                        p.pre(ctx)
                    except Exception as e:
                        bench_err = f"probe {p.name}.pre failed: {e}"
                        break
                if not bench_err:
                    rc_m, so_m, se_m, err_m, dt_m = _run_phase("measure", timeout)
                    bench_err = err_m
                    stdout_tail = (so_w + "\n--- measure ---\n" + so_m)[-2000:]
                    stderr_for_result = (se_w + "\n--- measure ---\n" + se_m)[-2000:]
                    wall = dt_m
        else:
            # Single-phase / legacy mode: launcher does everything itself.
            for p in probes:
                try:
                    p.pre(ctx)
                except Exception as e:
                    return EvaluationResult(
                        ok=False, error=f"probe {p.name}.pre failed: {e}",
                        score=0.0, wallclock_sec=0.0, probes={},
                        stdout_tail="", stderr_tail="",
                    )
            rc, so, se, err, dt = _run_phase("all", timeout)
            bench_err = err
            stdout_tail = so
            stderr_for_result = se
            wall = dt
    finally:
        # In split mode the loader outlives the bash subshells, so the
        # evaluator owns teardown. In single-phase mode the launcher's own
        # trap kills the loader and this is a no-op (loader.pid absent).
        if split_phases:
            _kill_persisted_loader()

    # --- post-hooks (always; deltas still meaningful on error) ---
    probe_results: Dict[str, ProbeResult] = {}
    for p in probes:
        try:
            probe_results[p.name] = p.post(ctx)
        except Exception as e:
            probe_results[p.name] = ProbeResult(
                name=p.name, value=0.0, unit="", direction="record",
                summary=f"(probe.post failed: {e})", details={},
            )

    score = (
        _raw_signed_score(probe_results, weights)
        if not bench_err else 0.0
    )

    return EvaluationResult(
        ok=(not bench_err),
        error=bench_err,
        score=score,
        wallclock_sec=wall,
        probes={n: asdict(r) for n, r in probe_results.items()},
        stdout_tail=stdout_tail,
        stderr_tail=stderr_for_result,
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Run a pre-compiled BPF cache policy against a benchmark.",
    )
    ap.add_argument(
        "binary",
        nargs="?",
        default=None,
        help="Path to compiled policy .out (or `-` to read bytes from stdin). "
             "Omit (or use --no-policy) to run the launch script with no policy attached.",
    )
    ap.add_argument("benchmark", help="Path to bash launch script")
    ap.add_argument("--no-policy", action="store_true",
                    help="Run the launch script without loading any policy (POLICY_BINARY is unset).")
    ap.add_argument("--cgroup", default=None, help="Cgroup path (overrides sentinel / env)")
    ap.add_argument("--timeout", type=int, default=180, help="Benchmark timeout seconds")
    ap.add_argument("--cwd", default=None, help="Working directory for the launch script")
    ap.add_argument("--json", action="store_true", help="Print full result as JSON")
    ap.add_argument("--work-dir", default=None, help="Scratch dir (default: tmp)")
    ap.add_argument("--split", action="store_true",
                    help="Invoke the launcher twice (EVO_PHASE=warmup, then EVO_PHASE=measure); "
                         "probes wrap only the measure phase. Launcher must respect EVO_PHASE.")
    ap.add_argument("--warmup-timeout", type=int, default=None,
                    help="Seconds for the warmup phase only (default: same as --timeout). "
                         "Ignored unless --split is set.")
    ap.add_argument(
        "--weight", action="append", default=[], metavar="NAME=FLOAT",
        help="Override probe weight; repeat for multiple. Example: --weight wallclock=2.0. "
             "The standalone CLI scores raw values — for normalized scoring across rounds, "
             "use `evolve.py` (see evolution.normalization).",
    )
    return ap.parse_args()


def _parse_kv_floats(items: List[str], flag: str) -> Dict[str, float]:
    out: Dict[str, float] = {}
    for it in items:
        if "=" not in it:
            raise SystemExit(f"{flag} expects NAME=FLOAT, got {it!r}")
        k, v = it.split("=", 1)
        try:
            out[k.strip()] = float(v)
        except ValueError:
            raise SystemExit(f"{flag} value not a float: {it!r}")
    return out


def main() -> None:
    args = _parse_args()

    binary_arg: Optional[str] = args.binary
    if args.no_policy or binary_arg in (None, "", "none", "NONE"):
        binary_arg = None

    weight_overrides = _parse_kv_floats(args.weight, "--weight")

    weights = dict(DEFAULT_WEIGHTS)
    weights.update(weight_overrides)

    if binary_arg is None and not args.benchmark:
        raise SystemExit("benchmark script is required")

    result = evaluate(
        binary_path=binary_arg,
        benchmark_script=args.benchmark,
        cgroup_path=args.cgroup,
        timeout=args.timeout,
        work_dir=args.work_dir,
        cwd=args.cwd,
        weights=weights,
        split_phases=args.split,
        warmup_timeout=args.warmup_timeout,
    )
    if args.json:
        print(json.dumps(result.to_dict(), indent=2))
    else:
        print(result.feedback_text())
    sys.exit(0 if result.ok else 1)


if __name__ == "__main__":
    main()
