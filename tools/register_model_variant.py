#!/usr/bin/env python3
"""Add a llama-swap GPU variant and its metadata sidecar transactionally."""
from __future__ import annotations
import argparse, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--group", required=True)
    ap.add_argument("--ttl", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--command-file", required=True)
    ap.add_argument("--metadata-dir", required=True)
    ap.add_argument("--inventory", required=True)
    ap.add_argument("--inventory-renderer", required=True)
    ap.add_argument("--metadata-json", required=True)
    ap.add_argument("--repository", required=True)
    ap.add_argument("--filename", required=True)
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--effective-context", required=True, type=int)
    ap.add_argument("--native-context", required=True, type=int)
    ap.add_argument("--cpu-moe", default="")
    ap.add_argument("--description", default="")
    ap.add_argument("--mmproj-path", default="")
    ap.add_argument("--repo-meta-json", default="")
    args = ap.parse_args()

    cfg = Path(args.config)
    text = cfg.read_text(encoding="utf-8")
    lines = text.splitlines()
    mi = next((i for i, line in enumerate(lines) if re.match(r"^models:\s*(?:#.*)?$", line)), None)
    if mi is None:
        raise RuntimeError("no top-level models: key found")
    child_indent = "  "
    for line in lines[mi + 1:]:
        if line.strip() and not line.lstrip().startswith("#"):
            if not line.startswith((" ", "\t")):
                break
            match = re.match(r"^(\s+)", line)
            if match is None:
                raise RuntimeError("could not determine model indentation")
            child_indent = match.group(1)
            break
    field_indent = child_indent + "  "
    cmd_indent = field_indent + "  "
    existing = set()
    for line in lines[mi + 1:]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            break
        m = re.match(r"^" + re.escape(child_indent) + r"[\"']?([^\"':]+)[\"']?\s*:", line)
        if m:
            existing.add(m.group(1))
    if args.name in existing:
        print(f"variant already exists: {args.name}")
        return 3

    group_match = re.search(r"(?m)^  " + re.escape(args.group) + r":\s*$", text)
    if not group_match:
        raise RuntimeError(f"group not found: {args.group}")
    group_start = group_match.end()
    next_group = re.search(r"(?m)^  [^ \n][^:]*:\s*$", text[group_start:])
    group_end = group_start + next_group.start() if next_group else text.find("\nmodels:", group_start)
    if group_end < 0:
        group_end = len(text)
    group_text = text[group_start:group_end]
    if re.search(r"(?m)^      - [\"']?" + re.escape(args.name) + r"[\"']?\s*$", group_text):
        raise RuntimeError(f"group already contains variant but model does not: {args.name}")
    member_pos = group_text.find("\n", group_text.find("members:"))
    if member_pos < 0:
        raise RuntimeError(f"members list not found in group: {args.group}")
    insert_at = group_start + member_pos + 1
    group_line = f'      - "{args.name}"\n'

    command = Path(args.command_file).read_text(encoding="utf-8").splitlines()
    metadata = json.loads(args.metadata_json)
    repo_meta = json.loads(args.repo_meta_json or "{}")
    mmproj_path = args.mmproj_path or ""
    has_mtp = bool(metadata.get("has_mtp"))
    block = [f'{child_indent}"{args.name}":', f'{field_indent}ttl: {args.ttl}', f'{field_indent}env: ["{args.env}"]']
    detail_lines = []
    if mmproj_path:
        detail_lines.append(f"  capabilities:")
        detail_lines.append(f'    in: ["text", "image"]')
        detail_lines.append(f'    out: ["text"]')
    detail_lines.append(f"  metadata:")
    detail_lines.append(f"    source_repo: {json.dumps(args.repository)}")
    detail_lines.append(f"    repo_url: {json.dumps(repo_meta.get('repo_url', ''))}")
    detail_lines.append(f"    file_size_bytes: {repo_meta.get('file_size_bytes')}")
    detail_lines.append(f"    file_sha256: {json.dumps(repo_meta.get('file_sha256') or '')}")
    detail_lines.append(f"    vision: {json.dumps(bool(mmproj_path))}")
    if mmproj_path:
        detail_lines.append(f"    mmproj: {json.dumps(mmproj_path)}")
        detail_lines.append(f"    mmproj_filename: {json.dumps(mmproj_path.rsplit('/', 1)[-1])}")
    if has_mtp:
        detail_lines.append(f"    mtp: true")
        detail_lines.append(f'    mtp_flag: "--spec-type draft-mtp"')
    detail_lines.append(f"    pipeline_tag: {json.dumps(repo_meta.get('pipeline_tag', '') or '')}")
    block += detail_lines + [f'{field_indent}cmd: |'] + [cmd_indent + line for line in command]
    new_text = text[:insert_at] + group_line + text[insert_at:]
    new_lines = new_text.splitlines()
    mi2 = next(i for i, line in enumerate(new_lines) if re.match(r"^models:\s*(?:#.*)?$", line))
    new_text = "\n".join(new_lines[:mi2 + 1] + block + new_lines[mi2 + 1:]) + "\n"

    metadata = json.loads(args.metadata_json)
    repo_meta = json.loads(args.repo_meta_json or "{}")
    mmproj_path = args.mmproj_path or ""
    has_mtp = bool(metadata.get("has_mtp"))
    sidecar = {
        "alias": args.name, "repository": args.repository, "filename": args.filename,
        "model_path": args.model_path, "requested_context": args.effective_context,
        "native_context": args.native_context, "n_cpu_moe": int(args.cpu_moe) if args.cpu_moe else None,
        "mmproj_path": mmproj_path or None,
        "mmproj_filename": mmproj_path.rsplit("/", 1)[-1] if mmproj_path else None,
        "vision": bool(mmproj_path) or ("image" in (repo_meta.get("pipeline_tag", "") or "").lower()),
        "has_mtp": has_mtp,
        "mtp_flag": "--spec-type draft-mtp" if has_mtp else None,
        "mtp_tensor_sample": (metadata.get("mtp_tensor_sample") or [])[:3],
        "repo_url": repo_meta.get("repo_url", ""),
        "file_size_bytes": repo_meta.get("file_size_bytes"),
        "file_sha256": repo_meta.get("file_sha256") or None,
        "has_checksum": bool(repo_meta.get("has_checksum")),
        "pipeline_tag": repo_meta.get("pipeline_tag", "") or None,
        "gguf": metadata, "description": args.description or metadata.get("name") or f"GGUF from {args.repository}",
    }
    metadata_dir = Path(args.metadata_dir)
    metadata_dir.mkdir(parents=True, exist_ok=True)
    inventory_path = Path(args.inventory)
    inventory_path.parent.mkdir(parents=True, exist_ok=True)
    sidecar_path = metadata_dir / f"{args.name}.json"
    old_config = cfg.read_bytes()
    old_sidecar = sidecar_path.read_bytes() if sidecar_path.exists() else None
    old_inventory = inventory_path.read_bytes() if inventory_path.exists() else None
    inv_tmp = Path(tempfile.mktemp(prefix="inventory.", dir=str(inventory_path.parent)))
    cfg_tmp = Path(tempfile.mktemp(prefix="config.", dir=str(cfg.parent)))
    try:
        cfg_tmp.write_text(new_text, encoding="utf-8")
        sidecar_path.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        subprocess.run([sys.executable, args.inventory_renderer, str(cfg_tmp), str(inv_tmp), str(metadata_dir)], check=True)
        shutil.copy2(cfg_tmp, cfg)
        shutil.copy2(inv_tmp, inventory_path)
    except Exception:
        cfg.write_bytes(old_config)
        if old_sidecar is None:
            sidecar_path.unlink(missing_ok=True)
        else:
            sidecar_path.write_bytes(old_sidecar)
        if old_inventory is None:
            inventory_path.unlink(missing_ok=True)
        else:
            inventory_path.write_bytes(old_inventory)
        raise
    finally:
        cfg_tmp.unlink(missing_ok=True)
        inv_tmp.unlink(missing_ok=True)
    print(f"registered CUDA variant '{args.name}'")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"variant registration failed: {exc}", file=sys.stderr)
        raise SystemExit(1)

