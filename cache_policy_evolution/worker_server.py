#!/usr/bin/env python3
"""evo-worker HTTP daemon — runs a pre-compiled BPF policy against a benchmark.

The coordinator compiles policies locally and POSTs the resulting `.out`
binary here; this process calls `evaluator.evaluate()` in-process and
returns the EvaluationResult as JSON. Stdlib-only: no FastAPI, no uvicorn.

Endpoints
---------

  GET  /health
       → {"status": "ok", "worker": "<hostname>"}

  POST /evaluate?benchmark=<path>&timeout=<sec>&cgroup=<path>&cwd=<path>
       Body: raw compiled `.out` bytes (Content-Type: application/octet-stream).
       → EvaluationResult JSON (200 always when the request is well-formed,
         even if the evaluation itself fails — see `ok` / `error` fields).

  POST /preflight?benchmark=<path>&timeout=<sec>
       Runs `<dirname(benchmark)>/setup.sh check` on the worker and returns
       its stdout/stderr/exit_code. Used by `evolve.py --preflight` to
       verify a worker has everything the workload needs before starting.

  POST /setup?benchmark=<path>&timeout=<sec>
       Runs `<dirname(benchmark)>/setup.sh setup` on the worker. Idempotent
       per the script's own contract. Used by `evolve.py --setup-workers`.

Launch
------

    python3 worker_server.py --port 8080

The worker assumes the cache_ext repo is cloned at the expected remote
location and `setup_isolation.sh` has already created the benchmark cgroup.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional
from urllib.parse import parse_qs, urlparse

# Make sibling packages importable whether this script is run directly or
# via `python3 -m worker_server`.
_SELF_DIR = os.path.dirname(os.path.abspath(__file__))
if _SELF_DIR not in sys.path:
    sys.path.insert(0, _SELF_DIR)

from evaluator import evaluate  # noqa: E402
from evolution.worker import build_probes_from_specs  # noqa: E402

log = logging.getLogger("evo-worker")

_HOSTNAME = socket.gethostname()
_AUTH_TOKEN: str = ""      # set from --token or $EVO_WORKER_TOKEN

# Only one /evaluate at a time per worker. cache_ext attaches a BPF
# struct_ops globally and the benchmark cgroup is host-shared, so concurrent
# evaluations would (a) collide on the struct_ops slot and (b) cross-pollute
# each other's iostat/memstat probes. Coordinator parallelism is the answer
# for scale-out, not in-host concurrency.
_EVAL_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    # ---- logging tweak -----------------------------------------------------
    def log_message(self, fmt: str, *args) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)

    # ---- dispatch ----------------------------------------------------------
    def do_GET(self) -> None:
        if self._path_is("/health"):
            self._reply_json(200, {"status": "ok", "worker": _HOSTNAME})
            return
        self._reply_json(404, {"error": f"unknown path {self.path}"})

    def do_POST(self) -> None:
        if self._path_is("/evaluate"):
            self._handle_evaluate()
            return
        if self._path_is("/preflight"):
            self._handle_setup_like("check")
            return
        if self._path_is("/setup"):
            self._handle_setup_like("setup")
            return
        self._reply_json(404, {"error": f"unknown path {self.path}"})

    # ---- /preflight + /setup ----------------------------------------------
    # Both run the per-workload `setup.sh` next to the benchmark script,
    # passing `check` (preflight) or `setup` as subcommand. The benchmark
    # path is the same one /evaluate already uses, so the coordinator
    # doesn't need to know about a separate setup-script convention.
    def _handle_setup_like(self, subcommand: str) -> None:
        if not self._auth_ok():
            self._reply_json(401, {"error": "unauthorized"})
            return

        q = parse_qs(urlparse(self.path).query)
        benchmark = (q.get("benchmark") or [""])[0]
        timeout_s = (q.get("timeout") or ["600"])[0]
        if not benchmark:
            self._reply_json(400, {"error": "missing ?benchmark="})
            return
        try:
            timeout = int(timeout_s)
        except ValueError:
            self._reply_json(400, {"error": f"invalid timeout={timeout_s!r}"})
            return

        setup_path = os.path.join(os.path.dirname(benchmark), "setup.sh")
        if not os.path.isfile(setup_path):
            self._reply_json(404, {
                "error": f"no setup.sh next to benchmark: {setup_path}",
                "ok": False,
                "worker": _HOSTNAME,
            })
            return

        try:
            cp = subprocess.run(
                ["bash", setup_path, subcommand],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            self._reply_json(200, {
                "ok": cp.returncode == 0,
                "exit_code": cp.returncode,
                "stdout": cp.stdout[-8000:],
                "stderr": cp.stderr[-8000:],
                "subcommand": subcommand,
                "setup_path": setup_path,
                "worker": _HOSTNAME,
            })
        except subprocess.TimeoutExpired as e:
            self._reply_json(200, {
                "ok": False,
                "exit_code": -1,
                "stdout": (e.stdout or b"").decode("utf-8", "replace")[-8000:] if isinstance(e.stdout, (bytes, bytearray)) else (e.stdout or "")[-8000:],
                "stderr": f"TIMEOUT after {timeout}s",
                "subcommand": subcommand,
                "setup_path": setup_path,
                "worker": _HOSTNAME,
            })
        except Exception as e:
            log.exception("setup-like %r crashed", subcommand)
            self._reply_json(500, {"error": f"setup crashed: {e}"})

    # ---- /evaluate ---------------------------------------------------------
    def _handle_evaluate(self) -> None:
        if not self._auth_ok():
            self._reply_json(401, {"error": "unauthorized"})
            return

        q = parse_qs(urlparse(self.path).query)
        benchmark = (q.get("benchmark") or [""])[0]
        timeout_s = (q.get("timeout")   or ["180"])[0]
        cgroup    = (q.get("cgroup")    or [None])[0]
        cwd       = (q.get("cwd")       or [None])[0]
        no_policy = (q.get("no_policy") or ["0"])[0] in ("1", "true", "yes")
        split_phases = (q.get("split_phases") or ["0"])[0] in ("1", "true", "yes")
        warmup_to_s  = (q.get("warmup_timeout") or [""])[0]
        weights_s = (q.get("weights") or [""])[0]
        probes_s  = (q.get("probes")  or [""])[0]
        weights = None
        probes = None
        try:
            if weights_s:
                weights = {k: float(v) for k, v in json.loads(weights_s).items()}
            if probes_s:
                probes = build_probes_from_specs(json.loads(probes_s))
        except (ValueError, json.JSONDecodeError) as e:
            self._reply_json(400, {"error": f"bad weights/probes JSON: {e}"})
            return

        if not benchmark:
            self._reply_json(400, {"error": "missing ?benchmark="})
            return
        try:
            timeout = int(timeout_s)
        except ValueError:
            self._reply_json(400, {"error": f"invalid timeout={timeout_s!r}"})
            return
        warmup_timeout: Optional[int] = None
        if warmup_to_s:
            try:
                warmup_timeout = int(warmup_to_s)
            except ValueError:
                self._reply_json(400, {"error": f"invalid warmup_timeout={warmup_to_s!r}"})
                return

        length = int(self.headers.get("Content-Length") or 0)
        if not no_policy and length <= 0:
            self._reply_json(400, {"error": "empty body; expected .out bytes (or pass ?no_policy=1)"})
            return
        binary_bytes = self.rfile.read(length) if length > 0 else b""

        binary_path = None
        if not no_policy:
            tf = tempfile.NamedTemporaryFile(
                prefix="evo-worker-", suffix=".out", delete=False,
            )
            binary_path = tf.name
            try:
                tf.write(binary_bytes)
                tf.close()
                os.chmod(binary_path, 0o755)
            except OSError as e:
                try:
                    os.unlink(binary_path)
                except OSError:
                    pass
                self._reply_json(500, {"error": f"cannot write binary: {e}"})
                return

        try:
            with _EVAL_LOCK:
                result = evaluate(
                    binary_path=binary_path,
                    benchmark_script=benchmark,
                    cgroup_path=cgroup,
                    timeout=timeout,
                    cwd=cwd,
                    weights=weights,
                    probes=probes,
                    split_phases=split_phases,
                    warmup_timeout=warmup_timeout,
                )
            body = result.to_dict()
            body["worker"] = _HOSTNAME
            self._reply_json(200, body)
        except Exception as e:
            log.exception("evaluate() crashed")
            self._reply_json(500, {"error": f"evaluate crashed: {e}"})
        finally:
            if binary_path is not None:
                try:
                    os.unlink(binary_path)
                except OSError:
                    pass

    # ---- helpers -----------------------------------------------------------
    def _path_is(self, prefix: str) -> bool:
        return urlparse(self.path).path.rstrip("/") == prefix.rstrip("/")

    def _auth_ok(self) -> bool:
        if not _AUTH_TOKEN:
            return True
        return self.headers.get("X-Auth-Token") == _AUTH_TOKEN

    def _reply_json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    ap = argparse.ArgumentParser(description="evo-worker HTTP daemon")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--token", default=os.environ.get("EVO_WORKER_TOKEN", ""),
                    help="Shared auth token; requests must send X-Auth-Token.")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s  %(message)s",
        datefmt="%H:%M:%S",
    )

    global _AUTH_TOKEN
    _AUTH_TOKEN = args.token

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    log.info(
        "listening on %s:%d (worker=%s, auth=%s)",
        args.host, args.port, _HOSTNAME, "on" if _AUTH_TOKEN else "off",
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")


if __name__ == "__main__":
    main()
