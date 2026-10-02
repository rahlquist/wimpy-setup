#!/usr/bin/env python3
"""Tests for model-specific llama runtime integrations."""
from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.model_integrations import get_integration, resolve_integration  # noqa: E402


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


cuda_fit = load("cuda_fit_integration_test", ROOT / "tools" / "cuda_fit.py")


class ModelIntegrationTests(unittest.TestCase):
    def test_gemma4_architecture_resolves_kv_array_integration(self):
        integration = resolve_integration(
            repository="mradermacher/Gemma-4-Dark-Thoughts-V2-31B-GGUF",
            filename="Gemma-4-Dark-Thoughts-V2-31B.Q3_K_S.gguf",
            architecture="gemma4",
        )
        self.assertEqual(integration.id, "gemma4-kv-array")

    def test_ternary_binary_override_requires_exact_repository_and_filename(self):
        integration = resolve_integration(
            repository="prism-ml/Ternary-Bonsai-2-27B-gguf",
            filename="Ternary-Bonsai-2-27B-PQ2_0.gguf",
            architecture="ternary",
        )
        argv = integration.build_command(
            ["/usr/local/bin/llama-server", "--model", "/models/model.gguf"],
            backend="ROCm0",
        )
        self.assertEqual(
            argv[0],
            "/home/rahlquist/.local/share/llama-prism/prism-b10743-adfffbe/llama-server",
        )
        self.assertIsNone(resolve_integration(
            repository="prism-ml/Ternary-Bonsai-2-27B-gguf",
            filename="different-quant.gguf",
            architecture="unknown",
        ))

    def test_ternary_integration_rejects_unconfigured_backend(self):
        integration = get_integration("ternary-bonsai-prism")
        with self.assertRaisesRegex(ValueError, "no binary configured"):
            integration.build_command(["llama-server"], backend="Vulkan0")

    def test_ktopt_integration_builds_existing_container_launch(self):
        integration = resolve_integration(
            repository="wiklif/Qwen3.8-27B-KTopt-GGUF",
            filename="Qwen3.8-27B-KTopt.gguf",
            architecture="qwen3",
        )
        self.assertIsNone(resolve_integration(
            repository="wiklif/Qwen3.8-27B-KTopt-GGUF",
            filename="Qwen3.8-27B-KTopt-Q4_K_M.gguf",
            architecture="qwen3",
        ))
        argv = integration.build_command(["--port", "19042"], backend="CUDA0")
        self.assertEqual(argv, [
            "/usr/bin/docker", "run", "--rm", "--gpus", "all",
            "-v", "/home/rahlquist/kt-models:/models:ro",
            "-e", "PORT=19042", "-e", "PROFILE=auto", "-e", "GPU_INDEX=0",
            "-e", "CUDA_VISIBLE_DEVICES=0", "-e", "ALIAS=qwen3-8-27b-ktopt-cuda",
            "-p", "19042:19042", "ghcr.io/lrozewicz/kt-llama-cpp:cuda",
        ])
        self.assertFalse(integration.fetch_supported)

    def test_runtime_launcher_dispatches_integration_command(self):
        import json
        import subprocess

        launcher = ROOT / "tools" / "model_integrations" / "launcher.py"
        completed = subprocess.run(
            [sys.executable, str(launcher), "--integration", "qwen38-ktopt-docker",
             "--backend", "CUDA0", "--print-command", "--", "--port", "19042"],
            check=True, capture_output=True, text=True,
        )
        command = json.loads(completed.stdout)
        self.assertEqual(command[0], "/usr/bin/docker")
        self.assertIn("19042:19042", command)

    def test_gemma4_integration_respects_llama_short_cache_flags(self):
        integration = get_integration("gemma4-kv-array")
        argv = integration.build_command(
            ["llama-server", "-dev", "ROCm0", "-ctk", "q4_0", "-ctv", "q4_0"], backend="ROCm0"
        )
        self.assertNotIn("--cache-type-k", argv)
        self.assertNotIn("--cache-type-v", argv)

    def test_gemma4_integration_rejects_backend_device_conflict(self):
        integration = get_integration("gemma4-kv-array")
        with self.assertRaisesRegex(ValueError, "command device CUDA0 conflicts with backend ROCm0"):
            integration.build_command(
                ["llama-server", "--device", "CUDA0"], backend="ROCm0"
            )

    def test_cuda_fit_dispatches_gemma4_kv_array_estimator(self):

        metadata = {
            "architecture": "gemma4",
            "block_count": 4,
            "attention_head_count_kv": [16, 16, 4, 16],
            "attention_key_length": 512,
            "attention_value_length": 512,
        }
        result = cuda_fit.estimate(100, metadata, 10**12)
        self.assertEqual(result["integration_id"], "gemma4-kv-array")
        self.assertEqual(result["kv_heads_total"], 52)
        self.assertEqual(result["kv_bytes"], int(cuda_fit.CTX * 52 * 1024 * 0.5625))


if __name__ == "__main__":
    unittest.main()
