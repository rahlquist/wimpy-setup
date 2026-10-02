#!/usr/bin/env python3
"""Regression test for emitting integration-aware GPU variants."""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTER = ROOT / "tools" / "register_model_variant.py"


class ModelIntegrationRegistrationTests(unittest.TestCase):
    def test_cuda_variant_command_invokes_selected_integration(self):
        with tempfile.TemporaryDirectory() as temporary:
            temp = pathlib.Path(temporary)
            config = temp / "config.yaml"
            config.write_text(
                'groups:\n'
                '  nvidia-5060ti:\n'
                '    members:\n'
                '    - "existing"\n'
                'models:\n'
                '  "existing":\n'
                '    cmd: |\n'
                '      /opt/llama-cuda/bin/llama-server --model /models/existing.gguf\n',
                encoding="utf-8",
            )
            command_file = temp / "command.txt"
            command_file.write_text(
                "/opt/llama-cuda/bin/llama-server --model /models/new.gguf\n"
                "--n-gpu-layers 99 --device CUDA0 --cache-type-k q4_0 --cache-type-v q4_0\n"
                "--host 0.0.0.0 --port ${PORT} --metrics\n",
                encoding="utf-8",
            )
            renderer = temp / "render_inventory.py"
            renderer.write_text(
                "import pathlib, sys\n"
                "pathlib.Path(sys.argv[2]).write_text('inventory generated\\n')\n",
                encoding="utf-8",
            )
            metadata_dir = temp / "metadata"
            inventory = temp / "inventory.html"
            result = subprocess.run(
                [
                    sys.executable, str(REGISTER),
                    "--config", str(config),
                    "--name", "gemma4-test-cuda",
                    "--group", "nvidia-5060ti",
                    "--ttl", "300",
                    "--env", "CUDA_VISIBLE_DEVICES=0",
                    "--command-file", str(command_file),
                    "--metadata-dir", str(metadata_dir),
                    "--inventory", str(inventory),
                    "--inventory-renderer", str(renderer),
                    "--metadata-json", json.dumps({"architecture": "gemma4"}),
                    "--repository", "unsloth/gemma-4-12B-it-GGUF",
                    "--filename", "gemma-4-12B-it-Q4_K_M.gguf",
                    "--model-path", "/models/new.gguf",
                    "--effective-context", "65536",
                    "--native-context", "262144",
                    "--integration-id", "gemma4-kv-array",
                ],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            configured = config.read_text(encoding="utf-8")
            self.assertIn("--integration gemma4-kv-array --backend CUDA0 --", configured)
            self.assertIn("model_integrations/launcher.py", configured)
            sidecar = json.loads((metadata_dir / "gemma4-test-cuda.json").read_text())
            self.assertEqual(sidecar["integration_id"], "gemma4-kv-array")


if __name__ == "__main__":
    unittest.main()
