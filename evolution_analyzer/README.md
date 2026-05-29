# visualize_evolution_tree

A single-file Python script that turns an evolutionary search tree JSON into a
self-contained interactive HTML page — same visualization style used for the
`evo_policy` BPF cache eviction runs.

## Requirements

Python 3.9+ standard library only. No `pip install` needed.

## Usage

```bash
python3 visualize_evolution_tree.py tree.json
```

That writes `tree.html` next to your input. Open it in any browser — all data
and code are embedded inline, no server needed, works offline (the only
external dependency is Google Fonts; if blocked, you get a system-font
fallback that still looks fine).

### Options

```
python3 visualize_evolution_tree.py INPUT [-o OUTPUT] [--title TITLE] [--quiet]
```

| Flag             | Meaning                                                              |
| ---------------- | -------------------------------------------------------------------- |
| `INPUT`          | Path to the tree JSON file (positional, required).                   |
| `-o, --output`   | Output HTML path. Default: `<input_stem>.html` next to input.        |
| `--title`        | Browser tab title. Default: `evo_policy — evolution tree`.           |
| `-q, --quiet`    | Suppress the summary line.                                           |

### Examples

```bash
# Simplest case — writes tree.html next to tree.json
python3 visualize_evolution_tree.py tree.json

# Custom output path and tab title
python3 visualize_evolution_tree.py runs/exp42.json -o reports/exp42.html --title "Experiment 42"

# Pipe through find for a batch of runs
find runs/ -name 'tree.json' | while read f; do
    python3 visualize_evolution_tree.py "$f"
done
```

## What it shows

- Tree topology with one band per seed lineage, depth on the y-axis.
- Nodes colored by score on a diverging red → neutral → green ramp.
- Gold star marks `best_node_id`; dashed ring marks `current_node_id`;
  white X marks any node tagged `compilation_failure`.
- The path from the seed to the best node is highlighted in gold.
- Click any node for full details on the right: mutation rationale, all
  benchmark probes (wallclock, refaults, IO bytes, evictions, promotions),
  the lineage trail back to the seed (clickable), and the full BPF +
  userspace source with C syntax highlighting and a one-click copy button.

## Expected JSON schema

Top-level keys:

```jsonc
{
  "nodes": { "<id>": { ... } },        // required, keyed dict
  "root_ids": ["<id>", ...],           // optional, inferred from parent_id=null
  "best_node_id": "<id>",              // optional, defaults to highest-score
  "current_node_id": "<id>",           // optional, defaults to best
  "metadata": { ... }                  // optional
}
```

Per-node fields the script reads:

| Field                  | Required | Notes                                              |
| ---------------------- | -------- | -------------------------------------------------- |
| `node_id`              | yes      | Must match the dict key.                           |
| `parent_id`            | yes      | `null` for roots.                                  |
| `children_ids`         | yes      | List of child ids.                                 |
| `code`                 | yes      | Source code shown in the detail pane.              |
| `score`                | yes      | Float; 0 treated as neutral / unevaluated seed.    |
| `depth`                | yes      | Used for the y-axis layout.                        |
| `strategy`             | yes      | Shown as a pill (e.g. `seed`, `mutate`).           |
| `mutation_description` | yes      | Shown verbatim as the rationale block.             |
| `timestamp`            | yes      | ISO 8601 string.                                   |
| `tags`                 | yes      | List; `compilation_failure` triggers fail marker.  |
| `seed_origin`          | optional | Shown as the lineage band label (e.g. `mru`).      |
| `round_num`            | optional | Shown in detail meta line.                         |
| `error`                | optional | Shown in red Error section if non-empty.           |
| `details.probes.*`     | optional | `wallclock`, `cgroup_iostat`, `cgroup_memstat`, `policy_counters`. Each with a `summary` string and `details` dict. |

Missing optional fields are handled gracefully — e.g. a seed node with no
probes shows "seed nodes are not evaluated" instead of an empty grid; trees
without `metadata.llm` work fine.

## Exit codes

- `0` — success
- `1` — input not found, invalid JSON, or schema mismatch (error printed to stderr)
