"""Ternary Bonsai integration using Wimpy's Prism builds."""
from __future__ import annotations

from typing import Any, Sequence

from .base import ensure_device, ensure_options


class TernaryBonsaiPrismIntegration:
    id = "ternary-bonsai-prism"
    fetch_supported = True
    fetch_reason = ""
    repository = "prism-ml/Ternary-Bonsai-2-27B-gguf"
    filename = "Ternary-Bonsai-2-27B-PQ2_0.gguf"
    binaries = {
        "ROCm0": "/home/rahlquist/.local/share/llama-prism/prism-b10743-adfffbe/llama-server",
        "CUDA0": "/home/rahlquist/.local/share/llama-prism/prism-b10743-adfffbe-cuda133/llama-server",
    }

    def match_score(self, repository: str, filename: str, architecture: str) -> int | None:
        del architecture
        return 100 if repository == self.repository and filename == self.filename else None

    def server_for_backend(self, backend: str) -> str | None:
        return self.binaries.get(backend)

    def build_command(self, base_argv: Sequence[str], backend: str) -> list[str]:
        binary = self.server_for_backend(backend)
        if not binary:
            raise ValueError(f"no binary configured for backend {backend!r}")
        command = list(base_argv)
        if not command:
            command = [binary]
        else:
            command[0] = binary
        command = ensure_device(command, backend)
        return ensure_options(command, {
            "--n-gpu-layers": "99",
            "--flash-attn": "on",
            "--cache-type-k": "q4_0",
            "--cache-type-v": "q4_0",
            "--ctx-size": "65536",
            "--device": backend,
        })

    def estimate_kv_cache_bytes(self, metadata: dict[str, Any], context_tokens: int,
                                bytes_per_value: float) -> int | None:
        return None
