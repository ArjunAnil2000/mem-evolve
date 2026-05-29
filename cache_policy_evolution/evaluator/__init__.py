"""Evaluator package — compile + run a policy, measure it via probes.

Public API:

    from evaluator import compile_policy, CompileResult
    from evaluator import evaluate, EvaluationResult
    from evaluator import Probe, ProbeResult, DEFAULT_PROBES

CLI:
    python3 -m evaluator.evaluate <binary.out> <launch_script>

The compiler and the evaluator are separate functions so that:
  - the coordinator compiles once per mutation (under a lock),
  - workers only need to know how to run a pre-built binary.
"""

from evaluator.compile import CompileResult, compile_policy
from evaluator.evaluate import (
    EvaluationResult,
    evaluate,
    resolve_cgroup_path,
)
from evaluator.probes import (
    DEFAULT_PROBES,
    DEFAULT_WEIGHTS,
    JsonExtractProbe,
    Probe,
    ProbeResult,
)

__all__ = [
    "CompileResult",
    "compile_policy",
    "evaluate",
    "EvaluationResult",
    "resolve_cgroup_path",
    "Probe",
    "ProbeResult",
    "JsonExtractProbe",
    "DEFAULT_PROBES",
    "DEFAULT_WEIGHTS",
]
