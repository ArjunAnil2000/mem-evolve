"""KernelTarget ABC and TargetConfig dataclass."""

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import yaml

log = logging.getLogger(__name__)


@dataclass
class TargetConfig:
    """Configuration for a kernel target."""

    name: str
    source_dir: str
    build_dir: str
    output_binary: str
    compilation: Dict[str, Any] = field(default_factory=dict)
    benchmarks: List[Dict[str, Any]] = field(default_factory=list)
    prompt_template: str = ""
    seeds: List[str] = field(default_factory=list)
    workers: List[Dict[str, Any]] = field(default_factory=list)


class KernelTarget(ABC):
    """
    Abstract base class for kernel-level evolutionary targets.

    Two-gate evaluation:
      Gate 1 (syntax + compile): prepare_source -> syntax_check -> compile
      Gate 2 (benchmark): evaluate (runs benchmarks with hooks)

    Concrete evaluate_stage1/2/3() methods delegate to the abstract gates,
    providing the OpenEvolve cascade interface.
    """

    def __init__(self, config: TargetConfig):
        self.config = config

    # ------------------------------------------------------------------
    # Gate 1: compilation
    # ------------------------------------------------------------------

    @abstractmethod
    def prepare_source(self, program_path: str) -> Dict[str, Any]:
        """Split / transform the program and write source files."""

    @abstractmethod
    def syntax_check(self) -> Dict[str, Any]:
        """Quick syntax validation (clang -fsyntax-only or equivalent)."""

    @abstractmethod
    def compile(self) -> Dict[str, Any]:
        """Full build (make / cargo / etc.)."""

    # ------------------------------------------------------------------
    # Gate 2: evaluation
    # ------------------------------------------------------------------

    @abstractmethod
    def evaluate(self, program_path: str) -> Dict[str, Any]:
        """Run benchmarks with hooks and return scored results."""

    # ------------------------------------------------------------------
    # OpenEvolve cascade interface
    # ------------------------------------------------------------------

    def evaluate_stage1(self, program_path: str) -> Dict[str, Any]:
        """Stage 1: prepare source + syntax check."""
        prep = self.prepare_source(program_path)
        if prep.get("combined_score", 1.0) == 0.0:
            return prep
        return self.syntax_check()

    def evaluate_stage2(self, program_path: str) -> Dict[str, Any]:
        """Stage 2: full compilation."""
        return self.compile()

    def evaluate_stage3(self, program_path: str) -> Dict[str, Any]:
        """Stage 3: benchmark evaluation."""
        return self.evaluate(program_path)

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------

    @classmethod
    def from_yaml(cls, yaml_path: str) -> "KernelTarget":
        """Load target config from YAML and return an instance.

        Subclasses should override this if they need custom loading.
        The default implementation builds a TargetConfig and instantiates
        the class that calls it.
        """
        with open(yaml_path, "r") as f:
            raw = yaml.safe_load(f)

        config = TargetConfig(
            name=raw.get("name", "unnamed"),
            source_dir=raw.get("source_dir", ""),
            build_dir=raw.get("build_dir", ""),
            output_binary=raw.get("output_binary", ""),
            compilation=raw.get("compilation", {}),
            benchmarks=raw.get("benchmarks", []),
            prompt_template=raw.get("prompt", ""),
            seeds=raw.get("seeds", []),
            workers=raw.get("workers", []),
        )
        return cls(config)
