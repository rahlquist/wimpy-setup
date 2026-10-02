"""Stable contract for per-model llama integrations."""
from __future__ import annotations

from typing import Any, Protocol, Sequence


class ModelIntegration(Protocol):
    id: str
    fetch_supported: bool
    fetch_reason: str

    def match_score(self, repository: str, filename: str, architecture: str) -> int | None: ...

    def server_for_backend(self, backend: str) -> str | None: ...

    def build_command(self, base_argv: Sequence[str], backend: str) -> list[str]: ...

    def estimate_kv_cache_bytes(self, metadata: dict[str, Any], context_tokens: int,
                                bytes_per_value: float) -> int | None: ...


def ensure_options(argv: Sequence[str], options: dict[str, str]) -> list[str]:
    """Add option/value pairs only when the model command did not set them."""
    result = list(argv)
    for option, value in options.items():
        if option not in result:
            result.extend((option, value))
    return result


def ensure_device(argv: Sequence[str], backend: str) -> list[str]:
    """Require the command's llama.cpp device to agree with its routed backend."""
    result = list(argv)
    for index, token in enumerate(result):
        if token in ("--device", "-dev"):
            if index + 1 >= len(result):
                raise ValueError(f"{token} is missing its device value")
            configured = result[index + 1]
            if configured != backend:
                raise ValueError(
                    f"command device {configured} conflicts with backend {backend}"
                )
            return result
        if token.startswith("--device=") or token.startswith("-dev="):
            configured = token.split("=", 1)[1]
            if configured != backend:
                raise ValueError(
                    f"command device {configured} conflicts with backend {backend}"
                )
            return result
    if backend.startswith(("ROCm", "CUDA", "Vulkan")):
        result.extend(("--device", backend))
    return result

