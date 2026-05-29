"""Workload-agnostic page-cache probes.

Each Probe has a pre() / post() lifecycle. The evaluator calls pre() before
the workload starts and post() after it finishes; the probe returns a
ProbeResult with a primary scalar value, a one-line summary for LLM feedback,
and a structured details dict.

v1 probes all read kernel-exposed counters scoped to the benchmark cgroup, so
they are independent of what the workload itself prints.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

@dataclass
class ProbeResult:
    name: str
    value: float                     # primary scalar, usable for scoring
    unit: str
    direction: str                   # "minimize" | "maximize" | "record"
    summary: str                     # one-line feedback for LLM
    details: Dict[str, Any] = field(default_factory=dict)


class Probe:
    """Base probe. Override pre() and post().

    ctx keys provided by the evaluator:
        cgroup_path          — absolute path to the benchmark cgroup
        policy_metrics_path  — JSON file the policy loader may write
        work_dir             — per-run scratch directory
        source_dir           — cache_ext source tree
    """

    name: str = ""
    direction: str = "record"
    unit: str = ""

    def pre(self, ctx: Dict[str, Any]) -> None:
        return None

    def post(self, ctx: Dict[str, Any]) -> ProbeResult:
        raise NotImplementedError


# ---------------------------------------------------------------------------
# Parsers for cgroup keyed-stat files
# ---------------------------------------------------------------------------

def _read_memstat(path: str) -> Dict[str, int]:
    """Parse memory.stat: one `key value` per line."""
    out: Dict[str, int] = {}
    try:
        with open(path) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    try:
                        out[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return out


def _read_iostat(path: str) -> Dict[str, int]:
    """Parse io.stat: `<dev> key=val key=val …` per line; sum across devices."""
    out: Dict[str, int] = {}
    try:
        with open(path) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) < 2:
                    continue
                for kv in parts[1:]:
                    if "=" not in kv:
                        continue
                    k, v = kv.split("=", 1)
                    try:
                        out[k] = out.get(k, 0) + int(v)
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return out


# ---------------------------------------------------------------------------
# v1 probes
# ---------------------------------------------------------------------------

class WallclockProbe(Probe):
    """Elapsed wall time between pre() and post()."""

    name = "wallclock"
    direction = "minimize"
    unit = "seconds"

    def pre(self, ctx):
        self._t0 = time.monotonic()

    def post(self, ctx):
        dt = time.monotonic() - self._t0
        return ProbeResult(
            name=self.name, value=float(dt), unit=self.unit,
            direction=self.direction,
            summary=f"{dt:.2f}s",
            details={"seconds": dt},
        )


class CgroupIostatProbe(Probe):
    """Delta of io.stat for the benchmark cgroup.

    `rbytes` (bytes read from block devices) is the single best proxy for
    "did the cache help" — a good policy keeps hot pages resident, so fewer
    block reads happen during the workload.
    """

    name = "cgroup_iostat"
    direction = "minimize"
    unit = "bytes"

    def pre(self, ctx):
        self._before = _read_iostat(os.path.join(ctx["cgroup_path"], "io.stat"))

    def post(self, ctx):
        after = _read_iostat(os.path.join(ctx["cgroup_path"], "io.stat"))
        rbytes = after.get("rbytes", 0) - self._before.get("rbytes", 0)
        wbytes = after.get("wbytes", 0) - self._before.get("wbytes", 0)
        rios = after.get("rios", 0) - self._before.get("rios", 0)
        details = {"rbytes": rbytes, "wbytes": wbytes, "rios": rios}
        return ProbeResult(
            name=self.name, value=float(rbytes), unit=self.unit,
            direction=self.direction,
            summary=(
                f"rbytes={rbytes / (1 << 20):.1f}MiB "
                f"wbytes={wbytes / (1 << 20):.1f}MiB "
                f"rios={rios}"
            ),
            details=details,
        )


class CgroupMemstatProbe(Probe):
    """Delta of memory.stat for the benchmark cgroup.

    Primary value is `workingset_refault_file` — a refault counts a page that
    was evicted, read back from disk, and found to still be hot. It is a
    direct measurement of eviction mispredictions. Lower is better.
    """

    name = "cgroup_memstat"
    direction = "minimize"
    unit = "refaults"

    KEYS = [
        "workingset_refault_file",
        "workingset_activate_file",
        "workingset_restore_file",
        "pgfault",
        "pgmajfault",
        "pgactivate",
        "pgdeactivate",
        "pgscan",
        "pgsteal",
    ]
    FINAL_KEYS = ["file", "file_mapped", "file_dirty"]

    def pre(self, ctx):
        self._before = _read_memstat(os.path.join(ctx["cgroup_path"], "memory.stat"))

    def post(self, ctx):
        after = _read_memstat(os.path.join(ctx["cgroup_path"], "memory.stat"))
        deltas = {k: after.get(k, 0) - self._before.get(k, 0) for k in self.KEYS}
        finals = {k: after.get(k, 0) for k in self.FINAL_KEYS}
        primary = deltas.get("workingset_refault_file", 0)
        summary = (
            f"refault_file={deltas['workingset_refault_file']} "
            f"pgmajfault={deltas['pgmajfault']} "
            f"pgactivate={deltas['pgactivate']} "
            f"resident_file={finals['file'] // (1 << 20)}MiB"
        )
        return ProbeResult(
            name=self.name, value=float(primary), unit=self.unit,
            direction=self.direction, summary=summary,
            details={"delta": deltas, "final": finals},
        )


class PolicyCountersProbe(Probe):
    """Reads $POLICY_METRICS_OUT JSON dumped by the policy's userspace loader.

    The convention (see docstring of evaluate.py) is that every policy MAY
    write a JSON object of {counter_name: int} to this path on exit. If the
    file is missing or unparseable, the probe reports 0 with a note —
    non-fatal, since not every policy exports counters.
    """

    name = "policy_counters"
    direction = "record"

    def pre(self, ctx):
        path = ctx.get("policy_metrics_path")
        if path and os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass

    def post(self, ctx):
        path = ctx.get("policy_metrics_path")
        if not path or not os.path.exists(path):
            return ProbeResult(
                name=self.name, value=0.0, unit="", direction=self.direction,
                summary="(no policy_metrics file — policy did not export counters)",
                details={},
            )
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception as e:
            return ProbeResult(
                name=self.name, value=0.0, unit="", direction=self.direction,
                summary=f"(failed to parse policy_metrics: {e})",
                details={},
            )
        if not isinstance(data, dict):
            return ProbeResult(
                name=self.name, value=0.0, unit="", direction=self.direction,
                summary=f"(policy_metrics is not a JSON object: {type(data).__name__})",
                details={},
            )
        summary = " ".join(f"{k}={v}" for k, v in sorted(data.items())) or "(empty)"
        return ProbeResult(
            name=self.name, value=0.0, unit="", direction=self.direction,
            summary=summary, details=data,
        )


class JsonExtractProbe(Probe):
    """Pull a single scalar from a JSON file written by the launch script.

    Useful when your benchmark already emits its own results (throughput,
    latency, custom counters) and you want to feed that value into the
    weighted score.

    `json_path` is a slash-separated path into the JSON object, e.g.
    `"results/throughput"` or `"combined_score"`. Numeric list indices are
    supported (`"runs/0/time"`).

    `results_path` may be absolute, or relative to the per-evaluation
    `JOB_DIR` (resolved against `ctx["work_dir"]`). Use a relative path like
    `"results.json"` when the launch script writes to `$JOB_DIR/results.json`.

    The file is read after the workload exits; if the file is missing or
    the path doesn't resolve to a number, the probe reports 0 with a note
    and contributes nothing meaningful to the score.
    """

    def __init__(
        self,
        *,
        name: str,
        results_path: str,
        json_path: str,
        direction: str = "maximize",
        unit: str = "",
    ):
        if direction not in ("minimize", "maximize", "record"):
            raise ValueError(f"bad direction {direction!r}")
        self.name = name
        self.results_path = results_path
        self.json_path = json_path
        self.direction = direction
        self.unit = unit

    def _resolve_path(self, ctx) -> str:
        if os.path.isabs(self.results_path):
            return self.results_path
        work_dir = ctx.get("work_dir") or "."
        return os.path.join(work_dir, self.results_path)

    def pre(self, ctx):
        path = self._resolve_path(ctx)
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError:
            pass

    def _walk(self, data: Any) -> Any:
        node: Any = data
        for part in self.json_path.split("/"):
            if part == "":
                continue
            if isinstance(node, dict):
                node = node.get(part)
            elif isinstance(node, list):
                try:
                    node = node[int(part)]
                except (ValueError, IndexError):
                    return None
            else:
                return None
        return node

    def post(self, ctx):
        path = self._resolve_path(ctx)
        if not os.path.exists(path):
            return ProbeResult(
                name=self.name, value=0.0, unit=self.unit,
                direction=self.direction,
                summary=f"(missing results file {path})",
                details={},
            )
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception as e:
            return ProbeResult(
                name=self.name, value=0.0, unit=self.unit,
                direction=self.direction,
                summary=f"(failed to parse {path}: {e})",
                details={},
            )
        node = self._walk(data)
        if not isinstance(node, (int, float)):
            return ProbeResult(
                name=self.name, value=0.0, unit=self.unit,
                direction=self.direction,
                summary=f"(json_path={self.json_path} did not resolve to a number; got {type(node).__name__})",
                details={"raw": data},
            )
        v = float(node)
        return ProbeResult(
            name=self.name, value=v, unit=self.unit,
            direction=self.direction,
            summary=f"{self.json_path}={v:g}{(' ' + self.unit) if self.unit else ''}",
            details={"json_path": self.json_path, "value": v},
        )


DEFAULT_PROBES: List[Probe] = [
    WallclockProbe(),
    CgroupIostatProbe(),
    CgroupMemstatProbe(),
    PolicyCountersProbe(),
]

DEFAULT_WEIGHTS: Dict[str, float] = {
    "cgroup_iostat":   1.0,
    "cgroup_memstat":  0.5,
    "wallclock":       0.5,
    # policy_counters is "record" only; not scored.
}
