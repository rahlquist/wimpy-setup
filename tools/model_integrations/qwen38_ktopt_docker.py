"""Qwen3.8 KTopt integration using its dedicated CUDA Docker runtime."""
from __future__ import annotations

import os
from typing import Any, Sequence


class Qwen38KToptDockerIntegration:
    id = "qwen38-ktopt-docker"
    fetch_supported = False
    fetch_reason = "This integration uses the dedicated ~/kt-models mount; add or update its model file there before serving."
    repository = "wiklif/Qwen3.8-27B-KTopt-GGUF"
    filename = "Qwen3.8-27B-KTopt.gguf"
    image = "ghcr.io/lrozewicz/kt-llama-cpp:cuda"
    alias = "qwen3-8-27b-ktopt-cuda"
    model_mount = "/home/rahlquist/kt-models:/models:ro"

    def match_score(self, repository: str, filename: str, architecture: str) -> int | None:
        del architecture
        return 100 if repository == self.repository and filename == self.filename else None

    def server_for_backend(self, backend: str) -> str | None:
        return "/usr/bin/docker" if backend == "CUDA0" else None

    def build_command(self, base_argv: Sequence[str], backend: str) -> list[str]:
        if backend != "CUDA0":
            raise ValueError("Qwen3.8 KTopt integration only supports CUDA0")
        args = list(base_argv)
        port = os.environ.get("PORT", "")
        if "--port" in args:
            index = args.index("--port") + 1
            if index < len(args):
                port = args[index]
        if not port or "${" in port:
            raise ValueError("Qwen3.8 KTopt integration requires the resolved --port")
        return [
            "/usr/bin/docker", "run", "--rm", "--gpus", "all",
            "-v", self.model_mount,
            "-e", f"PORT={port}",
            "-e", "PROFILE=auto",
            "-e", "GPU_INDEX=0",
            "-e", "CUDA_VISIBLE_DEVICES=0",
            "-e", f"ALIAS={self.alias}",
            "-p", f"{port}:{port}",
            self.image,
        ]

    def estimate_kv_cache_bytes(self, metadata: dict[str, Any], context_tokens: int,
                                bytes_per_value: float) -> int | None:
        return None
