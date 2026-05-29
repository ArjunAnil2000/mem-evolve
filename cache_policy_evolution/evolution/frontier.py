"""Frontier checkpoint: periodic smart-LLM review that reshapes the branch set.

Every `checkpoint_interval` rounds the coordinator pauses DFS, dumps the
top nodes + active-branch state, and asks a strong model to decide for each
branch: continue / kill / pivot, plus optional spawns rooted at strong
nodes no active branch is exploring.
"""

from __future__ import annotations

import json
import logging
import os
import re
from typing import Any, Dict, List, Optional

from evolution.branch import Branch, reset_branch_for_pivot, spawn_branch
from evolution.tree import EvolutionTree

log = logging.getLogger(__name__)

_PROMPT_PATH = os.path.join(os.path.dirname(__file__), "prompts", "frontier.txt")


def _load_prompt() -> str:
    with open(_PROMPT_PATH) as f:
        return f.read()


def _build_user_prompt(
    tree: EvolutionTree,
    branches: List[Branch],
    round_num: int,
    total_rounds: int,
    top_k: int,
    max_spawn: int,
) -> str:
    top = tree.get_best_nodes(top_k)
    top_lines = ["ID        score   depth strategy       seed"]
    top_lines.append("-" * 52)
    for n in top:
        top_lines.append(
            f"{n.node_id:<10}{n.score:>7.4f} {n.depth:>5} "
            f"{n.strategy:<14} {n.seed_origin}"
        )

    branch_lines = []
    for b in branches:
        try:
            n = tree.get_node(b.current_node_id)
        except KeyError:
            continue
        ancestors = tree.get_ancestors(b.current_node_id)[:3]
        lineage = " ← ".join(f"{a.node_id}({a.score:.3f})" for a in ancestors)
        err_note = f" err={n.error[:40]!r}" if n.error else ""
        branch_lines.append(
            f"- {b.branch_id}: head={n.node_id} score={n.score:.4f} "
            f"depth={n.depth} seed={b.seed_origin} "
            f"pivots={len(b.pivoted_rounds)}{err_note}\n"
            f"    recent: {lineage}"
        )

    tree_summary = tree.to_summary(max_tokens=2500)

    return (
        f"## Checkpoint — round {round_num}/{total_rounds}\n\n"
        f"## Tree summary\n{tree_summary}\n\n"
        f"## Top {len(top)} nodes\n```\n" + "\n".join(top_lines) + "\n```\n\n"
        f"## Active branches ({len(branches)})\n"
        + "\n".join(branch_lines) + "\n\n"
        f"## Constraints\n"
        f"- Return a decision for EACH of the {len(branches)} active branches.\n"
        f"- `spawns`: at most {max_spawn} entries.\n"
        f"- All `target_node_id` values must be existing node ids from above.\n\n"
        "Respond with ONLY the JSON object described in the system prompt."
    )


def _extract_json(text: str) -> Optional[Dict[str, Any]]:
    text = re.sub(r"^\s*```(?:json)?\s*", "", text.strip())
    text = re.sub(r"\s*```\s*$", "", text)
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        pass
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    for i, ch in enumerate(text[start:], start=start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except (json.JSONDecodeError, ValueError):
                    return None
    return None


def run_frontier_checkpoint(
    client: Any,
    model: str,
    temperature: float,
    tree: EvolutionTree,
    branches: List[Branch],
    round_num: int,
    total_rounds: int,
    *,
    top_k: int = 10,
    max_spawn: int = 2,
    next_branch_idx: int = 0,
) -> List[Branch]:
    if not branches:
        log.warning("frontier: called with no active branches; skipping")
        return branches

    user_prompt = _build_user_prompt(
        tree, branches, round_num, total_rounds, top_k, max_spawn,
    )
    log.info("frontier: calling %s for round %d", model, round_num)
    try:
        resp = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": _load_prompt()},
                {"role": "user",   "content": user_prompt},
            ],
            temperature=temperature,
            max_tokens=4096,
        )
        reply = resp.choices[0].message.content or ""
    except Exception as e:
        log.warning("frontier LLM failed: %s — keeping branches unchanged", e)
        return branches

    parsed = _extract_json(reply)
    if not parsed or not isinstance(parsed.get("decisions"), list):
        log.warning("frontier: unparseable JSON; keeping branches unchanged")
        log.debug("reply[:800]=%s", reply[:800])
        return branches

    decisions_raw = parsed.get("decisions", [])
    spawns_raw = parsed.get("spawns", [])[:max_spawn]

    by_id = {b.branch_id: b for b in branches}
    new_branches: List[Branch] = []
    seen = set()

    for d in decisions_raw:
        bid = d.get("branch_id", "")
        action = d.get("action", "continue")
        reason = (d.get("reason") or "")[:500]
        target = d.get("target_node_id")

        if bid not in by_id or bid in seen:
            continue
        seen.add(bid)
        b = by_id[bid]

        if action == "kill":
            log.info("  %s: KILL — %s", bid, reason[:80])
            continue
        if action == "pivot":
            if target and target in tree.nodes:
                tgt = tree.get_node(target)
                log.info("  %s: PIVOT → %s (%.4f) — %s",
                         bid, target, tgt.score, reason[:80])
                reset_branch_for_pivot(b, tgt, reason, round_num)
                new_branches.append(b)
            else:
                log.warning("  %s: invalid pivot target %s; continuing", bid, target)
                new_branches.append(b)
            continue
        log.info("  %s: CONTINUE — %s", bid, reason[:80])
        new_branches.append(b)

    # Branches the LLM omitted → default continue.
    for bid, b in by_id.items():
        if bid not in seen:
            log.warning("  %s: omitted by LLM; defaulting to continue", bid)
            new_branches.append(b)

    # Spawns.
    idx = next_branch_idx
    for s in spawns_raw:
        target = s.get("target_node_id")
        reason = (s.get("reason") or "")[:500]
        if not target or target not in tree.nodes:
            continue
        tgt = tree.get_node(target)
        nb = spawn_branch(idx, tgt, reason, round_num)
        log.info("  SPAWN %s @ %s (%.4f) — %s",
                 nb.branch_id, target, tgt.score, reason[:80])
        new_branches.append(nb)
        idx += 1

    return new_branches
