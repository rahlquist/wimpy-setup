#!/usr/bin/env python3
"""Redact common credential forms from fetch-model diagnostics.

This is deliberately conservative: it is a last line of defence for output
and logs, not a replacement for keeping credentials out of argv and tracing.
"""

from __future__ import annotations

import re
import sys


PATTERNS = (
    (
        re.compile(
            r"(?i)(\b(?:BWS_ACCESS_TOKEN|HF_TOKEN|GITHUB_TOKEN|[A-Z0-9_]*(?:TOKEN|API_KEY|PASSWORD|SECRET|PRIVATE_KEY))\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"
        ),
        r"\1[REDACTED]",
    ),
    (
        re.compile(r"(?i)(\b(?:authorization\s*:\s*(?:bearer|token)|bearer)\s+)[^\s,;&]+"),
        r"\1[REDACTED]",
    ),
    (re.compile(r"(https?://)[^\s/@:]+:[^\s/@]+@"), r"\1[REDACTED]@"),
    (
        re.compile(r"(?i)([?&](?:token|access_token|api_key|apikey|password|secret|sig)=)[^&#\s]+"),
        r"\1[REDACTED]",
    ),
)


def redact(text: str) -> str:
    for pattern, replacement in PATTERNS:
        text = pattern.sub(replacement, text)
    return text


def main() -> int:
    for line in sys.stdin:
        sys.stdout.write(redact(line))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
