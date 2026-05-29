"""Worker abstraction: "run this pre-compiled policy, return the result."

Compilation is the coordinator's job (see evaluator.compile_policy). Workers
accept a compiled `.out` binary and know only how to launch it against a
benchmark script that already exists on the worker host.

Two backends:

  LocalWorker — calls evaluator.evaluate() in-process. Used when
                `workers = []` in the TOML (single-machine mode).

  HTTPWorker  — POSTs the compiled binary to a running `worker_server.py`
                daemon on the remote host. Zero SSH required at runtime —
                SSH is only used once at provisioning time (by
                start_workers.sh) to launch the daemon. This matches the
                common CloudLab setup where the coordinator can SSH to every
                node but nodes can't SSH to each other.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict
from typing import Any, Dict, Optional

import requests

from evaluator import (
    DEFAULT_PROBES, EvaluationResult, JsonExtractProbe, Probe, evaluate,
)

log = logging.getLogger(__name__)


def build_probes_from_specs(specs: Optional[list]) -> Optional[list]:
    """Convert TOML-style probe specs into Probe instances.

    Each spec is a dict like:
        {type = "json_extract", name = "ycsb_throughput",
         results_file = "results.json",     # relative → resolved under JOB_DIR at evaluate-time
         json_path = "throughput_ops_per_sec",
         direction = "maximize",            # or "minimize" / "record"
         unit = "ops/s"}

    Returns DEFAULT_PROBES + custom probes, or None if `specs` is empty/None
    so the evaluator falls back to DEFAULT_PROBES alone.
    """
    if not specs:
        return None
    custom: list = []
    for s in specs:
        kind = (s.get("type") or "").lower()
        if kind in ("json_extract", "json"):
            custom.append(JsonExtractProbe(
                name=s["name"],
                results_path=s["results_file"],
                json_path=s["json_path"],
                direction=s.get("direction", "maximize"),
                unit=s.get("unit", ""),
            ))
        else:
            log.warning("unknown probe type %r — skipping", kind)
    return list(DEFAULT_PROBES) + custom


class Worker:
    name: str = "worker"

    def evaluate(
        self,
        binary_path: Optional[str],
        benchmark_script: str,
        timeout: int,
    ) -> Dict[str, Any]:
        """Run the pre-compiled binary + script. Return asdict(EvaluationResult).

        Pass `binary_path=None` to run the script with no policy attached.
        """
        raise NotImplementedError


# ---------------------------------------------------------------------------
# Local
# ---------------------------------------------------------------------------

class LocalWorker(Worker):
    def __init__(
        self,
        *,
        cgroup_path: Optional[str] = None,
        cwd: Optional[str] = None,
        weights: Optional[Dict[str, float]] = None,
        probes: Optional[list] = None,
        split_phases: bool = False,
        warmup_timeout: Optional[int] = None,
    ):
        self.cgroup_path = cgroup_path
        self.cwd = cwd
        self.weights = weights
        self.probes = probes
        self.split_phases = split_phases
        self.warmup_timeout = warmup_timeout
        self.name = "local"

    def evaluate(
        self,
        binary_path: Optional[str],
        benchmark_script: str,
        timeout: int,
    ) -> Dict[str, Any]:
        result = evaluate(
            binary_path=binary_path,
            benchmark_script=benchmark_script,
            cgroup_path=self.cgroup_path,
            timeout=timeout,
            cwd=self.cwd,
            weights=self.weights,
            probes=self.probes,
            split_phases=self.split_phases,
            warmup_timeout=self.warmup_timeout,
        )
        return result.to_dict()


# ---------------------------------------------------------------------------
# HTTP (talks to worker_server.py running on a remote node)
# ---------------------------------------------------------------------------

class HTTPWorker(Worker):
    """POSTs a compiled .out to a remote evo-worker daemon."""

    def __init__(
        self,
        url: str,
        *,
        remote_cgroup_path: Optional[str] = None,
        remote_cwd: Optional[str] = None,
        remote_benchmark: Optional[str] = None,
        auth_token: Optional[str] = None,
        weights: Optional[Dict[str, float]] = None,
        probe_specs: Optional[list] = None,
        split_phases: bool = False,
        warmup_timeout: Optional[int] = None,
    ):
        self.url = url.rstrip("/")
        self.remote_cgroup_path = remote_cgroup_path
        self.remote_cwd = remote_cwd
        self.remote_benchmark = remote_benchmark
        self.auth_token = auth_token
        self.weights = weights
        self.probe_specs = probe_specs
        self.split_phases = split_phases
        self.warmup_timeout = warmup_timeout
        self.name = f"http:{urlsafe_host(self.url)}"

    # ---- basic ops ---------------------------------------------------------
    def _headers(self, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
        h: Dict[str, str] = {}
        if self.auth_token:
            h["X-Auth-Token"] = self.auth_token
        if extra:
            h.update(extra)
        return h

    def health_check(self) -> bool:
        try:
            r = requests.get(
                f"{self.url}/health",
                headers=self._headers(),
                timeout=10,
            )
            return r.status_code == 200 and r.json().get("status") == "ok"
        except Exception as e:
            log.debug("health_check(%s) failed: %s", self.url, e)
            return False

    def evaluate(
        self,
        binary_path: Optional[str],
        benchmark_script: str,
        timeout: int,
    ) -> Dict[str, Any]:
        script = benchmark_script or self.remote_benchmark
        if not script:
            return _error_result(f"{self.url}: missing benchmark_script")

        if binary_path is None:
            binary_bytes = b""
        else:
            try:
                with open(binary_path, "rb") as f:
                    binary_bytes = f.read()
            except OSError as e:
                return _error_result(f"{self.url}: cannot read binary {binary_path}: {e}")

        params: Dict[str, Any] = {
            "benchmark": script,
            "timeout": int(timeout),
        }
        if binary_path is None:
            params["no_policy"] = "1"
        if self.remote_cgroup_path:
            params["cgroup"] = self.remote_cgroup_path
        if self.remote_cwd:
            params["cwd"] = self.remote_cwd
        if self.weights:
            params["weights"] = json.dumps(self.weights)
        if self.probe_specs:
            params["probes"] = json.dumps(self.probe_specs)
        if self.split_phases:
            params["split_phases"] = "1"
        if self.warmup_timeout is not None:
            params["warmup_timeout"] = int(self.warmup_timeout)

        try:
            r = requests.post(
                f"{self.url}/evaluate",
                params=params,
                data=binary_bytes,
                headers=self._headers({"Content-Type": "application/octet-stream"}),
                timeout=timeout + 120,
            )
        except requests.Timeout:
            return _error_result(f"{self.url}: HTTP timeout after {timeout + 120}s")
        except requests.RequestException as e:
            return _error_result(f"{self.url}: HTTP error: {e}")

        if r.status_code != 200:
            return _error_result(
                f"{self.url}: HTTP {r.status_code} — {r.text[:400]}"
            )
        try:
            return r.json()
        except (json.JSONDecodeError, ValueError):
            return _error_result(
                f"{self.url}: non-JSON response — {r.text[:400]}"
            )

    # ---- preflight + setup -------------------------------------------------
    def _setup_like(
        self,
        endpoint: str,
        benchmark_script: str,
        timeout: int,
    ) -> Dict[str, Any]:
        script = benchmark_script or self.remote_benchmark
        if not script:
            return {"ok": False, "error": f"{self.url}: missing benchmark_script",
                    "worker": self.url}
        try:
            r = requests.post(
                f"{self.url}/{endpoint}",
                params={"benchmark": script, "timeout": int(timeout)},
                headers=self._headers(),
                timeout=timeout + 30,
            )
        except requests.Timeout:
            return {"ok": False, "error": f"{self.url}: HTTP timeout after {timeout + 30}s",
                    "worker": self.url}
        except requests.RequestException as e:
            return {"ok": False, "error": f"{self.url}: HTTP error: {e}",
                    "worker": self.url}
        if r.status_code != 200:
            return {"ok": False, "exit_code": r.status_code,
                    "stderr": r.text[:1000], "worker": self.url}
        try:
            return r.json()
        except (json.JSONDecodeError, ValueError):
            return {"ok": False, "error": f"{self.url}: non-JSON response — {r.text[:400]}",
                    "worker": self.url}

    def preflight(self, benchmark_script: str, timeout: int = 60) -> Dict[str, Any]:
        return self._setup_like("preflight", benchmark_script, timeout)

    def setup(self, benchmark_script: str, timeout: int = 1800) -> Dict[str, Any]:
        return self._setup_like("setup", benchmark_script, timeout)


def _error_result(msg: str) -> Dict[str, Any]:
    return asdict(EvaluationResult(
        ok=False, error=msg, score=0.0, wallclock_sec=0.0,
        probes={}, stdout_tail="", stderr_tail="",
    ))


def urlsafe_host(url: str) -> str:
    """Extract host:port from a URL for the Worker.name field."""
    from urllib.parse import urlparse
    u = urlparse(url)
    return u.netloc or url


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

def build_workers(cfg: Dict[str, Any]) -> list[Worker]:
    """Build the worker pool from config.

    `cfg["workers"]` is a list. Each entry is either:
      - a string URL (e.g. "http://clnode003:8080"), or
      - a dict {"url": "...", "cgroup": "...", "cwd": "...", "auth_token": "..."}

    Empty list → one LocalWorker (single-machine mode).
    """
    worker_cfgs = cfg.get("workers", []) or []
    source_dir = cfg.get("source_dir")

    scoring = cfg.get("scoring", {}) or {}
    weights = scoring.get("weights") or None
    probe_specs = cfg.get("probes") or None
    probes = build_probes_from_specs(probe_specs)
    split_phases = bool(cfg.get("benchmark_split", False))
    warmup_timeout = cfg.get("warmup_timeout")
    if warmup_timeout is not None:
        warmup_timeout = int(warmup_timeout)

    if not worker_cfgs:
        return [LocalWorker(
            cgroup_path=cfg.get("cgroup") or None,
            cwd=source_dir,
            weights=weights,
            probes=probes,
            split_phases=split_phases,
            warmup_timeout=warmup_timeout,
        )]

    http_defaults = cfg.get("http_worker", {}) or {}
    default_token = http_defaults.get("auth_token") or cfg.get("auth_token")
    default_cgroup = http_defaults.get("cgroup") or cfg.get("cgroup")
    default_cwd = http_defaults.get("cwd") or http_defaults.get("remote_cwd")

    workers: list[Worker] = []
    for wc in worker_cfgs:
        if isinstance(wc, str):
            url, opts = wc, {}
        else:
            url = wc.get("url") or ""
            opts = {k: v for k, v in wc.items() if k != "url"}
        if not url:
            log.warning("skipping worker entry without url: %r", wc)
            continue
        workers.append(HTTPWorker(
            url=url,
            remote_cgroup_path=opts.get("cgroup") or default_cgroup,
            remote_cwd=opts.get("cwd") or default_cwd,
            remote_benchmark=cfg.get("benchmark"),
            auth_token=opts.get("auth_token") or default_token,
            weights=weights,
            probe_specs=probe_specs,
            split_phases=split_phases,
            warmup_timeout=warmup_timeout,
        ))
    return workers
