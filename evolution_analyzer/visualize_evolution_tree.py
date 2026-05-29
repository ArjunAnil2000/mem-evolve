#!/usr/bin/env python3
"""
visualize_evolution_tree.py

Generate a self-contained interactive HTML visualization of an evolutionary
search tree (e.g., evo_policy / BPF cache eviction policy evolution runs).

Usage:
    python3 visualize_evolution_tree.py tree.json
    python3 visualize_evolution_tree.py tree.json -o my_viz.html
    python3 visualize_evolution_tree.py tree.json --title "Run 42"

The output is a single .html file with all data and code embedded — drop it
anywhere, open in a browser, no server or dependencies needed.

Expected input JSON schema (top-level keys):
    nodes:         {node_id: {...}}    keyed dict of nodes
    root_ids:      [node_id, ...]      seed roots (parent_id is None)
    best_node_id:  node_id             highest-scoring node
    current_node_id: node_id           most recent node (optional)
    metadata:      {...}               run metadata (optional)

Each node has at minimum:
    node_id, parent_id, code, score, depth, strategy,
    mutation_description, timestamp, children_ids, tags
And usually:
    details: { ok, error, score, wallclock_sec, probes: {...} }
    seed_origin, round_num, error
"""

from __future__ import annotations
import argparse
import json
import os
import sys
from pathlib import Path


# ──────────────────────────────────────────────────────────────────────────────
# Tree layout — assigns x positions to every node so the tree renders cleanly.
# Algorithm: in-order leaf assignment. Leaves get sequential x slots; internal
# nodes get the average of their children's x. Roots are separated by a gap.
# ──────────────────────────────────────────────────────────────────────────────

def compute_positions(nodes: dict, roots: list[str]) -> dict[str, float]:
    """Return {node_id: x_in_leaf_units} for tidy left-to-right tree layout."""
    positions: dict[str, float] = {}
    leaf_counter = [0.0]
    LEAF_GAP = 1.0
    LINEAGE_GAP = 0.5

    def walk(nid: str) -> float:
        n = nodes[nid]
        children = n.get("children_ids", []) or []
        if not children:
            x = leaf_counter[0]
            leaf_counter[0] += LEAF_GAP
            positions[nid] = x
            return x
        cxs = [walk(c) for c in children]
        x = sum(cxs) / len(cxs)
        positions[nid] = x
        return x

    for r in roots:
        walk(r)
        leaf_counter[0] += LINEAGE_GAP

    return positions


# ──────────────────────────────────────────────────────────────────────────────
# Schema normalization — pull out just what the front-end needs from each node.
# Defensive: every probe / details access is guarded so partial data still works.
# ──────────────────────────────────────────────────────────────────────────────

def _safe_get(d, *path, default=None):
    cur = d
    for k in path:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k)
        if cur is None:
            return default
    return cur


def _compact_probe(p: dict) -> dict:
    """Project a single probe dict down to the fields the front-end uses."""
    if not isinstance(p, dict):
        return {}
    return {
        "value":     p.get("value"),
        "unit":      p.get("unit", "") or "",
        "direction": p.get("direction", "record"),
        "summary":   p.get("summary", "") or "",
        "details":   p.get("details") or {},
    }


def normalize_node(nid: str, n: dict) -> dict:
    """Project a raw node into the compact shape the HTML expects.

    All probes are passed through as a dict so workload-specific probes added
    via TOML (`[[probes]]`) — e.g. `throughput`, `read_p99_latency` — show up
    automatically alongside the default kernel probes.
    """
    details = n.get("details") or {}
    probes_raw = _safe_get(details, "probes", default={}) or {}
    probes_out = {name: _compact_probe(p) for name, p in probes_raw.items()}

    # Prefer the normalized score (range ~[-1, 1]) when present — the raw
    # score field can be a huge weighted sum that breaks the color ramp.
    normalized = _safe_get(details, "normalized", default=None)
    raw_score = float(n.get("score", 0.0))
    norm_score = _safe_get(normalized, "score") if isinstance(normalized, dict) else None
    display_score = float(norm_score) if isinstance(norm_score, (int, float)) else raw_score

    code = n.get("code", "") or ""

    return {
        "id": nid,
        "parent": n.get("parent_id"),
        "children": n.get("children_ids", []) or [],
        "depth": n.get("depth", 0),
        "score": round(display_score, 4),
        "raw_score": raw_score,
        "strategy": n.get("strategy", ""),
        "seed_origin": n.get("seed_origin"),
        "mutation": n.get("mutation_description", "") or "",
        "timestamp": n.get("timestamp", ""),
        "round": n.get("round_num", 0),
        "tags": n.get("tags", []) or [],
        "error": (n.get("error") or "")[:500],
        # Full probe set — JS builds the metric grid + raw-summary lines from this.
        "probes": probes_out,
        # Optional per-probe normalization breakdown (z-score, weight, contribution).
        "normalized": normalized if isinstance(normalized, dict) else None,
        # Source
        "code": code,
        "code_lines": code.count("\n") + 1 if code else 0,
    }


def build_viz_payload(tree: dict) -> dict:
    """Return the JSON payload embedded into the HTML."""
    nodes = tree.get("nodes") or {}
    if not nodes:
        raise ValueError("Input tree has no `nodes` field or it is empty.")

    # Roots: prefer explicit root_ids, fall back to scanning for parent=None
    roots = tree.get("root_ids")
    if not roots:
        roots = [nid for nid, n in nodes.items() if n.get("parent_id") is None]
    if not roots:
        raise ValueError("Could not identify any root nodes (parent_id=None).")

    # Best/current — fall back gracefully if absent
    best_id = tree.get("best_node_id")
    if best_id is None:
        # Highest-scoring node, breaking ties by earliest depth
        best_id = max(nodes.keys(), key=lambda k: (nodes[k].get("score", 0.0), -nodes[k].get("depth", 0)))
    current_id = tree.get("current_node_id", best_id)

    out_nodes = {nid: normalize_node(nid, n) for nid, n in nodes.items()}
    positions = compute_positions(nodes, roots)
    positions = {k: round(v, 3) for k, v in positions.items()}

    metadata_in = tree.get("metadata") or {}
    metadata_out = {
        "mutator_model": _safe_get(metadata_in, "llm", "mutator", "model"),
        "planner_model": _safe_get(metadata_in, "llm", "planner", "model"),
        "mode": metadata_in.get("mode"),
    }

    return {
        "roots": roots,
        "best_id": best_id,
        "current_id": current_id,
        "nodes": out_nodes,
        "positions": positions,
        "metadata": metadata_out,
    }


# ──────────────────────────────────────────────────────────────────────────────
# HTML template. Triple-quoted; the JSON payload is injected at __DATA__.
# Title injected at __TITLE__. Anything user-controllable is JSON-encoded
# before injection so it can't break the surrounding HTML.
# ──────────────────────────────────────────────────────────────────────────────

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>__TITLE__</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Instrument+Serif:ital@0;1&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  :root {
    --bg: #0d1014;
    --bg-2: #14181f;
    --bg-3: #1c2129;
    --border: #2a313c;
    --border-2: #3a424f;
    --text: #e8eaed;
    --text-dim: #9aa3b2;
    --text-faint: #5c6573;
    --accent: #d4a574;
    --good: #6ec07a;
    --good-bg: #1d3923;
    --bad: #d96970;
    --bad-bg: #391e22;
    --neutral: #8893a0;
    --highlight: #f4d27a;
    --link: #88a8d4;
    --mono: 'JetBrains Mono', ui-monospace, monospace;
    --serif: 'Instrument Serif', Georgia, serif;
    --sans: 'Inter', system-ui, sans-serif;
  }
  html, body {
    background: var(--bg); color: var(--text);
    font-family: var(--sans); font-size: 14px; line-height: 1.5;
    min-height: 100vh; -webkit-font-smoothing: antialiased;
  }
  body { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
  header {
    border-bottom: 1px solid var(--border);
    padding: 16px 24px 14px;
    display: flex; justify-content: space-between; align-items: flex-end; gap: 24px;
    flex-shrink: 0; background: var(--bg-2);
  }
  .title-block .eyebrow {
    font-family: var(--mono); font-size: 11px; color: var(--text-faint);
    letter-spacing: 0.12em; text-transform: uppercase; margin-bottom: 4px;
  }
  .title-block h1 {
    font-family: var(--serif); font-size: 32px; font-weight: 400;
    line-height: 1; font-style: italic; letter-spacing: -0.01em;
  }
  .title-block h1 .accent { color: var(--accent); font-style: normal; font-family: var(--mono); font-size: 24px; vertical-align: 0.05em; }
  .title-block .subtitle { margin-top: 6px; color: var(--text-dim); font-size: 13px; max-width: 60ch; }
  .stat-strip { display: flex; gap: 28px; align-items: center; }
  .stat { display: flex; flex-direction: column; align-items: flex-end; }
  .stat .label {
    font-family: var(--mono); font-size: 10px; color: var(--text-faint);
    text-transform: uppercase; letter-spacing: 0.1em;
  }
  .stat .value { font-family: var(--mono); font-size: 16px; font-weight: 500; color: var(--text); margin-top: 2px; line-height: 1; }
  .stat .value.good { color: var(--good); }
  .stat .value.bad { color: var(--bad); }

  main { flex: 1; display: grid; grid-template-columns: 1fr 460px; overflow: hidden; min-height: 0; }
  .tree-pane {
    overflow: auto; padding: 24px; background: var(--bg);
    background-image:
      linear-gradient(var(--bg-2) 1px, transparent 1px),
      linear-gradient(90deg, var(--bg-2) 1px, transparent 1px);
    background-size: 80px 80px; background-position: -1px -1px; position: relative;
  }
  .legend {
    position: sticky; top: 0; left: 0;
    background: rgba(13, 16, 20, 0.92); backdrop-filter: blur(8px);
    border: 1px solid var(--border); border-radius: 4px;
    padding: 10px 14px; margin-bottom: 16px;
    display: flex; align-items: center; gap: 18px;
    font-family: var(--mono); font-size: 11px; color: var(--text-dim);
    z-index: 5; width: max-content;
  }
  .legend-item { display: flex; align-items: center; gap: 6px; }
  .legend-swatch.score-bar {
    width: 80px; height: 8px; border-radius: 1px;
    background: linear-gradient(to right, #b54648, #4a4a4a, #4a8a52);
  }
  .legend-marker { width: 14px; height: 14px; display: inline-flex; align-items: center; justify-content: center; }

  .detail-pane {
    border-left: 1px solid var(--border); background: var(--bg-2);
    overflow: auto; display: flex; flex-direction: column;
  }
  .detail-empty { padding: 80px 32px; text-align: center; color: var(--text-faint); }
  .detail-empty .glyph { font-family: var(--serif); font-style: italic; font-size: 48px; color: var(--text-faint); margin-bottom: 16px; }
  .detail-empty p { font-size: 13px; line-height: 1.6; max-width: 30ch; margin: 0 auto; }
  .detail-content { padding: 20px 24px 32px; }
  .detail-header { border-bottom: 1px solid var(--border); padding-bottom: 14px; margin-bottom: 18px; }
  .detail-id {
    font-family: var(--mono); font-size: 11px; color: var(--text-faint);
    text-transform: uppercase; letter-spacing: 0.1em;
    display: flex; align-items: center; gap: 8px; margin-bottom: 6px;
  }
  .pill {
    display: inline-block; font-family: var(--mono); font-size: 10px;
    padding: 2px 7px; border-radius: 2px;
    border: 1px solid var(--border-2); background: var(--bg-3); color: var(--text-dim);
    text-transform: uppercase; letter-spacing: 0.08em;
  }
  .pill.best { background: #3a3415; border-color: #6e612b; color: var(--highlight); }
  .pill.current { background: #15303a; border-color: #2b5d6e; color: var(--link); }
  .pill.fail { background: var(--bad-bg); border-color: #6e2b2f; color: var(--bad); }
  .detail-score { font-family: var(--mono); font-size: 36px; font-weight: 500; line-height: 1; margin: 8px 0 6px; }
  .detail-score.good { color: var(--good); }
  .detail-score.bad { color: var(--bad); }
  .detail-score.zero { color: var(--neutral); }
  .detail-meta { font-family: var(--mono); font-size: 11px; color: var(--text-faint); display: flex; gap: 14px; flex-wrap: wrap; }

  .section { margin-bottom: 22px; }
  .section h3 {
    font-family: var(--mono); font-size: 10px; color: var(--text-faint);
    text-transform: uppercase; letter-spacing: 0.14em; font-weight: 500;
    margin-bottom: 8px; display: flex; align-items: center; gap: 8px;
  }
  .section h3::after { content: ''; flex: 1; height: 1px; background: var(--border); }
  .mutation-text {
    font-size: 13px; line-height: 1.65; color: var(--text);
    background: var(--bg); border: 1px solid var(--border);
    border-left: 2px solid var(--accent); padding: 12px 14px; border-radius: 0 3px 3px 0;
  }
  .mutation-text.is-seed { border-left-color: var(--neutral); }
  .mutation-text.is-fail { border-left-color: var(--bad); }
  .metric-grid {
    display: grid; grid-template-columns: 1fr 1fr; gap: 1px;
    background: var(--border); border: 1px solid var(--border);
    border-radius: 3px; overflow: hidden;
  }
  .metric { background: var(--bg); padding: 9px 12px; }
  .metric .k {
    font-family: var(--mono); font-size: 9.5px; color: var(--text-faint);
    text-transform: uppercase; letter-spacing: 0.1em; margin-bottom: 2px;
  }
  .metric .v { font-family: var(--mono); font-size: 13px; color: var(--text); }
  .raw-summary {
    font-family: var(--mono); font-size: 11px; color: var(--text-dim);
    background: var(--bg); border: 1px solid var(--border); border-radius: 3px;
    padding: 8px 10px; word-break: break-all; line-height: 1.6;
  }
  .raw-summary + .raw-summary { margin-top: 4px; }
  .raw-summary .key { color: var(--text-faint); }
  .code-toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
  .toolbar-meta { font-family: var(--mono); font-size: 10px; color: var(--text-faint); }
  .copy-btn {
    background: var(--bg); border: 1px solid var(--border-2); color: var(--text-dim);
    font-family: var(--mono); font-size: 10px; text-transform: uppercase; letter-spacing: 0.1em;
    padding: 4px 10px; border-radius: 2px; cursor: pointer; transition: all 0.15s;
  }
  .copy-btn:hover { color: var(--text); border-color: var(--text-dim); }
  .copy-btn.copied { color: var(--good); border-color: var(--good); }
  .code-box { background: var(--bg); border: 1px solid var(--border); border-radius: 3px; overflow: auto; max-height: 380px; }
  .code-box pre { font-family: var(--mono); font-size: 11px; line-height: 1.55; padding: 12px 14px; white-space: pre; color: var(--text-dim); }
  .code-box pre .kw { color: #c8a8e0; }
  .code-box pre .str { color: #b9d094; }
  .code-box pre .com { color: var(--text-faint); font-style: italic; }
  .code-box pre .num { color: #d4a574; }

  .lineage-trail { display: flex; flex-direction: column; gap: 4px; font-family: var(--mono); font-size: 11px; }
  .lineage-step {
    display: flex; align-items: center; gap: 8px;
    padding: 5px 8px; border-radius: 2px; cursor: pointer;
    color: var(--text-dim); transition: background 0.1s;
  }
  .lineage-step:hover { background: var(--bg-3); color: var(--text); }
  .lineage-step.is-current { background: var(--bg-3); color: var(--text); }
  .lineage-step .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .lineage-step .step-id { letter-spacing: 0.05em; }
  .lineage-step .step-score { margin-left: auto; color: var(--text-faint); }

  svg.tree { display: block; }
  .edge { fill: none; stroke: var(--border-2); stroke-width: 1.2; transition: stroke 0.15s, stroke-width 0.15s; }
  .edge.highlight { stroke: var(--highlight); stroke-width: 2; }
  .node-group { cursor: pointer; }
  .node-circle { stroke: var(--bg); stroke-width: 2; transition: r 0.12s, stroke 0.12s; }
  .node-group:hover .node-circle { stroke: var(--text); stroke-width: 2; }
  .node-group.selected .node-circle { stroke: var(--highlight); stroke-width: 2.5; }
  .node-label { font-family: var(--mono); font-size: 9.5px; fill: var(--text-faint); text-anchor: middle; pointer-events: none; user-select: none; }
  .node-group:hover .node-label, .node-group.selected .node-label { fill: var(--text); }
  .lineage-bg { fill: var(--bg-2); opacity: 0.4; }
  .lineage-label { font-family: var(--mono); font-size: 11px; fill: var(--text-faint); letter-spacing: 0.1em; text-transform: uppercase; }
  .lineage-label .seed-name { fill: var(--accent); }
  .depth-grid-line { stroke: var(--border); stroke-width: 0.5; stroke-dasharray: 2 4; opacity: 0.5; }
  .depth-label { font-family: var(--mono); font-size: 9.5px; fill: var(--text-faint); letter-spacing: 0.05em; }
  .crown-marker { fill: var(--highlight); stroke: var(--bg); stroke-width: 1; pointer-events: none; }
  .current-marker { fill: none; stroke: var(--link); stroke-width: 1.5; stroke-dasharray: 2 2; pointer-events: none; }

  ::-webkit-scrollbar { width: 10px; height: 10px; }
  ::-webkit-scrollbar-track { background: var(--bg); }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 0; }
  ::-webkit-scrollbar-thumb:hover { background: var(--border-2); }

  @media (max-width: 1100px) { main { grid-template-columns: 1fr 380px; } }
  @media (max-width: 900px) {
    main { grid-template-columns: 1fr; grid-template-rows: 1fr 50%; }
    .detail-pane { border-left: none; border-top: 1px solid var(--border); }
    header { flex-direction: column; align-items: flex-start; gap: 12px; }
    .stat-strip { width: 100%; justify-content: space-between; gap: 12px; }
  }
</style>
</head>
<body>

<header>
  <div class="title-block">
    <div class="eyebrow">Evolutionary search · BPF cache eviction policy</div>
    <h1><span class="accent">evo_policy</span> evolution tree</h1>
    <div class="subtitle">Three seed strategies, mutated by an LLM across rounds. Each node is a candidate kernel cache eviction policy; score is normalized fitness against the scan-thrash benchmark.</div>
  </div>
  <div class="stat-strip">
    <div class="stat"><div class="label">Nodes</div><div class="value" id="stat-nodes">—</div></div>
    <div class="stat"><div class="label">Lineages</div><div class="value" id="stat-lineages">—</div></div>
    <div class="stat"><div class="label">Max depth</div><div class="value" id="stat-depth">—</div></div>
    <div class="stat"><div class="label">Best score</div><div class="value good" id="stat-best">—</div></div>
    <div class="stat"><div class="label">Failures</div><div class="value bad" id="stat-fail">—</div></div>
  </div>
</header>

<main>
  <div class="tree-pane">
    <div class="legend">
      <div class="legend-item">Score
        <div class="legend-swatch score-bar"></div>
        <span style="color: var(--bad)">−1</span><span style="color:var(--neutral)">0</span><span style="color:var(--good)">+1</span>
      </div>
      <div class="legend-item">
        <span class="legend-marker"><svg width="14" height="14" viewBox="0 0 14 14"><polygon points="7,1 8.7,5.3 13,5.5 9.5,8.3 10.7,12.7 7,10 3.3,12.7 4.5,8.3 1,5.5 5.3,5.3" fill="#f4d27a"/></svg></span>
        best
      </div>
      <div class="legend-item">
        <span class="legend-marker"><svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5.5" fill="none" stroke="#88a8d4" stroke-width="1.5" stroke-dasharray="2 2"/></svg></span>
        latest
      </div>
      <div class="legend-item">
        <span class="legend-marker"><svg width="14" height="14" viewBox="0 0 14 14"><line x1="3" y1="3" x2="11" y2="11" stroke="#d96970" stroke-width="2"/><line x1="11" y1="3" x2="3" y2="11" stroke="#d96970" stroke-width="2"/></svg></span>
        compile fail
      </div>
    </div>
    <div id="tree-host"></div>
  </div>
  <aside class="detail-pane" id="detail-pane">
    <div class="detail-empty">
      <div class="glyph">∅</div>
      <p>Select a node from the tree to inspect its mutation, metrics, and source.</p>
      <p style="margin-top:12px; font-size:11px; font-family:var(--mono);">→ start with the gold-starred node (best)</p>
    </div>
  </aside>
</main>

<script id="evo-data" type="application/json">__DATA__</script>
<script>
(function () {
  const DATA = JSON.parse(document.getElementById('evo-data').textContent);
  const NODES = DATA.nodes;
  const POS = DATA.positions;
  const ROOTS = DATA.roots;
  const BEST = DATA.best_id;
  const CURRENT = DATA.current_id;

  const nodeCount = Object.keys(NODES).length;
  const lineageCount = ROOTS.length;
  const maxDepth = Math.max(...Object.values(NODES).map(n => n.depth));
  const bestScore = NODES[BEST].score;
  const failCount = Object.values(NODES).filter(n => (n.tags || []).includes('compilation_failure')).length;
  document.getElementById('stat-nodes').textContent = nodeCount;
  document.getElementById('stat-lineages').textContent = lineageCount;
  document.getElementById('stat-depth').textContent = maxDepth;
  document.getElementById('stat-best').textContent = bestScore.toFixed(4);
  document.getElementById('stat-fail').textContent = failCount;

  function lerp(a, b, t) { return a + (b - a) * t; }
  function lerpHex(c1, c2, t) {
    const p = h => [parseInt(h.slice(1,3),16), parseInt(h.slice(3,5),16), parseInt(h.slice(5,7),16)];
    const a = p(c1), b = p(c2);
    return `rgb(${Math.round(lerp(a[0], b[0], t))},${Math.round(lerp(a[1], b[1], t))},${Math.round(lerp(a[2], b[2], t))})`;
  }
  function scoreColor(s, isFail) {
    if (isFail) return '#5c6573';
    if (s === 0) return '#5c6573';
    if (s > 0) {
      const t = Math.min(1, s / 0.9);
      return lerpHex('#3a4a3e', '#6ec07a', t);
    } else {
      const t = Math.min(1, -s / 0.7);
      return lerpHex('#4a3a3e', '#d96970', t);
    }
  }

  const NODE_R = 9;
  const COL_W = 110;
  const ROW_H = 78;
  const PAD_L = 110;
  const PAD_T = 50;
  const PAD_B = 60;
  const PAD_R = 50;

  const xMin = Math.min(...Object.values(POS));
  const xMax = Math.max(...Object.values(POS));
  const px = {};
  for (const nid in POS) {
    px[nid] = { x: PAD_L + (POS[nid] - xMin) * COL_W, y: PAD_T + NODES[nid].depth * ROW_H };
  }
  const svgW = PAD_L + (xMax - xMin) * COL_W + PAD_R;
  const svgH = PAD_T + maxDepth * ROW_H + PAD_B;

  const lineageExtents = {};
  ROOTS.forEach(r => {
    let xMinL = Infinity, xMaxL = -Infinity;
    (function walk(id) {
      const x = px[id].x;
      if (x < xMinL) xMinL = x;
      if (x > xMaxL) xMaxL = x;
      (NODES[id].children || []).forEach(walk);
    })(r);
    lineageExtents[r] = { x0: xMinL - 26, x1: xMaxL + 26 };
  });

  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('class', 'tree');
  svg.setAttribute('width', svgW);
  svg.setAttribute('height', svgH);
  svg.setAttribute('viewBox', `0 0 ${svgW} ${svgH}`);

  function countSubtree(id) {
    let n = 1;
    (NODES[id].children || []).forEach(c => n += countSubtree(c));
    return n;
  }

  ROOTS.forEach(r => {
    const ext = lineageExtents[r];
    const rect = document.createElementNS(NS, 'rect');
    rect.setAttribute('x', ext.x0);
    rect.setAttribute('y', PAD_T - 28);
    rect.setAttribute('width', ext.x1 - ext.x0);
    rect.setAttribute('height', svgH - PAD_T - PAD_B + 30);
    rect.setAttribute('class', 'lineage-bg');
    rect.setAttribute('rx', 4);
    svg.appendChild(rect);
    const label = document.createElementNS(NS, 'text');
    label.setAttribute('x', (ext.x0 + ext.x1) / 2);
    label.setAttribute('y', PAD_T - 14);
    label.setAttribute('class', 'lineage-label');
    label.setAttribute('text-anchor', 'middle');
    const seedSpan = document.createElementNS(NS, 'tspan');
    seedSpan.setAttribute('class', 'seed-name');
    seedSpan.textContent = NODES[r].seed_origin || NODES[r].id;
    label.appendChild(seedSpan);
    const sub = document.createElementNS(NS, 'tspan');
    sub.textContent = ` · ${countSubtree(r)} nodes`;
    label.appendChild(sub);
    svg.appendChild(label);
  });

  for (let d = 0; d <= maxDepth; d++) {
    const y = PAD_T + d * ROW_H;
    const line = document.createElementNS(NS, 'line');
    line.setAttribute('x1', PAD_L - 10);
    line.setAttribute('x2', svgW - PAD_R + 10);
    line.setAttribute('y1', y);
    line.setAttribute('y2', y);
    line.setAttribute('class', 'depth-grid-line');
    svg.appendChild(line);
    const lbl = document.createElementNS(NS, 'text');
    lbl.setAttribute('x', 22);
    lbl.setAttribute('y', y + 3);
    lbl.setAttribute('class', 'depth-label');
    lbl.textContent = d === 0 ? 'depth 0' : `${d}`;
    svg.appendChild(lbl);
  }

  const bestPath = new Set();
  let cur = BEST;
  while (cur) { bestPath.add(cur); cur = NODES[cur].parent; }
  const bestEdges = new Set();
  for (const id of bestPath) {
    const p = NODES[id].parent;
    if (p) bestEdges.add(p + '→' + id);
  }

  Object.values(NODES).forEach(n => {
    if (!n.parent) return;
    const p = px[n.parent], c = px[n.id];
    const path = document.createElementNS(NS, 'path');
    const my = (p.y + c.y) / 2;
    path.setAttribute('d', `M ${p.x} ${p.y + NODE_R} C ${p.x} ${my}, ${c.x} ${my}, ${c.x} ${c.y - NODE_R}`);
    let cls = 'edge';
    if (bestEdges.has(n.parent + '→' + n.id)) cls += ' highlight';
    path.setAttribute('class', cls);
    svg.appendChild(path);
  });

  Object.values(NODES).forEach(n => {
    const { x, y } = px[n.id];
    const g = document.createElementNS(NS, 'g');
    g.setAttribute('class', 'node-group');
    g.setAttribute('transform', `translate(${x}, ${y})`);
    g.dataset.nid = n.id;
    const isFail = (n.tags || []).includes('compilation_failure');

    const circle = document.createElementNS(NS, 'circle');
    circle.setAttribute('r', NODE_R);
    circle.setAttribute('class', 'node-circle');
    circle.setAttribute('fill', scoreColor(n.score, isFail));
    g.appendChild(circle);

    if (n.id === BEST) {
      const star = document.createElementNS(NS, 'polygon');
      star.setAttribute('points', '0,-13 2.4,-4 11,-3.6 4,2.5 6,11 0,6 -6,11 -4,2.5 -11,-3.6 -2.4,-4');
      star.setAttribute('class', 'crown-marker');
      g.appendChild(star);
    }
    if (n.id === CURRENT && n.id !== BEST) {
      const ring = document.createElementNS(NS, 'circle');
      ring.setAttribute('r', NODE_R + 5);
      ring.setAttribute('class', 'current-marker');
      g.appendChild(ring);
    }
    if (isFail) {
      [[-4, -4, 4, 4], [4, -4, -4, 4]].forEach(([x1, y1, x2, y2]) => {
        const ln = document.createElementNS(NS, 'line');
        ln.setAttribute('x1', x1); ln.setAttribute('y1', y1);
        ln.setAttribute('x2', x2); ln.setAttribute('y2', y2);
        ln.setAttribute('stroke', '#fff'); ln.setAttribute('stroke-width', 1.5);
        g.appendChild(ln);
      });
    }

    const lbl = document.createElementNS(NS, 'text');
    lbl.setAttribute('y', NODE_R + 14);
    lbl.setAttribute('class', 'node-label');
    if (isFail) lbl.textContent = 'fail';
    else if (n.score === 0 && n.depth === 0) lbl.textContent = 'seed';
    else lbl.textContent = (n.score >= 0 ? '+' : '') + n.score.toFixed(2);
    g.appendChild(lbl);

    const title = document.createElementNS(NS, 'title');
    title.textContent = `${n.id} · depth ${n.depth} · ${n.strategy}\n${n.mutation.slice(0, 200)}`;
    g.appendChild(title);

    g.addEventListener('click', () => selectNode(n.id));
    svg.appendChild(g);
  });

  document.getElementById('tree-host').appendChild(svg);

  let selectedId = null;
  function selectNode(nid) {
    selectedId = nid;
    document.querySelectorAll('.node-group').forEach(el => {
      el.classList.toggle('selected', el.dataset.nid === nid);
    });
    renderDetail(nid);
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  }

  const CKEYWORDS = new Set([
    'if','else','for','while','do','return','static','inline','void','int','char',
    'unsigned','signed','struct','enum','union','typedef','const','volatile','sizeof',
    'switch','case','break','continue','default','goto','extern','register','auto',
    'long','short','double','float','bool','true','false','NULL'
  ]);

  function highlight(src) {
    const out = [];
    let i = 0;
    const n = src.length;
    while (i < n) {
      const ch = src[i], ch2 = src[i+1];
      if (ch === '/' && ch2 === '*') {
        const end = src.indexOf('*/', i + 2);
        const stop = end === -1 ? n : end + 2;
        out.push(['com', src.slice(i, stop)]); i = stop; continue;
      }
      if (ch === '/' && ch2 === '/') {
        let j = i;
        while (j < n && src[j] !== '\n') j++;
        out.push(['com', src.slice(i, j)]); i = j; continue;
      }
      if (ch === '"') {
        let j = i + 1;
        while (j < n) {
          if (src[j] === '\\' && j+1 < n) { j += 2; continue; }
          if (src[j] === '"') { j++; break; }
          j++;
        }
        out.push(['str', src.slice(i, j)]); i = j; continue;
      }
      if (ch === "'") {
        let j = i + 1;
        while (j < n) {
          if (src[j] === '\\' && j+1 < n) { j += 2; continue; }
          if (src[j] === "'") { j++; break; }
          j++;
        }
        out.push(['str', src.slice(i, j)]); i = j; continue;
      }
      if (ch === '#' && (i === 0 || src[i-1] === '\n')) {
        let j = i;
        while (j < n && src[j] !== '\n') j++;
        out.push(['kw', src.slice(i, j)]); i = j; continue;
      }
      if (/[0-9]/.test(ch) && (i === 0 || /[^a-zA-Z0-9_]/.test(src[i-1]))) {
        let j = i;
        if (ch === '0' && (ch2 === 'x' || ch2 === 'X')) {
          j += 2;
          while (j < n && /[0-9a-fA-F]/.test(src[j])) j++;
        } else {
          while (j < n && /[0-9]/.test(src[j])) j++;
        }
        out.push(['num', src.slice(i, j)]); i = j; continue;
      }
      if (/[a-zA-Z_]/.test(ch)) {
        let j = i;
        while (j < n && /[a-zA-Z0-9_]/.test(src[j])) j++;
        const word = src.slice(i, j);
        out.push([CKEYWORDS.has(word) ? 'kw' : 'plain', word]);
        i = j; continue;
      }
      out.push(['plain', ch]); i++;
    }
    let html = '';
    for (const [kind, text] of out) {
      const safe = escapeHtml(text);
      html += kind === 'plain' ? safe : `<span class="${kind}">${safe}</span>`;
    }
    return html;
  }

  function lineageTrail(nid) {
    const trail = [];
    let cur = nid;
    while (cur) { trail.push(cur); cur = NODES[cur].parent; }
    return trail.reverse();
  }

  function fmtScore(s) {
    if (s === 0) return '0.0000';
    return (s >= 0 ? '+' : '') + s.toFixed(4);
  }

  function renderDetail(nid) {
    const n = NODES[nid];
    const isFail = (n.tags || []).includes('compilation_failure');
    const isSeed = n.depth === 0;
    const isBest = nid === BEST;
    const isCurrent = nid === CURRENT;
    const trail = lineageTrail(nid);

    const pills = [];
    pills.push(`<span class="pill">${escapeHtml(n.strategy)}</span>`);
    if (n.seed_origin) pills.push(`<span class="pill" style="color:var(--accent);border-color:#5a4a32">seed: ${escapeHtml(n.seed_origin)}</span>`);
    if (isBest) pills.push('<span class="pill best">★ best</span>');
    if (isCurrent) pills.push('<span class="pill current">latest</span>');
    if (isFail) pills.push('<span class="pill fail">compile fail</span>');

    const scoreCls = n.score > 0 ? 'good' : (n.score < 0 ? 'bad' : 'zero');

    // ── Build the probe grid + raw-summary lines dynamically. Any probe
    //    declared via the TOML's [[probes]] (json_extract, etc.) shows up
    //    here automatically — no edits to this file needed. Known kernel
    //    probes (cgroup_iostat / cgroup_memstat / policy_counters) get a
    //    little extra unpacking; everything else falls through to a plain
    //    "name = value unit" tile + summary line.
    const probes = n.probes || {};
    const probeNames = Object.keys(probes);
    const tiles = [];
    const summaries = [];

    function tile(k, v) { tiles.push(`<div class="metric"><div class="k">${escapeHtml(k)}</div><div class="v">${v}</div></div>`); }
    function fmtNum(x) {
      if (x === null || x === undefined || Number.isNaN(x)) return '—';
      if (typeof x !== 'number') return escapeHtml(String(x));
      if (Math.abs(x) >= 1000) return x.toLocaleString();
      if (Number.isInteger(x)) return String(x);
      return x.toFixed(3);
    }
    function fmtBytes(b) {
      if (b === null || b === undefined) return '—';
      const mib = b / (1024 * 1024);
      return mib >= 1 ? mib.toFixed(1) + ' MiB' : (b / 1024).toFixed(1) + ' KiB';
    }

    for (const pname of probeNames) {
      const p = probes[pname] || {};
      const d = p.details || {};
      if (pname === 'wallclock') {
        tile('wallclock', escapeHtml(p.summary || (p.value != null ? p.value.toFixed(2) + ' s' : '—')));
      } else if (pname === 'cgroup_iostat') {
        tile('read bytes', fmtBytes(d.rbytes));
        tile('read IOs',   fmtNum(d.rios));
        if (d.wbytes) tile('write bytes', fmtBytes(d.wbytes));
      } else if (pname === 'cgroup_memstat') {
        const delta = d.delta || {};
        tile('refaults',     fmtNum(delta.workingset_refault_file));
        tile('major faults', fmtNum(delta.pgmajfault));
        tile('activations',  fmtNum(delta.pgactivate));
        if (delta.pgsteal != null) tile('pgsteal', fmtNum(delta.pgsteal));
      } else if (pname === 'policy_counters') {
        // Surface every counter, not just evictions/promotions.
        for (const [ck, cv] of Object.entries(d)) {
          if (typeof cv === 'number') tile(ck, fmtNum(cv));
        }
      } else {
        // Generic path: workload-specific probes (json_extract, etc.).
        const u = p.unit ? ' ' + escapeHtml(p.unit) : '';
        tile(pname, fmtNum(p.value) + u);
      }
      if (p.summary) {
        summaries.push(`<div class="raw-summary"><span class="key">${escapeHtml(pname)} ▸ </span>${escapeHtml(p.summary)}</div>`);
      }
    }

    let metricsHtml = '';
    if (probeNames.length) {
      metricsHtml = `
        <div class="section">
          <h3>Benchmark probes</h3>
          <div class="metric-grid">${tiles.join('')}</div>
          <div style="height:6px"></div>
          ${summaries.join('')}
        </div>`;
    } else if (isSeed) {
      metricsHtml = `<div class="section"><h3>Benchmark probes</h3><div style="font-size:12px;color:var(--text-faint);font-family:var(--mono);padding:8px 0">seed nodes are not evaluated · score 0.0000</div></div>`;
    }

    // ── Score breakdown: per-probe normalized contribution if available.
    let breakdownHtml = '';
    const norm = n.normalized;
    if (norm && norm.components && Object.keys(norm.components).length) {
      const rows = Object.entries(norm.components).map(([pname, c]) => {
        const z = (c.z != null) ? c.z.toFixed(2) : '—';
        const w = (c.weight != null) ? c.weight : '—';
        const contrib = (c.contribution != null) ? (c.contribution >= 0 ? '+' : '') + c.contribution.toFixed(3) : '—';
        const cls = (c.contribution != null && c.contribution > 0) ? 'good' : (c.contribution != null && c.contribution < 0 ? 'bad' : 'zero');
        return `<div class="metric"><div class="k">${escapeHtml(pname)} · w=${w}</div><div class="v"><span class="detail-score ${cls}" style="font-size:13px">${contrib}</span> <span style="color:var(--text-faint);font-size:10px">z=${z}</span></div></div>`;
      }).join('');
      const skipped = (norm.skipped || []).length
        ? `<div class="raw-summary" style="margin-top:6px"><span class="key">skipped ▸ </span>${escapeHtml(norm.skipped.join(', '))}</div>`
        : '';
      breakdownHtml = `
        <div class="section">
          <h3>Score breakdown · ${escapeHtml(norm.squash || 'raw')}</h3>
          <div class="metric-grid">${rows}</div>
          ${skipped}
        </div>`;
    }

    let errorHtml = '';
    if (n.error) {
      errorHtml = `
        <div class="section">
          <h3>Error</h3>
          <div class="raw-summary" style="color:var(--bad);border-color:#6e2b2f;background:var(--bad-bg)">${escapeHtml(n.error)}</div>
        </div>`;
    }

    const trailHtml = trail.map(tid => {
      const t = NODES[tid];
      const tIsFail = (t.tags || []).includes('compilation_failure');
      const dotColor = scoreColor(t.score, tIsFail);
      const cls = tid === nid ? 'lineage-step is-current' : 'lineage-step';
      const scoreLabel = tIsFail ? 'fail' : (t.depth === 0 ? 'seed' : fmtScore(t.score));
      return `<div class="${cls}" data-trail-id="${tid}">
        <span class="dot" style="background:${dotColor}"></span>
        <span class="step-id">d${t.depth} · ${tid}</span>
        <span class="step-score">${scoreLabel}</span>
      </div>`;
    }).join('');

    const ts = n.timestamp ? new Date(n.timestamp).toLocaleString() : '—';
    const pane = document.getElementById('detail-pane');
    pane.innerHTML = `
      <div class="detail-content">
        <div class="detail-header">
          <div class="detail-id"><span>node ${escapeHtml(nid)}</span></div>
          <div style="display:flex;flex-wrap:wrap;gap:5px;margin:6px 0 8px">${pills.join('')}</div>
          <div class="detail-score ${scoreCls}">${fmtScore(n.score)}</div>
          <div class="detail-meta">
            <span>depth ${n.depth}</span>
            <span>round ${n.round}</span>
            <span>${n.code_lines} loc</span>
            <span>${ts}</span>
          </div>
        </div>
        <div class="section">
          <h3>Mutation rationale</h3>
          <div class="mutation-text ${isSeed ? 'is-seed' : ''} ${isFail ? 'is-fail' : ''}">${escapeHtml(n.mutation)}</div>
        </div>
        ${metricsHtml}
        ${breakdownHtml}
        ${errorHtml}
        <div class="section">
          <h3>Lineage</h3>
          <div class="lineage-trail">${trailHtml}</div>
        </div>
        <div class="section">
          <h3>Source</h3>
          <div class="code-toolbar">
            <span class="toolbar-meta">${n.code_lines} lines · BPF + userspace loader</span>
            <button class="copy-btn" id="copy-btn">Copy</button>
          </div>
          <div class="code-box"><pre>${highlight(n.code || '')}</pre></div>
        </div>
      </div>
    `;

    pane.querySelectorAll('[data-trail-id]').forEach(el => {
      el.addEventListener('click', () => selectNode(el.dataset.trailId));
    });
    const btn = document.getElementById('copy-btn');
    btn.addEventListener('click', () => {
      navigator.clipboard.writeText(n.code || '').then(() => {
        btn.textContent = 'Copied'; btn.classList.add('copied');
        setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('copied'); }, 1500);
      });
    });
    pane.scrollTop = 0;
  }

  selectNode(BEST);
  setTimeout(() => {
    const treePane = document.querySelector('.tree-pane');
    const bestX = px[BEST].x;
    treePane.scrollLeft = Math.max(0, bestX - treePane.clientWidth / 2);
  }, 0);
})();
</script>
</body>
</html>
"""


def render_html(payload: dict, title: str) -> str:
    """Inject the JSON payload into the HTML template."""
    # JSON-encode the payload, then defang any "</script" sequences that might
    # appear inside string values (unlikely in this schema, but cheap insurance).
    data_str = json.dumps(payload, separators=(",", ":"))
    data_str = data_str.replace("</script", "<\\/script")

    # Title is plain text — escape minimally for safe interpolation in <title>.
    safe_title = (
        title.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
    )

    return HTML_TEMPLATE.replace("__TITLE__", safe_title).replace("__DATA__", data_str)


# ──────────────────────────────────────────────────────────────────────────────
# CLI
# ──────────────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Render an evolutionary search tree as an interactive HTML page.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Example:\n"
            "    python3 visualize_evolution_tree.py tree.json\n"
            "    python3 visualize_evolution_tree.py tree.json -o run42.html --title 'Run 42'\n"
        ),
    )
    parser.add_argument("input", help="path to evolution tree JSON file")
    parser.add_argument(
        "-o", "--output",
        help="output HTML path (default: <input_stem>.html alongside input)",
    )
    parser.add_argument(
        "--title",
        default="evo_policy — evolution tree",
        help="page title shown in browser tab (default: 'evo_policy — evolution tree')",
    )
    parser.add_argument(
        "--quiet", "-q", action="store_true",
        help="suppress informational output",
    )
    args = parser.parse_args(argv)

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"error: input file not found: {in_path}", file=sys.stderr)
        return 1
    if not in_path.is_file():
        print(f"error: input is not a file: {in_path}", file=sys.stderr)
        return 1

    out_path = Path(args.output) if args.output else in_path.with_suffix(".html")

    try:
        with in_path.open("r", encoding="utf-8") as f:
            tree = json.load(f)
    except json.JSONDecodeError as e:
        print(f"error: {in_path} is not valid JSON: {e}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"error: could not read {in_path}: {e}", file=sys.stderr)
        return 1

    try:
        payload = build_viz_payload(tree)
    except (KeyError, ValueError, TypeError) as e:
        print(f"error: tree does not match expected schema: {e}", file=sys.stderr)
        return 1

    html = render_html(payload, args.title)

    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w", encoding="utf-8") as f:
            f.write(html)
    except OSError as e:
        print(f"error: could not write {out_path}: {e}", file=sys.stderr)
        return 1

    if not args.quiet:
        n_nodes = len(payload["nodes"])
        n_lineages = len(payload["roots"])
        best_score = payload["nodes"][payload["best_id"]]["score"]
        size_kb = os.path.getsize(out_path) / 1024
        print(f"✓ rendered {n_nodes} nodes across {n_lineages} lineage(s)")
        print(f"  best: {payload['best_id']} ({best_score:+.4f})")
        print(f"  → {out_path}  ({size_kb:.1f} KB)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
