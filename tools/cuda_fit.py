#!/usr/bin/env python3
"""Conservative CUDA fit estimate for a 64K llama.cpp deployment."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model_integrations import resolve_integration

GIB = 1024 ** 3
CTX = 65536
# q4_0 KV cache is approximately 0.5625 bytes/value after block scales.
# Add a full GiB for runtime buffers, CUDA allocator fragmentation, and metadata.
RUNTIME_RESERVE = GIB


def estimate(model_bytes: int, metadata: dict, free_bytes: int) -> dict:
    layers = metadata.get("block_count")
    kv_heads = metadata.get("attention_head_count_kv")
    key_len = metadata.get("attention_key_length")
    value_len = metadata.get("attention_value_length")
    if not all(isinstance(x, int) and x > 0 for x in (layers, key_len, value_len)):
        return {"decision": "unknown", "reason": "GGUF lacks complete KV-cache dimensions"}

    integration = resolve_integration(
        repository=metadata.get("source_repo", ""),
        filename=metadata.get("filename", ""),
        architecture=metadata.get("architecture", ""),
    )
    integration_kv_bytes = None
    if integration is not None:
        integration_kv_bytes = integration.estimate_kv_cache_bytes(metadata, CTX, 0.5625)

    if isinstance(kv_heads, int) and kv_heads > 0:
        kv_heads_total = layers * kv_heads
        kv_heads_per_layer = None
    elif (
        isinstance(kv_heads, list)
        and len(kv_heads) == layers
        and all(type(heads) is int and heads > 0 for heads in kv_heads)
    ):
        # Generic fallback for per-layer KV metadata without a specialized adapter.
        kv_heads_total = sum(kv_heads)
        kv_heads_per_layer = kv_heads
    else:
        return {
            "decision": "unknown",
            "reason": "GGUF KV-head array must contain one positive integer per block",
        }

    kv_bytes = integration_kv_bytes
    if kv_bytes is None:
        kv_bytes = int(CTX * kv_heads_total * (key_len + value_len) * 0.5625)
    required = model_bytes + kv_bytes + RUNTIME_RESERVE
    result = {
        "decision": "fit" if required <= free_bytes else "no-fit",
        "model_bytes": model_bytes,
        "context_tokens": CTX,
        "kv_bytes": kv_bytes,
        "runtime_reserve_bytes": RUNTIME_RESERVE,
        "required_bytes": required,
        "free_bytes": free_bytes,
        "layers": layers,
        "kv_heads": kv_heads,
        "kv_heads_total": kv_heads_total,
        "key_length": key_len,
        "value_length": value_len,
    }
    if kv_heads_per_layer is not None:
        result["kv_heads_per_layer"] = kv_heads_per_layer
    if integration is not None:
        result["integration_id"] = integration.id
    return result


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