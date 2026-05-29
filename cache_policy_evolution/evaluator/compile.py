"""Compile a combined BPF+loader policy .c into a runnable `.out` binary.

Split out from evaluate.py so the evaluator itself stays focused on
"run a pre-compiled policy and measure it." Compilation lives on the
coordinator; the resulting binary is shipped to workers for execution.

Usage:
    from evaluator.compile import compile_policy, CompileResult
    r = compile_policy(code, policies_dir)
    if r.ok:
        ship r.binary_path to a worker
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from typing import Optional


# Auxiliary headers tracked in the parent repo that need to be present
# alongside the generated evo_policy.{bpf.c,c} at compile time. We stage
# them into `policies_dir` before each build so the cache_ext submodule
# stays at its upstream commit while we still own framework helpers.
#
# Add new files to this list when introducing new policy-side libraries.
_POLICY_LIB_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "policy_lib",
)
_AUX_HEADERS = ("evo_dump.h",)


def _stage_policy_lib_headers(policies_dir: str) -> None:
    """Copy parent-repo policy_lib headers into policies_dir.

    Idempotent — uses copy2 (overwrites) so a stale copy from a prior
    build can never shadow an updated source. Silent if a header is
    missing in the source dir; the build will fail with the include
    error which is more informative than a copy error here.
    """
    src_dir = os.path.normpath(_POLICY_LIB_DIR)
    if not os.path.isdir(src_dir):
        return
    for name in _AUX_HEADERS:
        src = os.path.join(src_dir, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(policies_dir, name))


# The stub skeleton header lets the loader's userspace .c syntax-check
# before `make` generates the real one. Kept alongside the compile logic
# so nothing else in the codebase has to know about it.
STUB_MARKER = "/* STUB_SKELETON_FOR_SYNTAX_CHECK_ONLY */"
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
    struct bpf_map *evo_policy_ops;
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

#endif
"""


@dataclass
class CompileResult:
    ok: bool
    binary_path: Optional[str]      # absolute path when ok, else None
    error: str                      # short error label (empty if ok)
    stderr_tail: str                # compiler diagnostics for LLM feedback


def compile_policy(
    policy_code: str,
    policies_dir: str,
) -> CompileResult:
    """Split a combined BPF+loader .c into the two files expected by the
    cache_ext Makefile, then build `evo_policy.out`.

    *policies_dir* is the `cache_ext/policies/` directory containing the
    Makefile and shared headers. It is modified in place — callers that run
    multiple compiles concurrently must serialize this call with a lock and
    snapshot the resulting binary before releasing the lock.

    The *policy_code* is the full combined source (both SECTION blocks).
    """
    from targets.code_splitter import split_sections
    from targets.compilation import CompilationPipeline

    bpf, loader = split_sections(policy_code)
    if not bpf or not loader:
        return CompileResult(
            ok=False, binary_path=None,
            error="missing SECTION markers (BPF KERNEL CODE / USERSPACE LOADER)",
            stderr_tail="",
        )

    try:
        _stage_policy_lib_headers(policies_dir)
        with open(os.path.join(policies_dir, "evo_policy.bpf.c"), "w") as f:
            f.write(bpf)
        with open(os.path.join(policies_dir, "evo_policy.c"), "w") as f:
            f.write(loader)
    except OSError as e:
        return CompileResult(
            ok=False, binary_path=None,
            error=f"cannot write split sources: {e}",
            stderr_tail="",
        )

    for stale in ("evo_policy.bpf.o", "evo_policy.skel.h", "evo_policy.out"):
        p = os.path.join(policies_dir, stale)
        if os.path.exists(p):
            try:
                os.remove(p)
            except OSError:
                pass

    binary = os.path.join(policies_dir, "evo_policy.out")
    pipeline = CompilationPipeline()
    ok, _stdout, stderr = pipeline.build(
        cwd=policies_dir,
        expected_outputs=[binary],
    )
    if not ok:
        return CompileResult(
            ok=False, binary_path=None,
            error="compile failed",
            stderr_tail=(stderr or "")[-2000:],
        )
    try:
        os.chmod(binary, 0o755)
    except OSError:
        pass
    return CompileResult(ok=True, binary_path=binary, error="", stderr_tail="")
