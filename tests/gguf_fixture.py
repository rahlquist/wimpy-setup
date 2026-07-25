#!/usr/bin/env python3
"""Generate a minimal valid GGUF file for testing."""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def gguf_string(s: str | bytes) -> bytes:
    """Write a GGUF-length-prefixed string (u64 len + raw bytes)."""
    if isinstance(s, str):
        s = s.encode()
    return struct.pack("<Q", len(s)) + s


def write_gguf(path: Path, *, arch: str = "llama", ctx_len: int = 65536,
               block_count: int = 32, expert_count: int = 0,
               expert_used_count: int = 0) -> None:
    """Write the smallest possible valid GGUF v3 file."""
    prefix = f"{arch}."
    # All values properly encoded: string values get gguf_string(),
    # integer values get the relevant struct.pack.
    keys_values = [
        ("general.architecture", 8, gguf_string(arch)),
        ("general.name", 8, gguf_string("test-model")),
        (f"{prefix}context_length", 4, struct.pack("<I", ctx_len)),
        (f"{prefix}block_count", 4, struct.pack("<I", block_count)),
        (f"{prefix}expert_count", 4, struct.pack("<I", expert_count)),
        (f"{prefix}expert_used_count", 4, struct.pack("<I", expert_used_count)),
    ]

    with path.open("wb") as f:
        f.write(b"GGUF")
        f.write(struct.pack("<I", 3))                # version 3
        f.write(struct.pack("<Q", 0))                 # tensor_count = 0
        f.write(struct.pack("<Q", len(keys_values)))  # metadata_kv_count

        for key, vtype, val in keys_values:
            f.write(gguf_string(key))
            f.write(struct.pack("<I", vtype))
            f.write(val)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"usage: {Path(sys.argv[0]).name} OUTPUT.gguf [arch] [ctx] [blocks] [experts] [experts_used]")
        sys.exit(2)
    path = Path(sys.argv[1])
    kw = {}
    if len(sys.argv) >= 3:
        kw["arch"] = sys.argv[2]
    if len(sys.argv) >= 4:
        kw["ctx_len"] = int(sys.argv[3])
    if len(sys.argv) >= 5:
        kw["block_count"] = int(sys.argv[4])
    if len(sys.argv) >= 6:
        kw["expert_count"] = int(sys.argv[5])
    if len(sys.argv) >= 7:
        kw["expert_used_count"] = int(sys.argv[6])
    write_gguf(path, **kw)
    print(f"wrote {path} ({path.stat().st_size} bytes)")
