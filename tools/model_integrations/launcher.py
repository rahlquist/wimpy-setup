#!/usr/bin/env python3
"""Invoke a selected model-specific llama integration as the model process."""
from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.model_integrations import get_integration  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    try:
        separator = raw.index("--")
    except ValueError:
        print("model integration launcher requires '--' before the base command", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser()
    parser.add_argument("--integration", required=True)
    parser.add_argument("--backend", required=True)
    parser.add_argument("--print-command", action="store_true")
    options = parser.parse_args(raw[:separator])
    base_command = raw[separator + 1:]
    try:
        integration = get_integration(options.integration)
        command = integration.build_command(base_command, options.backend)
    except (ValueError, OSError) as exc:
        print(f"model integration error: {exc}", file=sys.stderr)
        return 1
    if not command:
        print("model integration produced an empty command", file=sys.stderr)
        return 1
    if options.print_command:
        print(json.dumps(command))
        return 0
    print(f"[model-integration:{integration.id}] {shlex.join(command)}", flush=True)
    os.execvpe(command[0], command, os.environ.copy())
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
