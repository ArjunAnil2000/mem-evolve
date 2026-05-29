#!/usr/bin/env python3
"""
Demo: run the scan-thrash benchmark through the framework.

This is the worst-case workload for Linux's default page cache (LRU).
It alternates between reading hot data and doing large sequential scans
that pollute the cache. A smart eviction policy should protect the hot
working set from scan pollution.

Usage:
    # Quick standalone (just runs the bash benchmark, needs sudo):
    sudo bash examples/scan_thrash_demo/run_benchmark.sh

    # Through the framework with scoring:
    sudo python3 examples/scan_thrash_demo/run_demo.py --use-framework

    # Direct invocation (no framework, no cgroup — for debugging):
    python3 examples/scan_thrash_demo/run_demo.py
"""

import argparse
import json
import logging
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
sys.path.insert(0, PROJECT_DIR)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
log = logging.getLogger("scan_thrash_demo")


def main():
    parser = argparse.ArgumentParser(description="Scan-thrash benchmark demo")
    parser.add_argument("--hot-size", type=int, default=48,
                        help="Hot working set size in MB (default: 48)")
    parser.add_argument("--scan-size", type=int, default=1024,
                        help="Sequential scan size in MB (default: 1024)")
    parser.add_argument("--cache-limit", type=int, default=64,
                        help="Cgroup memory limit in MB (default: 64)")
    parser.add_argument("--rounds", type=int, default=5,
                        help="Number of hot-scan-hot cycles (default: 5)")
    parser.add_argument("--baseline", type=float, default=0.3,
                        help="Baseline score for scoring (default: 0.3, typical LRU)")
    parser.add_argument("--use-framework", action="store_true",
                        help="Run through BenchmarkRunner with hooks/scoring")
    args = parser.parse_args()

    results_file = os.path.join(SCRIPT_DIR, "results.json")

    env = os.environ.copy()
    env["HOT_SIZE_MB"] = str(args.hot_size)
    env["SCAN_SIZE_MB"] = str(args.scan_size)
    env["CACHE_LIMIT_MB"] = str(args.cache_limit)
    env["ROUNDS"] = str(args.rounds)
    env["JOB_DIR"] = SCRIPT_DIR

    if args.use_framework:
        log.info("=" * 60)
        log.info("Running through BenchmarkRunner framework")
        log.info("=" * 60)

        from benchmarks.runner import BenchmarkRunner, BenchmarkSpec

        # Use run.sh (the wrapper that sets up cgroup)
        launch_script = os.path.join(PROJECT_DIR, "eval/scan_thrash/run.sh")

        spec = BenchmarkSpec(
            name="scan_thrash",
            launch_script=launch_script,
            results_file=results_file,
            timeout=600,
            weight=1.0,
            iterations=1,
            iteration_aggregation="avg",
            baseline_values={"throughput": args.baseline},
            hooks=[{
                "type": "throughput",
                "weight": 1.0,
                "json_path": "combined_score",
                "unit": "ratio",
            }],
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
        log.info("Score interpretation (throughput hook: measured / baseline):")
        log.info("  > 1.0 = better than baseline LRU")
        log.info("  < 1.0 = worse than baseline LRU")
    else:
        log.info("=" * 60)
        log.info("Direct invocation (no framework)")
        log.info("=" * 60)
        log.info("Config: hot=%dMB scan=%dMB cache=%dMB rounds=%d",
                 args.hot_size, args.scan_size, args.cache_limit, args.rounds)
        log.info("")
        log.info("NOTE: This runs the raw script. For proper cgroup setup, use:")
        log.info("  sudo bash examples/scan_thrash_demo/run_benchmark.sh")
        log.info("")

        launch_script = os.path.join(PROJECT_DIR, "eval/scan_thrash/run.sh")
        rc = subprocess.run(["bash", launch_script], cwd=PROJECT_DIR, env=env)
        if rc.returncode != 0:
            log.error("Benchmark failed with rc=%d", rc.returncode)
            return 1

        with open(results_file) as f:
            raw = json.load(f)
        log.info("")
        log.info("=" * 60)
        log.info("RAW RESULTS")
        log.info("=" * 60)
        log.info(json.dumps(raw, indent=2))

        score = raw.get("combined_score", 0)
        log.info("")
        log.info("combined_score: %.4f", score)
        log.info("  ~1.0  = hot data stayed cached (good policy)")
        log.info("  <0.3  = hot data evicted by scan (LRU behavior)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
