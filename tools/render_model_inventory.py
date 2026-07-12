#!/usr/bin/env python3
"""Generate a static model inventory from llama-swap config and local sidecars."""
from __future__ import annotations

import datetime as dt
import html
import json
import re
import shlex
import sys
from pathlib import Path


def model_blocks(text: str):
    match = re.search(r"(?m)^models:\s*(?:#.*)?$", text)
    if not match:
        raise ValueError("no top-level models: key")
    lines = text[match.end():].splitlines()
    current = None
    entries = []
    for line in lines:
        if line and not line.startswith((" ", "\t")):
            break
        key = re.match(r'^  ["\']?([^"\':]+)["\']?:\s*$', line)
        if key:
            if current:
                entries.append(current)
            current = {"alias": key.group(1), "lines": []}
        elif current:
            current["lines"].append(line)
    if current:
        entries.append(current)
    return entries


def command_for(entry):
    lines = entry["lines"]
    start = next((i for i, line in enumerate(lines) if re.match(r"^    cmd:\s*[|>]\s*$", line)), None)
    if start is None:
        return ""
    out = []
    for line in lines[start + 1:]:
        if line.startswith("    ") and not line.startswith("      "):
            break
        if line.startswith("      "):
            out.append(line[6:])
    return " ".join(x.strip() for x in out)


def args_for(command):
    try:
        tokens = shlex.split(command.replace("${PORT}", "PORT"))
    except ValueError:
        return command
    if not tokens:
        return ""
    keep = []
    i = 1
    while i < len(tokens):
        token = tokens[i]
        if token in {"--model", "-m", "--host", "--port"}:
            i += 2
            continue
        keep.append(token)
        if token.startswith("-") and i + 1 < len(tokens) and not tokens[i + 1].startswith("-"):
            keep.append(tokens[i + 1])
            i += 2
        else:
            i += 1
    return " ".join(keep)


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: render_model_inventory.py CONFIG.yaml OUTPUT.html MODELS_DIR", file=sys.stderr)
        return 2
    config, output, models_dir = map(Path, sys.argv[1:])
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    rows = []
    for entry in model_blocks(config.read_text(encoding="utf-8")):
        command = command_for(entry)
        model_match = re.search(r"(?:--model|-m)\s+(\S+)", command)
        model_path = Path(model_match.group(1)) if model_match else None
        filename = model_path.name if model_path else "unknown"
        sidecar_path = models_dir / f"{entry['alias']}.json"
        sidecar = {}
        if sidecar_path.is_file():
            try:
                sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                pass
        added = sidecar.get("downloaded_at", today)
        description = sidecar.get("description") or f"Locally configured GGUF model: {filename}."
        native = sidecar.get("native_context", "unknown")
        architecture = sidecar.get("gguf", {}).get("architecture", "unknown")
        rows.append({
            "alias": entry["alias"], "filename": filename, "added": added,
            "description": description, "native": native, "architecture": architecture,
            "params": args_for(command),
        })
    rows.sort(key=lambda row: row["alias"])
    body = "\n".join(
        "<tr>"
        f"<td>{html.escape(str(row['alias']))}</td>"
        f"<td>{html.escape(str(row['filename']))}</td>"
        f"<td>{html.escape(str(row['added']))}</td>"
        f"<td>{html.escape(str(row['architecture']))}</td>"
        f"<td>{html.escape(str(row['native']))}</td>"
        f"<td>{html.escape(str(row['description']))}</td>"
        f"<td><code>{html.escape(str(row['params']))}</code></td>"
        "</tr>" for row in rows
    )
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wimpy model inventory</title>
<style>body{{font:15px system-ui,sans-serif;margin:2rem;color:#172033;background:#f7fbff}}h1{{color:#143f6b}}table{{border-collapse:collapse;width:100%;background:#fff}}th,td{{text-align:left;vertical-align:top;border:1px solid #b9cde0;padding:.6rem}}th{{background:#dceeff}}code{{white-space:pre-wrap;word-break:break-word}}small{{color:#4a5d70}}</style>
</head><body><h1>Wimpy llama.cpp model inventory</h1><p><small>Generated from <code>llama-swap-config.yaml</code>. Existing entries without a local metadata sidecar use this inventory's initial generation date.</small></p>
<table><thead><tr><th>llama-swap alias</th><th>Filename</th><th>Added (UTC)</th><th>Architecture</th><th>Native context</th><th>Description</th><th>Custom llama.cpp parameters</th></tr></thead><tbody>
{body}
</tbody></table></body></html>
"""
    output.write_text(document, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
