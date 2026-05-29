# evo_cache

**evo_cache** automatically evolves Linux page-cache eviction policies using
LLM-driven code generation. Policies are written as eBPF programs against the
[`cache_ext`](https://github.com/cache-ext/cache_ext) kernel (a custom 6.6.8
build from the SOSP 2025 *cache_ext* paper). A Python coordinator mutates
policies across parallel search branches, evaluates each candidate on a
cgroup-isolated benchmark, and feeds kernel-level probe measurements back to the
LLM so the next mutation is informed by real performance data.

## How it works

```
evolve.py  →  evolution.loop.evolve(cfg)
  ├── planner picks K seed policies (LRU, FIFO, S3-FIFO, …) + a focus hint each
  ├── each seed becomes the root of a search branch
  └── for each round, in parallel across branches:
        ├── mutator LLM proposes a new policy from the branch's history + last
        │   round's probe feedback
        ├── the policy is compiled (BPF + userspace loader) and run under a
        │   benchmark cgroup on a worker node
        ├── probes read kernel counters (refaults, bytes read, wallclock, …)
        └── results are recorded in the evolution tree
      every few rounds a "frontier" reviewer reshapes branches
      (continue / kill / pivot / spawn).
```

Each candidate is measured with **workload-agnostic probes** that read kernel
counters rather than parsing benchmark output:

| Probe | Signal |
|---|---|
| `WallclockProbe` | total runtime |
| `CgroupIostatProbe` | `rbytes` — bytes the workload had to read from disk |
| `CgroupMemstatProbe` | `workingset_refault_file` — direct refault count |
| `PolicyCountersProbe` | optional counters a policy dumps on exit |

## Repository layout

- **`cache_policy_evolution/`** — the coordinator (Python).
  - `evolve.py` — CLI entry point; loads a TOML config and runs the loop.
  - `evaluator/` — standalone policy evaluator: compile a policy, run it under a
    cgroup, collect probe results. Usable as a library or `python3 -m evaluator.evaluate`.
  - `evolution/` — the parallel branch search: evolution tree, per-branch LLM
    chat history, frontier reviewer, seed planner, and the main `evolve()` loop.
  - `worker_server.py` — stdlib HTTP daemon that runs on each worker node and
    evaluates compiled policies sent by the coordinator.
  - `targets/` — compilation helpers (split combined `.c` into BPF + loader).
  - `seeds/` — seed policies: `fifo.c`, `lru.c`, `mru.c`, `s3_fifo.c`, `scan_resist.c`, `noop.c`.
  - `eval/` — benchmark setup + run scripts (scan-thrash, filebench, YCSB/RocksDB, Twitter/LevelDB).
  - `examples/` — small self-contained demos.
  - `*.toml` — example run configs.
- **`evolution_analyzer/`** — single-file script that renders an evolution-tree
  JSON into a self-contained interactive HTML page.
- **`claude_api/`** — a small OpenAI-compatible proxy backed by the Claude Code
  CLI, so the coordinator's OpenAI client can talk to Claude Code locally.
- **CloudLab provisioning helpers** — `setup_cloudlab.sh`, `setup_main_node.sh`,
  `start_workers.sh`, `parse_ssh.sh`.
- **`cache_ext/`** — the custom kernel + eBPF runtime, pulled in as a git submodule.

## Quickstart

```bash
git clone --recurse-submodules <this-repo>
cd evo_cache/cache_policy_evolution
pip install -r requirements.txt
export ANTHROPIC_API_KEY=...        # or set api_key_env in your TOML

# Run locally (workers = [] in the config → single in-process worker):
python3 evolve.py scan_thrash.toml
python3 evolve.py scan_thrash.toml --rounds 30
python3 evolve.py scan_thrash.toml --resume
```

To distribute evaluation across nodes, launch a worker daemon on each host and
list their URLs in the config:

```bash
# on each worker:
python3 worker_server.py --port 8080
```
```toml
# in your TOML:
workers = ["http://host1:8080", "http://host2:8080"]
```

## Requirements

- Must run on the custom `6.6.8-cache-ext` kernel (eBPF `cache_ext` struct_ops).
  See the [`cache_ext`](https://github.com/cache-ext/cache_ext) submodule for
  build/install scripts.
- System deps: `clang-14`, `bpftool`, `libbpf`, `build-essential`, `libelf-dev`.
- Python deps: see `cache_policy_evolution/requirements.txt`.
- An LLM API key (Anthropic by default; any OpenAI-compatible endpoint works via
  the `llm_adapter`).

The coordinator needs `clang`/`bpftool` (it compiles policies and ships
pre-built binaries to workers). Worker nodes only need Python 3, the booted
custom kernel, and the benchmark cgroup set up.

See [`CLAUDE.md`](CLAUDE.md) for a deeper architecture reference.
