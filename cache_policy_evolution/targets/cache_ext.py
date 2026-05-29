"""CacheExtTarget - KernelTarget implementation for cache_ext BPF policies."""

import logging
import os
from typing import Any, Dict

import yaml

from benchmarks.runner import BenchmarkRunner, BenchmarkSpec
from targets.base import KernelTarget, TargetConfig
from targets.code_splitter import split_sections
from targets.compilation import CompilationConfig, CompilationPipeline

log = logging.getLogger(__name__)

# Marker to identify stub skeleton (DO NOT CHANGE - used for detection)
STUB_MARKER = "/* STUB_SKELETON_FOR_SYNTAX_CHECK_ONLY */"

# Stub skeleton header for syntax checking (before real skeleton is generated)
STUB_SKEL_H = f"""{STUB_MARKER}
#ifndef __EVO_POLICY_SKEL_H__
#define __EVO_POLICY_SKEL_H__

#include <stdlib.h>
#include <linux/limits.h>
#include <bpf/libbpf.h>

struct evo_policy_bpf_rodata {{
    size_t cache_size;
    char watch_dir_path[PATH_MAX];
    size_t watch_dir_path_len;
}};

struct evo_policy_bpf_maps {{
    struct bpf_map *ghost_map;
    struct bpf_map *evo_policy_ops;
    struct bpf_map *folio_metadata_map;
    struct bpf_map *inode_watchlist;
}};

struct evo_policy_bpf {{
    struct bpf_object *obj;
    struct evo_policy_bpf_rodata *rodata;
    struct evo_policy_bpf_maps maps;
}};

static inline struct evo_policy_bpf *evo_policy_bpf__open(void) {{ return NULL; }}
static inline int evo_policy_bpf__load(struct evo_policy_bpf *skel) {{ return 0; }}
static inline int evo_policy_bpf__attach(struct evo_policy_bpf *skel) {{ return 0; }}
static inline void evo_policy_bpf__destroy(struct evo_policy_bpf *skel) {{}}

#endif /* __EVO_POLICY_SKEL_H__ */
"""


class CacheExtTarget(KernelTarget):
    """KernelTarget for cache_ext BPF page-cache eviction policies.

    File layout (inside policies_dir):
      evo_policy.bpf.c   - BPF kernel code
      evo_policy.c        - userspace loader
      evo_policy.bpf.o    - compiled BPF object
      evo_policy.skel.h   - skeleton header (stub or real)
      evo_policy.out      - final binary
    """

    def __init__(self, config: TargetConfig):
        super().__init__(config)

        self.policies_dir = os.path.join(config.source_dir, "policies")
        self.bpf_path = os.path.join(self.policies_dir, "evo_policy.bpf.c")
        self.loader_path = os.path.join(self.policies_dir, "evo_policy.c")
        self.bpf_obj = os.path.join(self.policies_dir, "evo_policy.bpf.o")
        self.skel_path = os.path.join(self.policies_dir, "evo_policy.skel.h")
        self.binary_path = os.path.join(self.policies_dir, config.output_binary)

        self.pipeline = CompilationPipeline(
            CompilationConfig.from_dict(config.compilation)
        )

        # Build BenchmarkSpecs from config
        self.bench_specs = [
            BenchmarkSpec.from_dict(b, base_dir=config.source_dir)
            for b in config.benchmarks
        ]
        self.runner = BenchmarkRunner(self.bench_specs, base_dir=config.source_dir)

        # Set up distributed runner if workers are configured
        self.distributed_runner = None
        if config.workers:
            try:
                from distributed.coordinator import DistributedBenchmarkRunner
                worker_urls = [w["url"] for w in config.workers]
                self.distributed_runner = DistributedBenchmarkRunner(
                    worker_urls=worker_urls,
                    specs=self.bench_specs,
                    binary_path=self.binary_path,
                    base_dir=config.source_dir,
                )
                log.info("Distributed runner configured with %d workers", len(worker_urls))
            except ImportError:
                log.warning("distributed module not available, using local runner")
            except Exception as e:
                log.warning("Failed to set up distributed runner: %s", e)

    # ------------------------------------------------------------------
    # Gate 1: prepare + syntax
    # ------------------------------------------------------------------

    def prepare_source(self, program_path: str) -> Dict[str, Any]:
        """Split combined file and write BPF + loader + stub skeleton."""
        try:
            with open(program_path, "r") as f:
                code = f.read()

            bpf_code, loader_code = split_sections(code)

            if not bpf_code or not loader_code:
                return {
                    "combined_score": 0.0,
                    "stage": "prepare",
                    "errors": (
                        'Failed to parse sections. Ensure both '
                        '"// SECTION: BPF KERNEL CODE" and '
                        '"// SECTION: USERSPACE LOADER" markers exist.'
                    ),
                }

            with open(self.bpf_path, "w") as f:
                f.write(bpf_code)
            with open(self.loader_path, "w") as f:
                f.write(loader_code)
            with open(self.skel_path, "w") as f:
                f.write(STUB_SKEL_H)

            log.info("Wrote BPF -> %s", self.bpf_path)
            log.info("Wrote loader -> %s", self.loader_path)
            log.info("Wrote stub skeleton -> %s", self.skel_path)

            return {"combined_score": 1.0, "stage": "prepare"}

        except Exception as e:
            return {"combined_score": 0.0, "stage": "prepare", "errors": str(e)}

    def syntax_check(self) -> Dict[str, Any]:
        """Check BPF and loader syntax with clang -fsyntax-only."""
        bpf_ok, bpf_err = self.pipeline.syntax_check_bpf(
            self.bpf_path, self.policies_dir
        )
        if not bpf_ok:
            return {
                "combined_score": 0.0,
                "stage": "syntax",
                "syntax_valid": False,
                "bpf_syntax_ok": False,
                "loader_syntax_ok": None,
                "errors": bpf_err,
            }

        loader_ok, loader_err = self.pipeline.syntax_check_loader(
            self.loader_path, self.policies_dir
        )
        if not loader_ok:
            return {
                "combined_score": 0.2,
                "stage": "syntax",
                "syntax_valid": False,
                "bpf_syntax_ok": True,
                "loader_syntax_ok": False,
                "errors": loader_err,
            }

        return {
            "combined_score": 0.5,
            "stage": "syntax",
            "syntax_valid": True,
            "bpf_syntax_ok": True,
            "loader_syntax_ok": True,
            "errors": "",
        }

    # ------------------------------------------------------------------
    # Gate 1 cont: compile
    # ------------------------------------------------------------------

    def compile(self) -> Dict[str, Any]:
        """Full build: clean artifacts, make, verify skeleton is real."""
        if not os.path.exists(self.bpf_path) or not os.path.exists(self.loader_path):
            return {
                "combined_score": 0.0,
                "stage": "compilation",
                "compiled": False,
                "errors": "Source files not found. Stage 1 may have failed.",
            }

        self._clean_artifacts()

        passed, partial_score, details = self.pipeline.build(
            cwd=self.policies_dir,
            expected_outputs=[self.binary_path],
            stub_marker=STUB_MARKER,
            skel_path=self.skel_path,
        )

        if passed:
            log.info("Compilation successful: %s", self.binary_path)
            # Compute partial score from intermediate artifacts
            bpf_compiled = os.path.exists(self.bpf_obj)
            skel_real = os.path.exists(self.skel_path) and not _is_stub(self.skel_path)
            return {
                "combined_score": 0.8,
                "stage": "compilation",
                "compiled": True,
                "bpf_compiled": bpf_compiled,
                "skeleton_generated": skel_real,
                "loader_compiled": True,
                "errors": "",
            }

        # Partial failure
        bpf_compiled = os.path.exists(self.bpf_obj)
        skel_real = os.path.exists(self.skel_path) and not _is_stub(self.skel_path)
        score = 0.0
        if bpf_compiled:
            score += 0.3
        if skel_real:
            score += 0.2
        score = max(score, partial_score)

        return {
            "combined_score": score,
            "stage": "compilation",
            "compiled": False,
            "bpf_compiled": bpf_compiled,
            "skeleton_generated": skel_real,
            "loader_compiled": False,
            "errors": details,
        }

    # ------------------------------------------------------------------
    # Gate 2: evaluate
    # ------------------------------------------------------------------

    def evaluate(self, program_path: str) -> Dict[str, Any]:
        """Run benchmarks with hooks (distributed if workers configured)."""
        if not os.path.exists(self.binary_path):
            return {
                "combined_score": 0.0,
                "stage": "benchmark",
                "benchmark_run": False,
                "errors": "Compiled binary not found. Stage 2 may have failed.",
            }

        os.chmod(self.binary_path, 0o755)

        runner = self.distributed_runner if self.distributed_runner else self.runner

        try:
            result = runner.run_all()
            result["stage"] = "benchmark"
            result["benchmark_run"] = result.get("combined_score", 0.0) > 0
            return result
        except Exception as e:
            return {
                "combined_score": 0.8,
                "stage": "benchmark",
                "benchmark_run": False,
                "errors": f"Benchmark error: {e}",
            }

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------

    @classmethod
    def from_yaml(cls, yaml_path: str) -> "CacheExtTarget":
        """Load a CacheExtTarget from a YAML config file.

        Resolves relative paths in the config relative to the YAML file's
        directory.
        """
        with open(yaml_path, "r") as f:
            raw = yaml.safe_load(f)

        config_dir = os.path.dirname(os.path.abspath(yaml_path))

        def _resolve(p: str) -> str:
            if p and not os.path.isabs(p):
                return os.path.abspath(os.path.join(config_dir, p))
            return p

        config = TargetConfig(
            name=raw.get("name", "cache_ext"),
            source_dir=_resolve(raw.get("source_dir", "")),
            build_dir=_resolve(raw.get("build_dir", "")),
            output_binary=raw.get("output_binary", "evo_policy.out"),
            compilation=raw.get("compilation", {}),
            benchmarks=raw.get("benchmarks", []),
            prompt_template=raw.get("prompt", ""),
            seeds=raw.get("seeds", []),
            workers=raw.get("workers", []),
        )
        return cls(config)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _clean_artifacts(self) -> None:
        """Remove old build artifacts to force fresh compilation."""
        for path in (self.bpf_obj, self.skel_path, self.binary_path):
            if os.path.exists(path):
                try:
                    os.remove(path)
                    log.info("Removed old artifact: %s", path)
                except OSError as e:
                    log.warning("Failed to remove %s: %s", path, e)


def _is_stub(path: str) -> bool:
    """Check if skeleton file is the stub (not real bpftool-generated)."""
    try:
        with open(path, "r") as f:
            head = f.read(200)
        return STUB_MARKER in head
    except OSError:
        return False
