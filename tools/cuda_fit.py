#!/usr/bin/env python3
"""Conservative CUDA fit estimate for a 64K llama.cpp deployment."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

GIB = 1024 ** 3
CTX = 65536
# q4_0 KV cache is approximately 0.5625 bytes/value after block scales.
# Add a full GiB for runtime buffers, CUDA allocator fragmentation, and metadata.
RUNTIME_RESERVE = GIB


def estimate(model_bytes: int, metadata: dict, free_bytes: int) -> dict:
    values = [metadata.get("block_count"), metadata.get("attention_head_count_kv"), metadata.get("attention_key_length"), metadata.get("attention_value_length")]
    if not all(isinstance(x, int) and x > 0 for x in values):
        return {"decision": "unknown", "reason": "GGUF lacks complete KV-cache dimensions"}
    layers, kv_heads, key_len, value_len = (int(x) for x in values)
    kv_bytes = int(CTX * layers * kv_heads * (key_len + value_len) * 0.5625)
    required = model_bytes + kv_bytes + RUNTIME_RESERVE
    return {
        "decision": "fit" if required <= free_bytes else "no-fit",
        "model_bytes": model_bytes,
        "context_tokens": CTX,
        "kv_bytes": kv_bytes,
        "runtime_reserve_bytes": RUNTIME_RESERVE,
        "required_bytes": required,
        "free_bytes": free_bytes,
        "layers": layers,
        "kv_heads": kv_heads,
        "key_length": key_len,
        "value_length": value_len,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-bytes", type=int, required=True)
    ap.add_argument("--metadata", required=True)
    ap.add_argument("--free-bytes", type=int, required=True)
    args = ap.parse_args()
    print(json.dumps(estimate(args.model_bytes, json.loads(Path(args.metadata).read_text()), args.free_bytes)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())