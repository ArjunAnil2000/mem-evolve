"""Planner: smart-LLM seed-picker run once at the start of a run.

Inputs:  workload description + list of available seeds (name, one-liner).
Output:  K branch assignments {seed, rationale, focus_hint}.

The focus_hint becomes the first user instruction on each branch — so the
planner effectively bootstraps each DFS with a concrete hypothesis.
"""

from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

log = logging.getLogger(__name__)

_PROMPT_PATH = os.path.join(os.path.dirname(__file__), "prompts", "planner.txt")


@dataclass
class BranchAssignment:
    seed: str
    rationale: str
    focus_hint: str


def _load_prompt() -> str:
    with open(_PROMPT_PATH) as f:
        return f.read()


def _is_boilerplate_comment(text: str) -> bool:
    """True for the `// ====` / `// SECTION: ...` / `// EVOLVE-BLOCK-*`
    markers every seed file starts with — never real description text."""
    if not text:
        return True
    if set(text) <= {"="}:
        return True
    if text.startswith("SECTION:"):
        return True
    if text in ("EVOLVE-BLOCK-START", "EVOLVE-BLOCK-END"):
        return True
    return False


def _summarise_seed(seed_code: str, max_chars: int = 400) -> str:
    """Grab the first real descriptive comment near the top of a seed file.

    Every seed starts with the `// ====` / `// SECTION: ...` /
    `// EVOLVE-BLOCK-START` boilerplate before any actual prose, so those
    lines (and any non-comment lines, e.g. #include, in between) are
    skipped while searching for a genuine description.
    """
    lines = seed_code.splitlines()
    summary_lines = []
    for ln in lines[:30]:
        s = ln.strip()
        if not s:
            if summary_lines:
                break
            continue
        if s.startswith("//"):
            text = s.lstrip("/").strip()
            if _is_boilerplate_comment(text):
                continue
            summary_lines.append(text)
        elif s.startswith("/*") or s.startswith("*"):
            text = s.lstrip("/* ").strip()
            if text and not _is_boilerplate_comment(text):
                summary_lines.append(text)
        elif summary_lines:
            break
    text = " ".join(summary_lines).strip()
    if not text:
        # Fallback: just name the first interesting helper.
        for ln in lines:
            if "BPF_STRUCT_OPS" in ln:
                text = ln.strip()
                break
    return (text[:max_chars] + "…") if len(text) > max_chars else text or "(no description)"


def _extract_json(reply: str) -> Optional[Dict[str, Any]]:
    reply = reply.strip()
    reply = re.sub(r"^```(?:json)?\s*", "", reply)
    reply = re.sub(r"\s*```\s*$", "", reply)
    try:
        return json.loads(reply)
    except (json.JSONDecodeError, ValueError):
        pass
    # Balanced-brace scan.
    start = reply.find("{")
    if start < 0:
        return None
    depth = 0
    for i, ch in enumerate(reply[start:], start=start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(reply[start:i + 1])
                except (json.JSONDecodeError, ValueError):
                    return None
    return None


def load_seeds(seeds_dir: str) -> Dict[str, str]:
    """Return {seed_name: code} for every .c in seeds_dir."""
    out: Dict[str, str] = {}
    if not os.path.isdir(seeds_dir):
        return out
    for entry in sorted(os.listdir(seeds_dir)):
        if not entry.endswith(".c"):
            continue
        name = entry[:-2]
        try:
            with open(os.path.join(seeds_dir, entry)) as f:
                out[name] = f.read()
        except OSError:
            continue
    return out


def pick_seeds(
    client: Any,
    model: str,
    temperature: float,
    workload_description: str,
    seeds_dir: str,
    k: int,
) -> List[BranchAssignment]:
    """Run the planner once. Returns K BranchAssignments.

    On any failure (parse error, bad seed name, LLM down) falls back to
    round-robin over whatever seeds are available — the run still proceeds.
    """
    seeds = load_seeds(seeds_dir)
    if not seeds:
        raise RuntimeError(f"No seeds found in {seeds_dir}")

    seed_lines = [
        f"- {name}: {_summarise_seed(code)}"
        for name, code in seeds.items()
    ]

    user_msg = (
        f"## Workload description\n{workload_description.strip()}\n\n"
        f"## Available seeds\n" + "\n".join(seed_lines) + "\n\n"
        f"## Task\nPick exactly K = {k} branches. Respond with ONLY the JSON "
        "object specified in the system prompt."
    )

    fallback = _round_robin_fallback(seeds, k)

    try:
        resp = client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": _load_prompt()},
                {"role": "user",   "content": user_msg},
            ],
            temperature=temperature,
            max_tokens=2048,
        )
        reply = resp.choices[0].message.content or ""
    except Exception as e:
        log.warning("planner LLM call failed (%s); using round-robin fallback", e)
        return fallback

    parsed = _extract_json(reply)
    if not parsed or not isinstance(parsed.get("branches"), list):
        log.warning("planner reply did not parse; using fallback. reply[:200]=%r", reply[:200])
        return fallback

    analysis = (parsed.get("workload_analysis") or "").strip()
    if analysis:
        log.info("Planner workload analysis: %s", analysis[:240])

    out: List[BranchAssignment] = []
    for entry in parsed["branches"][:k]:
        seed = (entry.get("seed") or "").strip()
        if seed not in seeds:
            log.warning("planner picked unknown seed '%s'; skipping", seed)
            continue
        out.append(BranchAssignment(
            seed=seed,
            rationale=(entry.get("rationale") or "")[:400],
            focus_hint=(entry.get("focus_hint") or "")[:500],
        ))

    if len(out) < k:
        log.warning("planner returned %d/%d valid entries; padding with fallback", len(out), k)
        needed = k - len(out)
        out.extend(fallback[:needed])

    return out


def _round_robin_fallback(seeds: Dict[str, str], k: int) -> List[BranchAssignment]:
    names = list(seeds.keys()) or ["lru"]
    return [
        BranchAssignment(
            seed=names[i % len(names)],
            rationale="(fallback: planner unavailable or invalid)",
            focus_hint="Propose a small, well-motivated change to the seed.",
        )
        for i in range(k)
    ]
