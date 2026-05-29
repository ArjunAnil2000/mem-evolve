#!/usr/bin/env python3
"""
Demo: run the filesearch bash benchmark through the framework.

This shows how the hook system, benchmark runner, and scoring work
without needing any BPF compilation or cgroup setup.

Usage:
    python examples/filesearch_demo/run_demo.py [--passes 5] [--iterations 3]
"""

import argparse
import json
import logging
import os
import sys

# Make sure the framework is importable
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
sys.path.insert(0, PROJECT_DIR)

from benchmarks.runner import BenchmarkRunner, BenchmarkSpec
from hooks import create_hook

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
log = logging.getLogger("demo")

LINUX_SRC = "/mydata/evo_cache/linux"


def main():
    parser = argparse.ArgumentParser(description="Filesearch benchmark demo")
    parser.add_argument("--passes", type=int, default=5,
                        help="Number of rg passes per iteration (default: 5)")
    parser.add_argument("--iterations", type=int, default=3,
                        help="Number of iterations inside the bash script (default: 3)")
    parser.add_argument("--baseline", type=float, default=60.0,
                        help="Baseline time in seconds for scoring (default: 60)")
    args = parser.parse_args()

    results_file = os.path.join(SCRIPT_DIR, "results.json")
    launch_script = os.path.join(SCRIPT_DIR, "run_benchmark.sh")

    # --- Method 1: just run the bash script directly to see it work ---
    log.info("=" * 60)
    log.info("METHOD 1: Direct bash invocation")
    log.info("=" * 60)

    import subprocess
    rc = subprocess.run(
        [
            launch_script,
            "--data-dir", LINUX_SRC,
            "--results-file", results_file,
            "--passes", str(args.passes),
            "--iterations", str(args.iterations),
        ],
        cwd=PROJECT_DIR,
    )
    if rc.returncode != 0:
        log.error("Benchmark script failed with rc=%d", rc.returncode)
        return 1

    with open(results_file) as f:
        raw = json.load(f)
    log.info("Raw JSON results: %s", json.dumps(raw, indent=2))

    # --- Method 2: run through the framework's BenchmarkRunner ---
    log.info("")
    log.info("=" * 60)
    log.info("METHOD 2: Framework BenchmarkRunner with hooks")
    log.info("=" * 60)

    spec = BenchmarkSpec(
        name="filesearch_demo",
        launch_script=launch_script,
        results_file=results_file,
        timeout=300,
        weight=1.0,
        iterations=1,       # framework does 1 iter; the script does its own
        iteration_aggregation="avg",
        baseline_values={"time": args.baseline},
        hooks=[
            {"type": "time", "weight": 1.0},
        ],
    )

    runner = BenchmarkRunner([spec], base_dir=PROJECT_DIR)
    result = runner.run_all()

    log.info("")
    log.info("=" * 60)
    log.info("FRAMEWORK RESULTS")
    log.info("=" * 60)
    log.info("combined_score: %.4f", result["combined_score"])
    for bname, bdata in result.get("benchmarks", {}).items():
        log.info("  benchmark: %s", bname)
        log.info("    score: %.4f", bdata.get("score", 0))
        for hname, hdata in bdata.get("hooks", {}).items():
            log.info("    hook %-20s  value=%.3f  baseline=%s  score=%.4f",
                     hname, hdata["value"], hdata["baseline"], hdata["score"])

    log.info("")
    log.info("Score interpretation: baseline(%.1fs) / measured = %.4f",
             args.baseline, result["combined_score"])
    log.info("  > 1.0 means faster than baseline")
    log.info("  < 1.0 means slower than baseline")

    return 0


if __name__ == "__main__":
    sys.exit(main())
