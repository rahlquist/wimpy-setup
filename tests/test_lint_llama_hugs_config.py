#!/usr/bin/env python3
"""Tests for static llama-hugs config validation."""
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import lint_llama_hugs_config as linter


VALID_AMD_CONFIG = """\
healthCheckTimeout: 180
store:
  path: /opt/llama-hugs/hugs.sqlite
groups:
  amd-r9700:
    members:
      - sample
models:
  sample:
    env:
      - HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a
    capabilities:
      context: 65536
    cmd: /usr/local/bin/llama-server --model /models/sample.gguf --device ROCm0 --host 0.0.0.0 --port ${PORT}
"""


class LlamaHugsConfigLintTests(unittest.TestCase):
    def codes(self, text):
        return {issue.code for issue in linter.lint_text(text)}

    def test_valid_amd_config_has_no_issues(self):
        self.assertEqual([], linter.lint_text(VALID_AMD_CONFIG))

    def test_missing_dynamic_port_is_reported(self):
        text = VALID_AMD_CONFIG.replace("--port ${PORT}", "--port 8080")
        self.assertIn("cmd.missing_port_placeholder", self.codes(text))

    def test_empty_port_argument_is_reported(self):
        text = VALID_AMD_CONFIG.replace("--port ${PORT}", "--port  --metrics")
        self.assertIn("cmd.empty_port", self.codes(text))

    def test_unknown_top_level_typo_is_reported(self):
        text = VALID_AMD_CONFIG.replace(
            "healthCheckTimeout: 180", "healthCheckTimeuot: 180"
        )
        self.assertIn("config.unknown_key", self.codes(text))

    def test_missing_health_check_timeout_is_reported(self):
        text = VALID_AMD_CONFIG.replace("healthCheckTimeout: 180\n", "")
        self.assertIn("config.missing_key", self.codes(text))

    def test_duplicate_yaml_keys_are_reported(self):
        text = VALID_AMD_CONFIG.replace(
            "healthCheckTimeout: 180", "healthCheckTimeout: 180\nhealthCheckTimeout: 240"
        )
        self.assertIn("yaml.parse", self.codes(text))

    def test_group_member_must_exist(self):
        text = VALID_AMD_CONFIG.replace("- sample", "- missing-model")
        self.assertIn("group.missing_model", self.codes(text))

    def test_gpu_device_must_match_group(self):
        text = VALID_AMD_CONFIG.replace("--device ROCm0", "--device CUDA0")
        self.assertIn("gpu.device_mismatch", self.codes(text))

    def test_integration_backend_is_checked_against_group(self):
        template = "cmd: /usr/local/bin/llama-server --model /models/sample.gguf --device ROCm0 --host 0.0.0.0 --port ${PORT}"
        wrapper = "cmd: /usr/bin/python3 /tools/model_integrations/launcher.py --integration gemma4-kv-array --backend ROCm0 -- /usr/local/bin/llama-server --model /models/sample.gguf --host 0.0.0.0 --port ${PORT}"
        text = VALID_AMD_CONFIG.replace(template, wrapper)
        self.assertNotIn("gpu.device_mismatch", self.codes(text))
        self.assertIn("--backend ROCm0", text)
        wrong = text.replace("--backend ROCm0", "--backend CUDA0")
        self.assertIn("gpu.device_mismatch", self.codes(wrong))

    def test_amd_pin_must_be_a_stable_uuid_not_an_index(self):
        text = VALID_AMD_CONFIG.replace(
            "HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a", "HIP_VISIBLE_DEVICES=GPU-0"
        )
        self.assertIn("gpu.env_pin", self.codes(text))

    def test_malformed_environment_entry_is_reported(self):
        text = VALID_AMD_CONFIG.replace(
            "HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a", "HIP_VISIBLE_DEVICES"
        )
        self.assertIn("model.env_entry", self.codes(text))

    def test_null_store_is_not_treated_as_omitted(self):
        text = VALID_AMD_CONFIG.replace(
            "store:\n  path: /opt/llama-hugs/hugs.sqlite", "store: null"
        )
        self.assertIn("store.type", self.codes(text))

    def test_relative_store_path_is_rejected(self):
        text = VALID_AMD_CONFIG.replace(
            "/opt/llama-hugs/hugs.sqlite", "hugs.sqlite"
        )
        self.assertIn("store.path_relative", self.codes(text))

    def test_huggingface_download_flags_are_rejected(self):
        text = VALID_AMD_CONFIG.replace(
            "--model /models/sample.gguf", "--hf-repo owner/repo"
        )
        self.assertIn("cmd.remote_model", self.codes(text))

    def test_docker_cuda_command_uses_env_pin_without_host_device_flag(self):
        text = """\
healthCheckTimeout: 180
store:
  path: /opt/llama-hugs/hugs.sqlite
groups:
  nvidia-5060ti:
    members: [container-model]
models:
  container-model:
    env:
      - CUDA_VISIBLE_DEVICES=0
    cmd: /usr/bin/docker run --gpus all -e PORT=${PORT} -e CUDA_VISIBLE_DEVICES=0 image:tag
"""
        self.assertEqual([], linter.lint_text(text))

    def test_missing_store_warns_and_can_be_required(self):
        text = VALID_AMD_CONFIG.replace(
            "store:\n  path: /opt/llama-hugs/hugs.sqlite\n", ""
        )
        warning = next(
            issue for issue in linter.lint_text(text) if issue.code == "store.missing"
        )
        self.assertEqual("warning", warning.severity)
        error = next(
            issue
            for issue in linter.lint_text(text, require_store=True)
            if issue.code == "store.missing"
        )
        self.assertEqual("error", error.severity)

    def test_sub_64k_context_is_a_warning(self):
        text = VALID_AMD_CONFIG.replace("context: 65536", "context: 64000")
        issue = next(
            issue
            for issue in linter.lint_text(text)
            if issue.code == "model.context_below_64k"
        )
        self.assertEqual("warning", issue.severity)

    def test_repository_config_has_no_errors(self):
        issues = linter.lint_file(ROOT / "llama-hugs-config.yaml")
        self.assertEqual([], [issue for issue in issues if issue.severity == "error"])


if __name__ == "__main__":
    unittest.main()
