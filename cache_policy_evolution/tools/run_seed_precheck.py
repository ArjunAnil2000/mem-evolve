#!/usr/bin/env python3
"""Compile one seed and run it against a benchmark script, standalone.

For manual sanity checks and baseline runs OUTSIDE the evolve.py loop —
e.g. "does this seed compile and run cleanly against get_scan on this
host." Not part of the evolution pipeline; just a thin wrapper around
evaluator.compile_policy() + evaluator.evaluate() with a single JSON
output combining the standard probe results with whatever the benchmark
script's own results.json (if any) contains, so one file has everything
needed to compare runs later.

Usage:
    python3 tools/run_seed_precheck.py <seed_path> <benchmark_script> \
        --work-dir DIR [--cgroup PATH] [--timeout N] [--cwd DIR] \
        [--policies-dir DIR] [--json-out FILE]

Example (from cache_policy_evolution/, on a host with the toolchain):
    sudo -E python3 tools/run_seed_precheck.py \
        seeds/vulcan_scan_class.c \
        eval/get_scan/run_with_policy.sh \
        --cgroup /sys/fs/cgroup/cache_ext_precheck \
        --work-dir /mydata/precheck_runs/exp-3_vulcan_scan_class

Exit codes: 0 = ran and scored ok, 1 = ran but benchmark reported
failure, 2 = compile failed.
"""

import argparse
import json
import os
import shutil
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CPE_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))       # cache_policy_evolution/
REPO_ROOT = os.path.abspath(os.path.join(CPE_DIR, ".."))        # mem-evolve/
sys.path.insert(0, CPE_DIR)

from evaluator import compile_policy, evaluate  # noqa: E402


def _resolve(path: str, base: str) -> str:
    return path if os.path.isabs(path) else os.path.join(base, path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("seed_path", help="Path to the seed .c file (combined BPF+loader)")
    ap.add_argument("benchmark_script", help="Path to the launch script, e.g. eval/get_scan/run_with_policy.sh")
    ap.add_argument("--work-dir", required=True, help="Scratch dir; results.json (if any) and precheck_result.json land here")
    ap.add_argument("--policies-dir", default=os.path.join(REPO_ROOT, "cache_ext", "policies"))
    ap.add_argument("--cgroup", default=None, help="Cgroup path (passed through to evaluator.evaluate)")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--cwd", default=os.path.join(REPO_ROOT, "cache_ext"),
                     help="Working directory for the launch script (default: cache_ext/)")
    ap.add_argument("--json-out", default=None, help="Default: <work-dir>/precheck_result.json")
    args = ap.parse_args()

    seed_path = _resolve(args.seed_path, CPE_DIR)
    benchmark_script = _resolve(args.benchmark_script, CPE_DIR)
    policies_dir = os.path.abspath(args.policies_dir)
    work_dir = os.path.abspath(args.work_dir)
    os.makedirs(work_dir, exist_ok=True)

    if not os.path.isfile(seed_path):
        print(f"[precheck] seed not found: {seed_path}", file=sys.stderr)
        return 2

    with open(seed_path) as f:
        code = f.read()

    print(f"[precheck] compiling {seed_path}", file=sys.stderr)
    cres = compile_policy(code, policies_dir)
    if not cres.ok or not cres.binary_path:
        print(f"[precheck] COMPILE FAILED: {cres.error}", file=sys.stderr)
        if cres.stderr_tail:
            print(cres.stderr_tail, file=sys.stderr)
        return 2

    snapshot = os.path.join(work_dir, "policy.out")
    shutil.copy2(cres.binary_path, snapshot)
    os.chmod(snapshot, 0o755)
    print(f"[precheck] compiled OK -> {snapshot}", file=sys.stderr)

    print(f"[precheck] running {benchmark_script} (timeout={args.timeout}s)", file=sys.stderr)
    result = evaluate(
        binary_path=snapshot,
        benchmark_script=benchmark_script,
        cgroup_path=args.cgroup,
        timeout=args.timeout,
        work_dir=work_dir,
        cwd=args.cwd,
    )

    combined = result.to_dict()
    workload_results_path = os.path.join(work_dir, "results.json")
    if os.path.exists(workload_results_path):
        try:
            with open(workload_results_path) as f:
                combined["workload_results"] = json.load(f)
        except Exception as e:
            combined["workload_results_error"] = str(e)
    combined["seed_path"] = seed_path

    out_path = args.json_out or os.path.join(work_dir, "precheck_result.json")
    with open(out_path, "w") as f:
        json.dump(combined, f, indent=2)

    print(f"[precheck] ok={result.ok} score={result.score:.4f} wall={result.wallclock_sec:.2f}s",
          file=sys.stderr)
    print(f"[precheck] -> {out_path}", file=sys.stderr)
    if not result.ok:
        print(f"[precheck] error: {result.error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
