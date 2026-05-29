"""
Split combined policy files into BPF kernel code and userspace loader sections.

Preserved from old/evaluation/code_splitter.py.
"""

from typing import Tuple


def split_sections(code: str) -> Tuple[str, str]:
    """
    Split combined file into BPF and loader sections.

    Args:
        code: Combined policy file content

    Returns:
        Tuple of (bpf_code, loader_code)
    """
    bpf_marker = "// SECTION: BPF KERNEL CODE"
    loader_marker = "// SECTION: USERSPACE LOADER"

    bpf_start = code.find(bpf_marker)
    loader_start = code.find(loader_marker)

    if bpf_start == -1 or loader_start == -1:
        return "", ""

    bpf_section = code[bpf_start:loader_start].strip()
    loader_section = code[loader_start:].strip()

    bpf_code = extract_code_block(bpf_section)
    loader_code = extract_code_block(loader_section)

    return bpf_code, loader_code


def extract_code_block(section: str) -> str:
    """
    Extract code between EVOLVE-BLOCK-START and EVOLVE-BLOCK-END markers.

    Args:
        section: Section containing EVOLVE-BLOCK markers

    Returns:
        Code content between markers
    """
    start_marker = "// EVOLVE-BLOCK-START"
    end_marker = "// EVOLVE-BLOCK-END"

    start = section.find(start_marker)
    end = section.find(end_marker)

    if start != -1 and end != -1:
        code = section[start + len(start_marker):end].strip()
        return code

    return section
