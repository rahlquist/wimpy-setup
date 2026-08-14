#!/usr/bin/env python3
"""Regression tests for benchmark GPU routing and explicit device commands."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WATCHER_PATH = ROOT / "benching" / "model_watcher.py"
BENCH_PATH = ROOT / "benching" / "bench_model.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


watcher = load("model_watcher_test_module", WATCHER_PATH)
bench_model = load("bench_model_test_module", BENCH_PATH)


class BenchmarkRoutingTests(unittest.TestCase):
    def test_config_aliases_are_source_of_gpu_routing(self):
        classes = watcher.model_gpu_classes(str(ROOT / "llama-swap-config.yaml"))
        self.assertIn("rocm", classes[
            "/home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q2_K_XL.gguf"])
        self.assertIn("cuda", classes[
            "/home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q2_K_XL.gguf"])

    def test_bench_command_contains_explicit_device(self):
        cmd = bench_model.build_bench_command(
            "/usr/local/bin/llama-bench", "/models/foo.gguf", "ROCm0",
            ["-p", "512"],
        )
        self.assertIn("--device", cmd)
        self.assertEqual(cmd[cmd.index("--device") + 1], "ROCm0")

    def test_bench_command_rejects_missing_device(self):
        with self.assertRaises(ValueError):
            bench_model.build_bench_command(
                "/usr/local/bin/llama-bench", "/models/foo.gguf", None,
                ["-p", "512"],
            )

    def test_gpu_rows_reject_mismatch(self):
        rows = [{"gpu_info": "NVIDIA GeForce RTX 5060 Ti"}]
        self.assertIn("mismatch", bench_model.validate_gpu_rows(
            rows, "AMD Radeon AI PRO R9700"))

    def test_gpu_rows_accept_expected_identity(self):
        rows = [{"gpu_info": "AMD Radeon AI PRO R9700, AMD Ryzen 7 7700"}]
        self.assertIsNone(bench_model.validate_gpu_rows(
            rows, "AMD Radeon AI PRO R9700"))


if __name__ == "__main__":
    unittest.main()

# test sentinel: this file must fail until routing/device enforcement exists
# (the imported functions intentionally do not exist in the current code).
#
# The sentinel comment documents why this is a RED test rather than a smoke test.
#
# End.
