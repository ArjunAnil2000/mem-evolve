"""Render an EvolutionTree JSON dump as a Graphviz DOT graph (and optional image).

Usage:
    python3 -m tools.view_tree runs/scan_thrash_may_1_2_23/evolution_tree.json
    python3 -m tools.view_tree path/to/tree.json -o tree.svg --format svg
    python3 -m tools.view_tree path/to/tree.json --dot-only > tree.dot
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from typing import Optional

# Allow running both as `python3 -m tools.view_tree` and `python3 tools/view_tree.py`.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from evolution.tree import EvolutionTree, TreeNode


def _color_for(node: TreeNode, best_id: Optional[str], current_id: Optional[str]) -> str:
    if node.error:
        return "#f4cccc"  # red-ish for errored nodes
    if node.node_id == best_id:
        return "#b6d7a8"  # green for best
    if node.node_id == current_id:
        return "#9fc5e8"  # blue for current frontier
    return "#ffffff"


def _label_for(node: TreeNode) -> str:
    score = "ERR" if node.error else f"{node.score:.4f}"
    strategy = node.strategy or "-"
    seed = node.seed_origin or "-"
    desc = (node.mutation_description or "").strip()
    lines = [
        f"{node.node_id}  [r{node.round_num} d{node.depth}]",
        f"score: {score}",
        f"strat: {strategy}  seed: {seed}",
    ]
    if desc:
        lines.extend(desc.split("\n"))
    # Graphviz HTML-escape minimal chars.
    safe = [
        line.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        for line in lines
    ]
    return "\\n".join(safe)


def tree_to_dot(tree: EvolutionTree, title: str = "evolution_tree") -> str:
    lines = [
        f'digraph "{title}" {{',
        '  rankdir=TB;',
        '  node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=10];',
        '  edge [fontname="Helvetica", fontsize=9, color="#666666"];',
    ]
    for nid, node in tree.nodes.items():
        fill = _color_for(node, tree.best_node_id, tree.current_node_id)
        label = _label_for(node)
        lines.append(f'  "{nid}" [label="{label}", fillcolor="{fill}"];')
    for nid, node in tree.nodes.items():
        if node.parent_id:
            lines.append(f'  "{node.parent_id}" -> "{nid}";')
    # Legend.
    lines += [
        '  subgraph cluster_legend {',
        '    label="legend"; style="dashed"; color="#999999"; fontsize=10;',
        '    legend_best  [label="best",    fillcolor="#b6d7a8"];',
        '    legend_curr  [label="current", fillcolor="#9fc5e8"];',
        '    legend_err   [label="errored", fillcolor="#f4cccc"];',
        '    legend_best -> legend_curr -> legend_err [style=invis];',
        '  }',
        '}',
    ]
    return "\n".join(lines)


def render(dot_text: str, out_path: str, fmt: str) -> None:
    if not shutil.which("dot"):
        raise RuntimeError(
            "graphviz `dot` not found on PATH. Install with `sudo apt install graphviz` "
            "or rerun with --dot-only and render elsewhere."
        )
    proc = subprocess.run(
        ["dot", f"-T{fmt}", "-o", out_path],
        input=dot_text.encode("utf-8"),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"dot failed: {proc.stderr.decode('utf-8', 'replace')}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tree_json", help="Path to evolution_tree.json")
    ap.add_argument("-o", "--output", default=None, help="Output image path (default: <tree_json>.svg)")
    ap.add_argument("-f", "--format", default="svg", help="Output format: svg, png, pdf, ... (default: svg)")
    ap.add_argument("--dot-only", action="store_true", help="Print DOT to stdout, do not invoke graphviz")
    ap.add_argument("--summary", action="store_true", help="Also print the text tree summary to stderr")
    args = ap.parse_args()

    tree = EvolutionTree.load(args.tree_json)

    if args.summary:
        print(tree.to_summary(), file=sys.stderr)

    dot_text = tree_to_dot(tree, title=os.path.basename(args.tree_json))

    if args.dot_only:
        sys.stdout.write(dot_text)
        return 0

    out_path = args.output or os.path.splitext(args.tree_json)[0] + f".{args.format}"
    render(dot_text, out_path, args.format)
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
