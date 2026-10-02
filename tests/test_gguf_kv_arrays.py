#!/usr/bin/env python3
"""Regression tests for per-layer GGUF KV-head arrays."""
from __future__ import annotations

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


gguf_metadata = load("gguf_metadata_test", ROOT / "tools" / "gguf_metadata.py")
cuda_fit = load("cuda_fit_test", ROOT / "tools" / "cuda_fit.py")


def gguf_string(value: str) -> bytes:
    encoded = value.encode()
    return struct.pack("<Q", len(encoded)) + encoded


def write_gemma4_fixture(path: Path, kv_heads: list[int], block_count: int | None = None) -> None:
    arch = "gemma4"
    block_count = len(kv_heads) if block_count is None else block_count
    entries = [
        ("general.architecture", 8, gguf_string(arch)),
        ("general.name", 8, gguf_string("Gemma 4 fixture")),
        (f"{arch}.context_length", 4, struct.pack("<I", 262144)),
        (f"{arch}.block_count", 4, struct.pack("<I", block_count)),
        (f"{arch}.expert_count", 4, struct.pack("<I", 0)),
        (f"{arch}.expert_used_count", 4, struct.pack("<I", 0)),
        (f"{arch}.attention.head_count", 4, struct.pack("<I", 32)),
        (f"{arch}.attention.head_count_kv", 9,
         struct.pack("<IQ", 4, len(kv_heads)) + b"".join(struct.pack("<I", n) for n in kv_heads)),
        (f"{arch}.attention.key_length", 4, struct.pack("<I", 512)),
        (f"{arch}.attention.value_length", 4, struct.pack("<I", 512)),
    ]
    with path.open("wb") as handle:
        handle.write(b"GGUF")
        handle.write(struct.pack("<IQQ", 3, 0, len(entries)))
        for key, value_type, payload in entries:
            handle.write(gguf_string(key))
            handle.write(struct.pack("<I", value_type))
            handle.write(payload)


class GGUFKeyValueArrayTests(unittest.TestCase):
    def test_reader_preserves_per_layer_kv_head_array(self):
        expected = [16, 16, 4, 16]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "gemma4.gguf"
            write_gemma4_fixture(path, expected)
            metadata = gguf_metadata.read_metadata(path)
        self.assertEqual(metadata["attention_head_count_kv"], expected)
        self.assertEqual(metadata["block_count"], len(expected))

    def test_reader_rejects_kv_array_with_wrong_layer_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "gemma4.gguf"
            write_gemma4_fixture(path, [16, 4], block_count=4)
            with self.assertRaisesRegex(ValueError, "one positive integer per block"):
                gguf_metadata.read_metadata(path)

    def test_cuda_fit_uses_each_layer_kv_head_count(self):
        metadata = {
            "block_count": 4,
            "attention_head_count_kv": [16, 16, 4, 16],
            "attention_key_length": 512,
            "attention_value_length": 512,
        }
        estimate = cuda_fit.estimate(model_bytes=100, metadata=metadata, free_bytes=10**12)
        expected_kv_bytes = int(cuda_fit.CTX * sum(metadata["attention_head_count_kv"])
                                * (512 + 512) * 0.5625)
        self.assertEqual(estimate["kv_bytes"], expected_kv_bytes)
        self.assertEqual(estimate["kv_heads_per_layer"], metadata["attention_head_count_kv"])

    def test_cuda_fit_preserves_scalar_kv_head_metadata(self):
        metadata = {
            "block_count": 4,
            "attention_head_count_kv": 8,
            "attention_key_length": 128,
            "attention_value_length": 128,
        }
        estimate = cuda_fit.estimate(model_bytes=100, metadata=metadata, free_bytes=10**12)
        expected_kv_bytes = int(cuda_fit.CTX * 4 * 8 * (128 + 128) * 0.5625)
        self.assertEqual(estimate["kv_bytes"], expected_kv_bytes)

    def test_cuda_fit_rejects_array_with_wrong_layer_count(self):
        metadata = {
            "block_count": 4,
            "attention_head_count_kv": [16, 4],
            "attention_key_length": 512,
            "attention_value_length": 512,
        }
        estimate = cuda_fit.estimate(model_bytes=100, metadata=metadata, free_bytes=10**12)
        self.assertEqual(estimate["decision"], "unknown")


if __name__ == "__main__":
    unittest.main()
