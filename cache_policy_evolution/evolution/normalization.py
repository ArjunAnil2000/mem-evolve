"""Online z-score normalization for probe values.

Why this exists
---------------
Raw probe values live on wildly different scales: `cgroup_iostat` is bytes
(1e9), `wallclock` is seconds (1e1), `cgroup_memstat` is refault counts
(1e3). A naive weighted sum over raw values is dominated by whichever probe
happens to have the largest unit. Static baselines (a-priori values you
divide by) work but are brittle: they go stale when the benchmark, hardware,
or workload size changes.

This module keeps a running mean and population stddev for each probe
across the run (Welford's online algorithm) and scores each new round as

    z      = (value - mu) / sigma          # per probe, unit-free
    signed = z * (-1 if minimize else +1)  # higher-is-better convention
    score  = sum_w(weights[name] * tanh(signed)) / sum_w(weights[name])

The `tanh` squash maps each probe's contribution to (-1, +1), so a single
freak run cannot dominate the weighted sum. A linear (no-squash) variant is
also exposed for comparison.

State persists to a JSON file so `--resume` and `--calibrate` flows pick up
where they left off.
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field
from typing import Any, Dict, Optional


# ---------------------------------------------------------------------------
# Per-probe Welford accumulator
# ---------------------------------------------------------------------------

@dataclass
class _Welford:
    n: int = 0
    mean: float = 0.0
    M2: float = 0.0          # sum of squared deviations from current mean

    def update(self, x: float) -> None:
        self.n += 1
        delta = x - self.mean
        self.mean += delta / self.n
        delta2 = x - self.mean
        self.M2 += delta * delta2

    @property
    def variance(self) -> float:
        # Population variance (n, not n-1) — matches z-score convention.
        return self.M2 / self.n if self.n > 0 else 0.0

    @property
    def stddev(self) -> float:
        return math.sqrt(self.variance)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

@dataclass
class NormalizationState:
    """Persistent {probe_name → Welford} map plus scoring config.

    `min_n`: number of samples required before a probe contributes to the
    score. The first few rounds yield z=0 for everything — this is fine; the
    LLM's feedback string still shows raw values, so it can reason about
    physical quantities anyway.

    `squash`: "tanh" (default) clamps each probe's contribution to (-1, +1);
    "none" leaves z-scores raw (a single 10σ outlier dominates).
    """

    probes: Dict[str, _Welford] = field(default_factory=dict)
    squash: str = "tanh"
    min_n: int = 2

    # ---- updating -----------------------------------------------------------
    def update(self, raw_values: Dict[str, float]) -> None:
        for name, v in raw_values.items():
            try:
                f = float(v)
            except (TypeError, ValueError):
                continue
            if not math.isfinite(f):
                continue
            self.probes.setdefault(name, _Welford()).update(f)

    def n(self, probe_name: str) -> int:
        w = self.probes.get(probe_name)
        return w.n if w else 0

    # ---- scoring ------------------------------------------------------------
    def score(
        self,
        probe_results: Dict[str, Dict[str, Any]],
        weights: Dict[str, float],
    ) -> Dict[str, Any]:
        """Score a single round given its probe outputs.

        `probe_results` is the dict shape from `EvaluationResult.probes`:
            {name: {value, direction, summary, ...}}

        Returns a dict containing the final `score`, plus a per-probe
        breakdown for debugging / LLM display:
            {
              "score": float,
              "components": {name: {z, contribution, mean, stddev, n}},
              "skipped": [name, …],
            }
        """
        components: Dict[str, Dict[str, Any]] = {}
        skipped = []
        num, den = 0.0, 0.0

        for name, entry in probe_results.items():
            direction = entry.get("direction", "record")
            if direction == "record":
                continue
            w = float(weights.get(name, 0.0))
            if w <= 0.0:
                continue

            value = float(entry.get("value", 0.0))
            stats = self.probes.get(name)
            if stats is None or stats.n < self.min_n or stats.stddev <= 0.0:
                skipped.append(name)
                continue

            z = (value - stats.mean) / stats.stddev
            signed = -z if direction == "minimize" else z
            contrib = math.tanh(signed) if self.squash == "tanh" else signed

            num += contrib * w
            den += w
            components[name] = {
                "z": z,
                "contribution": contrib,
                "weight": w,
                "mean": stats.mean,
                "stddev": stats.stddev,
                "n": stats.n,
            }

        score = num / den if den > 0 else 0.0
        return {"score": score, "components": components, "skipped": skipped}

    # ---- persistence --------------------------------------------------------
    def to_dict(self) -> Dict[str, Any]:
        return {
            "squash": self.squash,
            "min_n": self.min_n,
            "probes": {
                k: {"n": v.n, "mean": v.mean, "M2": v.M2}
                for k, v in self.probes.items()
            },
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "NormalizationState":
        st = cls(
            squash=data.get("squash", "tanh"),
            min_n=int(data.get("min_n", 2)),
        )
        for k, v in (data.get("probes") or {}).items():
            st.probes[k] = _Welford(
                n=int(v.get("n", 0)),
                mean=float(v.get("mean", 0.0)),
                M2=float(v.get("M2", 0.0)),
            )
        return st

    def save(self, path: str) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.to_dict(), f, indent=2)
        os.replace(tmp, path)

    @classmethod
    def load(cls, path: str) -> Optional["NormalizationState"]:
        if not os.path.exists(path):
            return None
        try:
            with open(path) as f:
                return cls.from_dict(json.load(f))
        except (OSError, ValueError, json.JSONDecodeError):
            return None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def extract_raw_values(probe_results: Dict[str, Dict[str, Any]]) -> Dict[str, float]:
    """Pull `{name: value}` from `EvaluationResult.probes`-shaped dicts.

    Skips `record`-direction probes (e.g. policy_counters) so they don't
    pollute the running stats.
    """
    out: Dict[str, float] = {}
    for name, entry in probe_results.items():
        if entry.get("direction") == "record":
            continue
        try:
            f = float(entry.get("value", 0.0))
        except (TypeError, ValueError):
            continue
        if math.isfinite(f):
            out[name] = f
    return out
