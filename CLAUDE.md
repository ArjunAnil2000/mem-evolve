# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

**evo_cache** automatically evolves Linux page-cache eviction policies using LLM-driven code generation. Policies are written as eBPF programs against the `cache_ext` kernel (custom 6.6.8 build from the SOSP 2025 cache_ext paper). A Python coordinator mutates policies across parallel DFS branches, evaluates each candidate on a cgroup-isolated benchmark, and surfaces kernel-level probe feedback back to the LLM.

## Repository Structure

- **`cache_ext/`** — custom Linux kernel submodule, eBPF policies, benchmark runners, install scripts.
- **`cache_policy_evolution/`** — the coordinator (Python). Two packages:
  - **`evaluator/`** — standalone end-to-end policy evaluator.
    - `evaluate.py` — `evaluate(policy_path, benchmark_script, ...) -> EvaluationResult`. Compiles a combined BPF+loader `.c`, launches the benchmark under a cgroup, runs probes, returns unified result. Usable as a library or CLI (`python3 -m evaluator.evaluate ...`).
    - `probes.py` — workload-agnostic probes (read kernel counters, not workload output):
      - `WallclockProbe` (time)
      - `CgroupIostatProbe` (`rbytes` — the best "did the cache help" signal)
      - `CgroupMemstatProbe` (`workingset_refault_file` — direct refault count)
      - `PolicyCountersProbe` (optional — reads JSON dumped to `$POLICY_METRICS_OUT` by the policy loader)
    - No LLM / tree / worker dependencies — the unit of work orchestration wraps.
  - **`evolution/`** — parallel branch-based search.
    - `tree.py` — `EvolutionTree` / `TreeNode` (full lineage, node queries, serialization, LLM-ready summary).
    - `branch.py` — `Branch` with per-branch LLM chat history + `step_branch()` (one DFS round).
    - `frontier.py` — smart-LLM checkpoint reviewer: continue / kill / pivot / spawn.
    - `planner.py` — smart-LLM seed-picker run once at startup; takes workload description + seed summaries, returns K `BranchAssignment`s with initial focus hints.
    - `worker.py` — `LocalWorker` (in-process) and `HTTPWorker` (POSTs a compiled `.out` to a remote `worker_server.py` daemon). Coordinator only needs HTTP reachability to each node — no SSH at runtime.
    - `loop.py` — main `evolve(cfg)` orchestrator. One code path: `workers=[]` → single LocalWorker / 1 branch; `workers=[...]` → one HTTPWorker per URL, parallel branches.
    - `prompts/mutator.txt`, `prompts/planner.txt`, `prompts/frontier.txt` — system prompts.
  - `evolve.py` — thin CLI that loads TOML and calls `evolution.loop.evolve`.
  - `worker_server.py` — stdlib HTTP daemon runs on each worker node; exposes `GET /health` and `POST /evaluate` (binary bytes in body). Calls `evaluator.evaluate()` locally.
  - `targets/` — shared compilation helpers (`code_splitter`, `CompilationPipeline`).
  - `llm_adapter.py` — OpenAI-compatible wrapper over the Anthropic SDK.
  - `seeds/` — seed policies: `fifo.c`, `lru.c`, `mru.c`, `s3_fifo.c`, `scan_resist.c`.
  - `scan_thrash.toml` — example config.

- **`parse_ssh.sh`**, **`setup_cloudlab.sh`** — CloudLab provisioning helpers (top-level).

## Key Commands

### Running evolution
```bash
cd cache_policy_evolution
pip install -r requirements.txt
python3 evolve.py scan_thrash.toml                 # local-serial if workers=[]
python3 evolve.py scan_thrash.toml --rounds 30
python3 evolve.py scan_thrash.toml --resume
python3 evolve.py scan_thrash.toml --no-planner    # skip planner; use cfg.seeds
```

### Standalone evaluation
```bash
# Compile once on the coordinator (or anywhere with clang/bpftool):
python3 -c "
from evaluator import compile_policy
code = open('seeds/lru.c').read()
r = compile_policy(code, '../cache_ext/policies')
print(r.ok, r.binary_path, r.error)
"

# Run the compiled binary:
python3 -m evaluator.evaluate ../cache_ext/policies/evo_policy.out \
    ../cache_ext/eval/scan_thrash/run_with_policy.sh \
    --cgroup /sys/fs/cgroup/cache_ext_bench

# Or read the binary from stdin (handy for scripted pipelines):
cat evo_policy.out | python3 -m evaluator.evaluate - \
    ../cache_ext/eval/scan_thrash/run_with_policy.sh --json
```

### Workers (HTTP daemon on each node)
```bash
# From the coordinator (needs SSH to each worker, one-time):
./start_workers.sh host1 host2 host3                 # launch
./start_workers.sh --git-pull --token $(uuidgen) h1  # refresh repo + auth
./start_workers.sh --status host1 host2              # /health check
./start_workers.sh --stop host1 host2                # kill daemons

# Manually on a worker (no SSH needed if you have shell access):
cd ~/evo_cache/cache_policy_evolution
python3 worker_server.py --port 8080
```
Then put the URLs in `scan_thrash.toml`:
```toml
workers = ["http://host1:8080", "http://host2:8080"]
```

### Building policies manually
```bash
cd cache_ext
./build_policies.sh
cd policies && make
```

### Setup (CloudLab c6525-25g / Ubuntu 22.04)
```bash
cd cache_ext
./install_kernel.sh      # build + install 6.6.8-cache-ext
./install_filesearch.sh
./install_leveldb.sh
./install_ycsb.sh
./setup_isolation.sh     # creates the benchmark cgroup
./download_dbs.sh
```

## Architecture: Evolution Pipeline

```
evolve.py  →  evolution.loop.evolve(cfg)
  ├── build LLM clients (mutator + planner)
  ├── build workers from cfg.workers  (LocalWorker or [SSHWorker,…])
  ├── planner.pick_seeds()  → K BranchAssignments (seed + focus_hint)
  │   └── adds K root TreeNodes, creates K Branches
  └── for round in 1..N:
      ├── ThreadPoolExecutor: for each Branch in parallel:
      │     branch.step_branch(branch, tree, worker, …)
      │       ├── append user turn (round-1 seed/hint OR prev-round probe feedback)
      │       ├── mutator LLM call with full chat history
      │       ├── extract code; append assistant turn
      │       └── worker.evaluate(policy_code, benchmark_script, timeout)
      │            →  LocalWorker.evaluate()  or  SSHWorker.evaluate() (stdin-piped)
      │            →  evaluator.evaluate()  →  EvaluationResult
      ├── main thread: tree.add_node() for each BranchStepResult  (tree is single-threaded)
      ├── persist tree.json + round_N.json + best_policy.c
      └── every checkpoint_interval rounds:
            frontier.run_frontier_checkpoint() → reshape active branches
              (continue / kill / pivot / spawn)
```

Chat-history compaction: only the **most recent** assistant turn on each branch retains the full code block; earlier assistant turns are replaced with `[full code elided]` + their leading prose. Keeps context size bounded as rounds accumulate.

## Evaluator Conventions

Environment variables a launch script receives from `evaluator.evaluate()`:

| Var | Purpose |
|---|---|
| `POLICY_BINARY` | Absolute path to the compiled `evo_policy.out` loader |
| `CACHE_EXT_CGROUP` | Benchmark cgroup to run the workload under |
| `POLICY_METRICS_OUT` | Path the loader MAY dump counter JSON to |
| `JOB_DIR` | Per-run scratch directory |

Cgroup discovery (in `evaluate.py`): `--cgroup` flag → `$CACHE_EXT_CGROUP` → `/run/evo_cache/cgroup.path` sentinel. `setup_isolation.sh` is expected to write the sentinel when it creates the cgroup.

**Policy counters** (optional convention): a policy's userspace loader may write `$POLICY_METRICS_OUT` as a JSON object `{counter_name: int}` on exit. The `PolicyCountersProbe` reads this and surfaces the counters in LLM feedback. Standard counter names: `evictions`, `promotions`, `ghost_hits`, `queue_fulls` + up to 4 custom slots.

## Runtime Requirements

- Must run on the custom `6.6.8-cache-ext` kernel (eBPF cache_ext struct_ops).
- System deps: clang-14, bpftool, libbpf, build-essential, libelf-dev.
- Python deps: `anthropic`, `openai`, `pyyaml`, `requests`, `tomli` (< 3.11). See `requirements.txt`.
- **Coordinator**: runs `evolve.py`. Needs LLM API key, Python deps, `clang-14` + `bpftool` (for compilation), and SSH access to every worker host (used ONCE at provision time by `start_workers.sh`).
- **Worker nodes**: run `worker_server.py`. Need Python 3, the repo cloned at the expected path, the custom kernel booted, and `setup_isolation.sh` already executed (so `/sys/fs/cgroup/cache_ext_bench` exists). Workers do NOT need clang/bpftool — the coordinator ships pre-compiled `.out` binaries.
- **Network**: coordinator → worker HTTP (default port 8080) at runtime. Worker → worker connectivity is NOT required (intentional — matches CloudLab setups with no inter-node SSH).

## Policy Code Pattern

Policies are combined C files with two sections:
```
// SECTION: BPF KERNEL CODE
// EVOLVE-BLOCK-START
...
// EVOLVE-BLOCK-END

// SECTION: USERSPACE LOADER
// EVOLVE-BLOCK-START
...
// EVOLVE-BLOCK-END
```
`targets/code_splitter.py` splits them into `cache_ext/policies/evo_policy.bpf.c` and `evo_policy.c`. The shared header `cache_ext/policies/cache_ext_lib.bpf.h` provides list helpers. Existing policies in `cache_ext/policies/` and `cache_policy_evolution/seeds/` are references.

## Notes for Future Work

- **Baseline normalization**: `EvaluationResult.score` is currently raw (weighted probe values). The evolution loop could normalize against the seed round's probe values for clearer LLM feedback (`[better]` / `[worse]` annotations).
- **More probes**: `perf stat` and `bpftrace` latency histograms were scoped out of v1; add as continuous probes (extend `Probe` with `start()` / `stop()` phases).
- **`policy_counters` in seeds**: seeds don't populate the counter map yet. Adding a tiny helper in `cache_ext_lib.bpf.h` + loader exit hook would unlock self-introspection feedback for every evolved policy.
