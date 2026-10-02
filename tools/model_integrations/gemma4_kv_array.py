"""Gemma 4 integration: heterogeneous per-block KV-head metadata."""
from __future__ import annotations

from typing import Any, Sequence

from .base import ensure_device


class Gemma4KVArrayIntegration:
    id = "gemma4-kv-array"
    fetch_supported = True
    fetch_reason = ""

    def match_score(self, repository: str, filename: str, architecture: str) -> int | None:
        return 40 if architecture == "gemma4" else None

    def server_for_backend(self, backend: str) -> str | None:
        return None

    def build_command(self, base_argv: Sequence[str], backend: str) -> list[str]:
        command = ensure_device(base_argv, backend)
        if not any(option in command for option in ("--cache-type-k", "-ctk")):
            command.extend(("--cache-type-k", "q4_0"))
        if not any(option in command for option in ("--cache-type-v", "-ctv")):
            command.extend(("--cache-type-v", "q4_0"))
        return command

    def estimate_kv_cache_bytes(self, metadata: dict[str, Any], context_tokens: int,
                                bytes_per_value: float) -> int | None:
        layers = metadata.get("block_count")
        heads = metadata.get("attention_head_count_kv")
        key_len = metadata.get("attention_key_length")
        value_len = metadata.get("attention_value_length")
        if not all(type(value) is int and value > 0 for value in (layers, key_len, value_len)):
            return None
        if isinstance(heads, list):
            if len(heads) != layers or not all(type(value) is int and value > 0 for value in heads):
                raise ValueError("Gemma 4 KV-head array must contain one positive integer per block")
            total_heads = sum(heads)
        elif type(heads) is int and heads > 0:
            total_heads = layers * heads
        else:
            return None
        return int(context_tokens * total_heads * (key_len + value_len) * bytes_per_value)
