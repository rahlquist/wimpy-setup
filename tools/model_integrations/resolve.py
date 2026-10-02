#!/usr/bin/env python3
"""Resolve the exact model-specific integration for a GGUF model."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.model_integrations import get_integration, resolve_integration  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default="")
    parser.add_argument("--filename", default="")
    parser.add_argument("--architecture", default="")
    parser.add_argument("--integration", default="")
    parser.add_argument("--supports-fetch", action="store_true")
    parser.add_argument("--server-for", default="")
    args = parser.parse_args()
    integration = (
        get_integration(args.integration)
        if args.integration
        else resolve_integration(args.repository, args.filename, args.architecture)
    )
    if integration is None:
        print("no" if args.supports_fetch else "")
        return 0
    if args.supports_fetch:
        print("yes" if integration.fetch_supported else "no")
    elif args.server_for:
        print(integration.server_for_backend(args.server_for) or "")
    else:
        print(integration.id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
