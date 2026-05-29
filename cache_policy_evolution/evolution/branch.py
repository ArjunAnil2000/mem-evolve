"""Per-branch DFS state + one-round step.

Each Branch owns its own LLM chat history — the "whispering back and
forth" loop across rounds. A branch thread:

  1. Builds a user turn summarising last round's probe feedback.
  2. Calls the mutator LLM with the full chat.
  3. Hands the code to its assigned Worker for compile+benchmark.
  4. Returns a BranchStepResult for the main thread to stitch into the tree.

All compile + benchmark work lives inside Worker.evaluate(), so this module
stays purely coordination logic: LLM dialogue, result digestion, and
chat-history bookkeeping.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import threading
from dataclasses import asdict, dataclass, field
from typing import Any, Dict, List, Optional

from evaluator import EvaluationResult, compile_policy
from evolution.tree import EvolutionTree, TreeNode
from evolution.worker import Worker

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class Branch:
    branch_id: str
    current_node_id: str
    seed_origin: str = "seed"
    chat_history: List[Dict[str, str]] = field(default_factory=list)
    focus_hint: str = ""                 # set by planner / pivot
    pivoted_rounds: List[int] = field(default_factory=list)


@dataclass
class BranchStepResult:
    branch_id: str
    parent_id: str
    code: str
    score: float
    error: str
    details: Dict[str, Any]
    mutation_description: str
    seed_origin: str
    strategy: str
    worker_name: Optional[str]


# ---------------------------------------------------------------------------
# Constructors / branch lifecycle
# ---------------------------------------------------------------------------

def make_branch(
    idx: int,
    seed_node: TreeNode,
    *,
    focus_hint: str = "",
) -> Branch:
    return Branch(
        branch_id=f"b{idx}",
        current_node_id=seed_node.node_id,
        seed_origin=seed_node.seed_origin or "seed",
        focus_hint=focus_hint,
    )


def reset_branch_for_pivot(
    branch: Branch,
    target_node: TreeNode,
    reason: str,
    round_num: int,
) -> None:
    branch.chat_history = [
        {"role": "user", "content": _pivot_preamble(target_node, reason)},
    ]
    branch.current_node_id = target_node.node_id
    branch.seed_origin = target_node.seed_origin or branch.seed_origin
    branch.focus_hint = reason
    branch.pivoted_rounds.append(round_num)


def spawn_branch(
    idx: int,
    target_node: TreeNode,
    reason: str,
    round_num: int,
) -> Branch:
    b = Branch(
        branch_id=f"b{idx}",
        current_node_id=target_node.node_id,
        seed_origin=target_node.seed_origin or "spawn",
        focus_hint=reason,
    )
    b.chat_history = [
        {"role": "user", "content": _pivot_preamble(target_node, reason)},
    ]
    b.pivoted_rounds.append(round_num)
    return b


# ---------------------------------------------------------------------------
# Prompt pieces
# ---------------------------------------------------------------------------

def _initial_user_msg(seed_code: str, seed_name: str, focus_hint: str) -> str:
    hint = (
        f"\n\n## Initial focus (from the planner)\n{focus_hint}\n"
        if focus_hint else ""
    )
    return (
        f"Round 1 — starting from seed `{seed_name}`.\n\n"
        "You will be invoked repeatedly on this branch. Each round you receive "
        "probe feedback from your last attempt (cgroup I/O, refaults, wallclock, "
        "optional policy counters) and propose ONE focused mutation. Keep track "
        "across rounds of what you've tried.\n"
        f"{hint}\n"
        "Current code:\n"
        f"```c\n{seed_code}\n```\n\n"
        "Propose one focused change and return the COMPLETE modified code "
        "(both BPF and loader sections) in a single ```c block. Begin your "
        "reply with 1–2 sentences naming the change."
    )


def _followup_user_msg(round_num: int, parent_node: TreeNode) -> str:
    status = (
        f"STATUS: FAIL — {parent_node.error[:400]}"
        if parent_node.error else "STATUS: OK"
    )
    parts = [
        f"Round {round_num}. Probe feedback from your last attempt on this branch:",
        "",
        status,
        "",
    ]

    # On failure, surface the compiler / runtime stderr so the LLM can fix
    # the actual error rather than guess. Compile failures land here with a
    # very informative stderr tail.
    if parent_node.error:
        stderr_tail = _get_detail(parent_node.details, "stderr_tail")
        stdout_tail = _get_detail(parent_node.details, "stdout_tail")
        if stderr_tail:
            parts.append("stderr (tail):")
            parts.append("```")
            parts.append(stderr_tail[-1800:].rstrip())
            parts.append("```")
        if stdout_tail and not stderr_tail:
            parts.append("stdout (tail):")
            parts.append("```")
            parts.append(stdout_tail[-1200:].rstrip())
            parts.append("```")

    # Fold probe summaries if present in details. Annotate each line with the
    # z-score the coordinator assigned this round, so the LLM knows whether
    # this run was statistically better or worse than the running mean.
    probes = _extract_probe_summaries(parent_node.details)
    components = _extract_norm_components(parent_node.details)
    if probes:
        parts.append("Probes (raw value | z-score vs running mean, "
                     "negative = better for minimize-direction probes):")
        for name, summary in probes.items():
            comp = components.get(name)
            if comp:
                parts.append(
                    f"  - {name}: {summary}   "
                    f"[z={comp['z']:+.2f}σ contrib={comp['contribution']:+.2f} "
                    f"w={comp['weight']:.2f}]"
                )
            else:
                parts.append(f"  - {name}: {summary}")
        parts.append(f"normalized_score={parent_node.score:+.4f}")
    elif not parent_node.error:
        # Degraded mode (no probe data, e.g., pre-benchmark error).
        parts.append(f"score={parent_node.score:.4f} (no probe details available)")

    parts.append("")
    parts.append(
        "Evolve further. If the last change did not help, back off and try a "
        "different angle — do NOT repeat the same mutation. If it helped, push "
        "harder in the same direction. Return the COMPLETE modified code in a "
        "single ```c block. Begin your reply with 1–2 sentences naming the change."
    )
    return "\n".join(parts)


def _pivot_preamble(target_node: TreeNode, reason: str) -> str:
    return (
        "### Branch pivot (fresh start)\n"
        f"A frontier-review step has moved this branch onto a stronger node "
        f"(`{target_node.node_id}`, score={target_node.score:.4f}, "
        f"seed={target_node.seed_origin}). Prior chat memory has been "
        "discarded — you start here.\n\n"
        f"Reviewer's reason: {reason}\n\n"
        "Starting code:\n"
        f"```c\n{target_node.code}\n```\n"
    )


def _extract_probe_summaries(details: Dict[str, Any]) -> Dict[str, str]:
    """Pull `{probe_name: summary}` out of an EvaluationResult.to_dict()."""
    probes = details.get("probes") if isinstance(details, dict) else None
    if not isinstance(probes, dict):
        return {}
    return {
        name: (entry.get("summary") if isinstance(entry, dict) else str(entry))
        for name, entry in probes.items()
    }


def _get_detail(details: Dict[str, Any], key: str) -> str:
    v = details.get(key) if isinstance(details, dict) else None
    return v if isinstance(v, str) else ""


def _extract_norm_components(details: Dict[str, Any]) -> Dict[str, Dict[str, float]]:
    """Pull the per-probe normalization breakdown stashed by loop._normalized_score."""
    norm = details.get("normalized") if isinstance(details, dict) else None
    if not isinstance(norm, dict):
        return {}
    comps = norm.get("components")
    return comps if isinstance(comps, dict) else {}


# ---------------------------------------------------------------------------
# Chat-history trimming
# ---------------------------------------------------------------------------

_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)


def _compact_assistant(content: str, keep_chars: int = 600) -> str:
    stripped = _CODE_BLOCK_RE.sub("[full code elided — superseded]", content).strip()
    if len(stripped) > keep_chars:
        stripped = stripped[:keep_chars].rsplit(" ", 1)[0] + " …"
    return stripped or "[no prose]"


def _trim_history_code(branch: Branch) -> None:
    """Keep full code only in the LAST assistant turn; compact earlier ones."""
    last = -1
    for i in range(len(branch.chat_history) - 1, -1, -1):
        if branch.chat_history[i]["role"] == "assistant":
            last = i
            break
    for i, m in enumerate(branch.chat_history):
        if i == last:
            continue
        if m["role"] == "assistant" and "```" in m["content"]:
            branch.chat_history[i] = {
                "role": "assistant",
                "content": _compact_assistant(m["content"]),
            }


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------

def _extract_code(reply: str) -> Optional[str]:
    blocks = re.findall(r"```(?:c)?\s*\n(.*?)```", reply, re.DOTALL)
    if not blocks:
        return None
    return max(blocks, key=len).strip()


def _summarise_reply(reply: str) -> str:
    prose = _CODE_BLOCK_RE.sub("", reply).strip()
    first = prose.split("\n\n", 1)[0] if prose else ""
    return (first[:220] + "…") if len(first) > 220 else (first or "(no description)")


# ---------------------------------------------------------------------------
# One round on one branch
# ---------------------------------------------------------------------------

def step_branch(
    branch: Branch,
    tree: EvolutionTree,
    *,
    round_num: int,
    client: Any,
    model: str,
    system_prompt: str,
    temperature: float,
    seed_code: str,
    seed_name: str,
    worker: Worker,
    benchmark_script: str,
    timeout: int,
    policies_dir: str,
    compile_lock: threading.Lock,
    binary_cache_dir: str,
) -> BranchStepResult:
    parent_id_at_start = branch.current_node_id
    parent_node = tree.get_node(parent_id_at_start)

    # ---------------- 1. User turn ----------------
    has_prior_assistant = any(m["role"] == "assistant" for m in branch.chat_history)
    if not has_prior_assistant:
        if branch.chat_history:
            # Pivot preamble already installed — add round-N instruction after it.
            branch.chat_history.append({
                "role": "user",
                "content": (
                    f"Round {round_num} (first attempt on pivoted branch). "
                    "Propose your first mutation. Return the COMPLETE modified "
                    "code in a single ```c block. Begin with 1–2 sentences "
                    "naming the change."
                ),
            })
        else:
            branch.chat_history.append({
                "role": "user",
                "content": _initial_user_msg(seed_code, seed_name, branch.focus_hint),
            })
    else:
        _trim_history_code(branch)
        branch.chat_history.append({
            "role": "user",
            "content": _followup_user_msg(round_num, parent_node),
        })

    # ---------------- 2. LLM call ----------------
    messages = [{"role": "system", "content": system_prompt}] + branch.chat_history
    reply = ""
    try:
        resp = client.chat.completions.create(
            model=model, messages=messages,
            temperature=temperature, max_tokens=16384,
        )
        reply = resp.choices[0].message.content or ""
    except Exception as e:
        log.warning("[%s] LLM call failed: %s", branch.branch_id, e)

    new_code = _extract_code(reply)
    if not new_code:
        new_code = parent_node.code
        reply = (reply or "(LLM returned empty response)") + \
                "\n\n[coordinator: no ```c``` block parsed; reusing parent code]"
    branch.chat_history.append({"role": "assistant", "content": reply})

    mutation_desc = _summarise_reply(reply)

    # ---------------- 3. Compile (serialised) + snapshot binary ----------------
    # The shared policies_dir is written by every branch, so the compile
    # call must hold a lock. We then snapshot the resulting binary to a
    # per-branch path so the worker can run it long after the lock is gone
    # (other branches may have overwritten policies_dir/evo_policy.out).
    snapshot_binary: Optional[str] = None
    compile_err = ""
    compile_stderr_tail = ""

    with compile_lock:
        cres = compile_policy(new_code, policies_dir)
        if cres.ok and cres.binary_path:
            os.makedirs(binary_cache_dir, exist_ok=True)
            snapshot_binary = os.path.join(
                binary_cache_dir,
                f"{branch.branch_id}_r{round_num}.out",
            )
            try:
                shutil.copy2(cres.binary_path, snapshot_binary)
                os.chmod(snapshot_binary, 0o755)
            except OSError as e:
                compile_err = f"failed to snapshot binary: {e}"
                snapshot_binary = None
        else:
            compile_err = cres.error or "compile failed"
            compile_stderr_tail = cres.stderr_tail

    if not snapshot_binary:
        # Short-circuit: worker never runs. LLM sees the compile diagnostics
        # via stderr_tail on the next round.
        eval_dict = asdict(EvaluationResult(
            ok=False,
            error=compile_err or "compile failed",
            score=0.0,
            wallclock_sec=0.0,
            probes={},
            stdout_tail="",
            stderr_tail=compile_stderr_tail,
        ))
        score = 0.0
        err = compile_err or "compile failed"
        return BranchStepResult(
            branch_id=branch.branch_id,
            parent_id=parent_id_at_start,
            code=new_code,
            score=score,
            error=err,
            details=eval_dict,
            mutation_description=mutation_desc,
            seed_origin=branch.seed_origin,
            strategy=(
                "pivot-mutate"
                if branch.pivoted_rounds and branch.pivoted_rounds[-1] == round_num
                else ("seed-mutate" if parent_node.depth == 0 else "mutate")
            ),
            worker_name=None,
        )

    # ---------------- 4. Evaluate via worker ----------------
    try:
        eval_dict = worker.evaluate(
            binary_path=snapshot_binary,
            benchmark_script=benchmark_script,
            timeout=timeout,
        )
    except Exception as e:
        log.exception("[%s] worker.evaluate crashed", branch.branch_id)
        eval_dict = {
            "ok": False, "error": f"worker crashed: {e}",
            "score": 0.0, "wallclock_sec": 0.0,
            "probes": {}, "stdout_tail": "", "stderr_tail": "",
        }

    score = float(eval_dict.get("score", 0.0)) if eval_dict.get("ok") else 0.0
    err = "" if eval_dict.get("ok") else str(eval_dict.get("error", ""))

    strategy = (
        "pivot-mutate"
        if branch.pivoted_rounds and branch.pivoted_rounds[-1] == round_num
        else ("seed-mutate" if parent_node.depth == 0 else "mutate")
    )

    return BranchStepResult(
        branch_id=branch.branch_id,
        parent_id=parent_id_at_start,
        code=new_code,
        score=score,
        error=err,
        details=eval_dict,
        mutation_description=mutation_desc,
        seed_origin=branch.seed_origin,
        strategy=strategy,
        worker_name=worker.name,
    )
