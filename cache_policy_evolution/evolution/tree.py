from __future__ import annotations

import datetime
import json
import uuid
from dataclasses import dataclass, field, asdict
from typing import Any, Dict, List, Optional


@dataclass
class TreeNode:
    """A single node in the evolution tree, representing one policy variant."""

    node_id: str
    parent_id: Optional[str]
    code: str
    score: float
    details: Dict[str, Any]
    error: str
    round_num: int
    depth: int
    strategy: str
    mutation_description: str
    timestamp: str
    seed_origin: str
    children_ids: List[str] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)


class EvolutionTree:
    """Tree-based tracker for the full evolution history of cache policies.

    Each node represents a policy variant produced by mutation, backtracking,
    or restart. The tree supports querying lineage, identifying dead ends,
    extracting the best-performing branch, and generating compact LLM-friendly
    summaries.
    """

    def __init__(self, metadata: Optional[Dict[str, Any]] = None) -> None:
        self.nodes: Dict[str, TreeNode] = {}
        self.root_ids: List[str] = []
        self.current_node_id: Optional[str] = None
        self.best_node_id: Optional[str] = None
        self.metadata: Dict[str, Any] = metadata if metadata is not None else {}

    # ------------------------------------------------------------------
    # Core mutation
    # ------------------------------------------------------------------

    def add_node(
        self,
        parent_id: Optional[str],
        code: str,
        score: float,
        details: Dict[str, Any],
        error: str,
        strategy: str,
        mutation_description: str,
        seed_origin: str,
        round_num: int,
    ) -> TreeNode:
        """Create a new node, wire parent/child links, and update bookkeeping."""

        node_id = uuid.uuid4().hex[:8]
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

        # Compute depth from parent.
        if parent_id is not None:
            parent = self.nodes[parent_id]
            depth = parent.depth + 1
        else:
            depth = 0

        # Auto-tags based on error content.
        tags: List[str] = []
        if error:
            error_lower = error.lower()
            if "compilation" in error_lower or "compile" in error_lower:
                tags.append("compilation_failure")
            if "syntax" in error_lower:
                tags.append("syntax_error")

        node = TreeNode(
            node_id=node_id,
            parent_id=parent_id,
            code=code,
            score=score,
            details=details,
            error=error,
            round_num=round_num,
            depth=depth,
            strategy=strategy,
            mutation_description=mutation_description,
            timestamp=timestamp,
            seed_origin=seed_origin,
            children_ids=[],
            tags=tags,
        )

        self.nodes[node_id] = node

        # Link parent -> child.
        if parent_id is not None:
            self.nodes[parent_id].children_ids.append(node_id)
        else:
            self.root_ids.append(node_id)

        # Update best. Only evaluated, error-free nodes can be "best" —
        # seed roots (depth 0, no evaluation) and failed runs carry score
        # 0.0 which would otherwise beat any real negative-weighted score.
        if depth > 0 and not error:
            best = self.nodes.get(self.best_node_id) if self.best_node_id else None
            if best is None or score > best.score:
                self.best_node_id = node_id

        self.current_node_id = node_id
        return node

    # ------------------------------------------------------------------
    # Queries
    # ------------------------------------------------------------------

    def get_node(self, node_id: str) -> TreeNode:
        """Return the node with the given ID (raises KeyError if missing)."""
        return self.nodes[node_id]

    def get_ancestors(self, node_id: str) -> List[TreeNode]:
        """Walk the parent chain from *node_id* up to the root (inclusive)."""
        path: List[TreeNode] = []
        current: Optional[str] = node_id
        while current is not None:
            node = self.nodes[current]
            path.append(node)
            current = node.parent_id
        return path

    def get_branch(self, node_id: str) -> List[TreeNode]:
        """Return the root-to-node path (reversed ancestor list)."""
        return list(reversed(self.get_ancestors(node_id)))

    def get_children(self, node_id: str) -> List[TreeNode]:
        """Return direct children of a node."""
        return [self.nodes[cid] for cid in self.nodes[node_id].children_ids]

    def get_best_nodes(self, n: int = 5) -> List[TreeNode]:
        """Return the top *n* nodes sorted by score descending."""
        ranked = sorted(self.nodes.values(), key=lambda nd: nd.score, reverse=True)
        return ranked[:n]

    def get_dead_ends(self) -> List[TreeNode]:
        """Identify leaf nodes that are dead ends.

        A leaf is a dead end when:
        - Its score has *declined* over the last 2+ ancestors, OR
        - The last 2+ nodes on its branch all have errors.
        """
        dead: List[TreeNode] = []
        for node in self._leaf_nodes():
            ancestors = self.get_ancestors(node.node_id)  # node … root
            if len(ancestors) >= 3:
                # Check declining scores over last 3 (node, parent, grandparent).
                recent = ancestors[:3]
                if all(recent[i].score <= recent[i + 1].score for i in range(2)):
                    # Strictly declining or flat — consider dead if at least one strict decline.
                    if any(recent[i].score < recent[i + 1].score for i in range(2)):
                        dead.append(node)
                        continue
            if len(ancestors) >= 2:
                recent = ancestors[:2]
                if all(a.error for a in recent):
                    dead.append(node)
                    continue
        return dead

    def get_frontier(self) -> List[TreeNode]:
        """Return all leaf nodes (nodes with no children)."""
        return self._leaf_nodes()

    def depth_stats(self) -> Dict[str, Any]:
        """Aggregate depth statistics across the tree."""
        if not self.nodes:
            return {"max_depth": 0, "avg_depth": 0.0, "num_branches": 0, "total_nodes": 0}
        depths = [n.depth for n in self.nodes.values()]
        return {
            "max_depth": max(depths),
            "avg_depth": round(sum(depths) / len(depths), 2),
            "num_branches": len(self.root_ids),
            "total_nodes": len(self.nodes),
        }

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------

    def to_dict(self) -> Dict[str, Any]:
        """Serialize the full tree to a plain dict."""
        return {
            "nodes": {nid: asdict(node) for nid, node in self.nodes.items()},
            "root_ids": self.root_ids,
            "current_node_id": self.current_node_id,
            "best_node_id": self.best_node_id,
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> EvolutionTree:
        """Deserialize a tree from a plain dict."""
        tree = cls(metadata=data.get("metadata", {}))
        for nid, nd in data.get("nodes", {}).items():
            tree.nodes[nid] = TreeNode(**nd)
        tree.root_ids = data.get("root_ids", [])
        tree.current_node_id = data.get("current_node_id")
        tree.best_node_id = data.get("best_node_id")
        return tree

    def save(self, path: str) -> None:
        """Write the tree as JSON to *path*."""
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.to_dict(), fh, indent=2, ensure_ascii=False)

    @classmethod
    def load(cls, path: str) -> EvolutionTree:
        """Read a tree from a JSON file at *path*."""
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return cls.from_dict(data)

    # ------------------------------------------------------------------
    # Summary for LLM context
    # ------------------------------------------------------------------

    def to_summary(self, max_tokens: int = 4000) -> str:
        """Generate a compact text summary suitable for LLM context injection.

        Sections are appended in priority order until the estimated token
        budget (``max_tokens``, approximated as ``len(text) // 4``) is
        exhausted.
        """
        sections: List[str] = [
            self._section_overview(),
            self._section_best_path(),
            self._section_current_branch(),
            self._section_top_performers(),
            self._section_dead_ends(),
            self._section_branch_structure(),
        ]

        result_parts: List[str] = []
        used_tokens = 0
        for section in sections:
            if not section:
                continue
            est = len(section) // 4
            if used_tokens + est > max_tokens:
                # Try to fit a truncated version.
                remaining_chars = (max_tokens - used_tokens) * 4
                if remaining_chars > 80:
                    result_parts.append(section[:remaining_chars].rsplit("\n", 1)[0])
                break
            result_parts.append(section)
            used_tokens += est

        return "\n\n".join(result_parts)

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _leaf_nodes(self) -> List[TreeNode]:
        return [n for n in self.nodes.values() if not n.children_ids]

    def _max_round(self) -> int:
        if not self.nodes:
            return 0
        return max(n.round_num for n in self.nodes.values())

    # --- Summary section builders ---

    def _section_overview(self) -> str:
        stats = self.depth_stats()
        lines = [
            f"## Evolution Tree ({stats['total_nodes']} nodes, "
            f"{self._max_round()} rounds, {stats['num_branches']} branches)"
        ]
        if self.best_node_id:
            b = self.nodes[self.best_node_id]
            lines.append(
                f"Best: {b.node_id} (score={b.score}, depth={b.depth}, seed={b.seed_origin})"
            )
        if self.current_node_id:
            c = self.nodes[self.current_node_id]
            lines.append(
                f"Current: {c.node_id} (score={c.score}, depth={c.depth}, seed={c.seed_origin})"
            )
        return "\n".join(lines)

    def _section_best_path(self) -> str:
        if not self.best_node_id:
            return ""
        branch = self.get_branch(self.best_node_id)
        seed = branch[0].seed_origin if branch else "?"
        parts = [f"{n.node_id} ({n.score})" for n in branch]
        if parts:
            parts[-1] += " [BEST]"
        return f"## Best Path ({seed})\n" + " \u2192 ".join(parts)

    def _section_current_branch(self) -> str:
        if not self.current_node_id:
            return ""
        branch = self.get_branch(self.current_node_id)
        seed = branch[0].seed_origin if branch else "?"
        parts = []
        for n in branch:
            desc = n.mutation_description
            short_desc = (desc[:30] + "...") if len(desc) > 33 else desc
            parts.append(f"{n.node_id} ({n.score}, {short_desc})")
        if parts:
            parts[-1] += " [HERE]"

        # Trend from last 3 scores.
        recent_scores = [n.score for n in branch[-3:]]
        trend = "stable"
        if len(recent_scores) >= 2:
            if all(recent_scores[i] < recent_scores[i + 1] for i in range(len(recent_scores) - 1)):
                trend = "improving"
            elif all(recent_scores[i] > recent_scores[i + 1] for i in range(len(recent_scores) - 1)):
                trend = "declining"

        path_str = " \u2192 ".join(parts)
        return (
            f"## Current Branch ({seed})\n"
            f"{path_str}\n"
            f"Trend: {trend} over last {len(recent_scores)} rounds"
        )

    def _section_top_performers(self) -> str:
        top = self.get_best_nodes(5)
        if not top:
            return ""
        lines = ["## Top Performers", f"{'ID':<10} {'Score':>8} {'Depth':>6} {'Strategy':<12} {'Seed'}"]
        lines.append("-" * 52)
        for n in top:
            lines.append(f"{n.node_id:<10} {n.score:>8.4f} {n.depth:>6} {n.strategy:<12} {n.seed_origin}")
        return "\n".join(lines)

    def _section_dead_ends(self) -> str:
        dead = self.get_dead_ends()
        if not dead:
            return ""
        lines = ["## Dead Ends"]
        for n in dead:
            ancestors = self.get_ancestors(n.node_id)
            if len(ancestors) >= 2 and all(a.error for a in ancestors[:2]):
                reason = f"consecutive errors: {n.error[:60]}"
            else:
                scores = [a.score for a in ancestors[:3]]
                arrow = " \u2192 "
                reason = f"declining scores: {arrow.join(f'{s:.4f}' for s in scores)}"
            lines.append(f"- {n.node_id} (depth={n.depth}, seed={n.seed_origin}): {reason}")
        return "\n".join(lines)

    def _section_branch_structure(self) -> str:
        if not self.root_ids:
            return ""
        lines = ["## Branch Structure"]
        for rid in self.root_ids:
            self._render_subtree(rid, indent=0, lines=lines, max_depth=8)
        return "\n".join(lines)

    def _render_subtree(
        self, node_id: str, indent: int, lines: List[str], max_depth: int
    ) -> None:
        node = self.nodes[node_id]
        prefix = "  " * indent
        marker = ""
        if node_id == self.best_node_id:
            marker = " [BEST]"
        elif node_id == self.current_node_id:
            marker = " [HERE]"
        lines.append(f"{prefix}{node.node_id} ({node.score:.4f}, {node.strategy}){marker}")
        if indent >= max_depth and node.children_ids:
            lines.append(f"{prefix}  ...")
            return
        for cid in node.children_ids:
            self._render_subtree(cid, indent + 1, lines, max_depth)
