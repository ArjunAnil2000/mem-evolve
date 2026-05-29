"""
Generic YAML-driven compilation pipeline.

Config fields (all overridable via YAML):
  compiler, bpf_syntax_flags, loader_syntax_flags,
  build_command, build_timeout, syntax_timeout
"""

import logging
import os
import subprocess
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

log = logging.getLogger(__name__)


@dataclass
class CompilationConfig:
    """Compilation settings - defaults work for cache_ext."""

    compiler: str = "clang-14"
    bpf_syntax_flags: List[str] = field(default_factory=lambda: [
        "-fsyntax-only", "-target", "bpf", "-D__TARGET_ARCH_x86",
    ])
    loader_syntax_flags: List[str] = field(default_factory=lambda: [
        "-fsyntax-only", "-I", "/usr/include",
    ])
    build_command: str = "make"
    build_target: str = "evo_policy.out"
    build_timeout: int = 120
    syntax_timeout: int = 30

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "CompilationConfig":
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


class CompilationPipeline:
    """YAML-driven build pipeline."""

    def __init__(self, config: Optional[CompilationConfig] = None):
        self.config = config or CompilationConfig()

    # ------------------------------------------------------------------
    # Syntax checks
    # ------------------------------------------------------------------

    def syntax_check_bpf(
        self, source: str, include_dir: str
    ) -> Tuple[bool, str]:
        """Run syntax-only check on BPF source file.

        Returns (passed, error_msg).
        """
        cmd = [
            self.config.compiler,
            *self.config.bpf_syntax_flags,
            "-I", include_dir,
            source,
        ]
        return self._run_syntax(cmd, include_dir, "BPF")

    def syntax_check_loader(
        self, source: str, include_dir: str
    ) -> Tuple[bool, str]:
        """Run syntax-only check on userspace loader source file.

        Returns (passed, error_msg).
        """
        cmd = [
            self.config.compiler,
            *self.config.loader_syntax_flags,
            "-I", include_dir,
            source,
        ]
        return self._run_syntax(cmd, include_dir, "Loader")

    # ------------------------------------------------------------------
    # Full build
    # ------------------------------------------------------------------

    def build(
        self,
        cwd: str,
        target: Optional[str] = None,
        expected_outputs: Optional[List[str]] = None,
        stub_marker: Optional[str] = None,
        skel_path: Optional[str] = None,
    ) -> Tuple[bool, float, str]:
        """Run the full build.

        Returns (passed, partial_score, details).
        """
        target = target or self.config.build_target
        expected_outputs = expected_outputs or []

        try:
            result = subprocess.run(
                [self.config.build_command, target],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=self.config.build_timeout,
            )

            if result.returncode == 0:
                # Verify expected outputs exist
                for path in expected_outputs:
                    if not os.path.exists(path):
                        return False, 0.3, f"Build succeeded but output not found: {path}"

                # If stub_marker provided, verify skeleton is real
                if stub_marker and skel_path:
                    if os.path.exists(skel_path):
                        with open(skel_path, "r") as f:
                            head = f.read(200)
                        if stub_marker in head:
                            return (
                                False,
                                0.4,
                                "Skeleton is still stub - bpftool did not generate real skeleton.",
                            )

                return True, 0.8, ""

            # Build failed - determine partial score
            stderr = result.stderr or result.stdout or "Unknown compilation error"
            details = stderr[:2000]
            return False, 0.0, details

        except subprocess.TimeoutExpired:
            return False, 0.0, f"Compilation timed out after {self.config.build_timeout}s"
        except Exception as e:
            return False, 0.0, f"Build error: {e}"

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _run_syntax(
        self, cmd: List[str], cwd: str, label: str
    ) -> Tuple[bool, str]:
        try:
            result = subprocess.run(
                cmd,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=self.config.syntax_timeout,
            )
            if result.returncode != 0:
                err = result.stderr[:1500] if result.stderr else "Unknown syntax error"
                return False, f"{label} syntax error:\n{err}"
            return True, ""
        except subprocess.TimeoutExpired:
            return False, f"{label} syntax check timed out after {self.config.syntax_timeout}s"
        except Exception as e:
            return False, f"{label} syntax check error: {e}"
