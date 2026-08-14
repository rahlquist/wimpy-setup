#!/usr/bin/env python3
"""fetch_repo_metadata.py — HF-repo metadata for the model being fetched.

Queries the Hugging Face API for:
  - repo display name + id + URL
  - pipeline_tag (vision? text?)
  - model card description (cardData)
  - the BASE FILE's size and LFS sha256 (when the repo advertises one)
Emits one JSON object on stdout. Exit 0 on success (even for repos that
advertise no checksum); >0 on API/network failure so fetch-model.sh can
decide whether the failure is fatal for registration.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

HF_TOKEN = os.environ.get("HF_TOKEN", "")
API_BASE = "https://huggingface.co/api"


def auth_headers():
    return {"Authorization": f"Bearer {HF_TOKEN}"} if HF_TOKEN else {}


def api_get(url):
    req = urllib.request.Request(url, headers=auth_headers())
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def main():
    if len(sys.argv) < 3:
        print("Usage: fetch_repo_metadata.py <repo_id> <base_filename>", file=sys.stderr)
        return 2
    repo_id, base_file = sys.argv[1], sys.argv[2]
    info, tree = None, None
    try:
        info = api_get(f"{API_BASE}/models/{urllib.parse.quote(repo_id, safe='/')}")
        tree = api_get(f"{API_BASE}/models/{urllib.parse.quote(repo_id, safe='/')}/tree/main")
    except urllib.error.HTTPError as e:
        print(f"HF API error for {repo_id}: {e.code} {e.reason}", file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        print(f"Cannot reach HF API: {e.reason}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        return 2

    card = (info or {}).get("cardData") or {}
    entry = next((x for x in (tree or []) if x.get("path") == base_file), None)
    lfs = (entry or {}).get("lfs") or {}
    content_sha256 = lfs.get("oid") or ""  # 64-hex SHA-256 of file content (Xet/LFS)
    out = {
        "repo_id": repo_id,
        "repo_url": f"https://huggingface.co/{repo_id}",
        "repo_name": (info or {}).get("name") or repo_id.split("/")[-1],
        "pipeline_tag": (info or {}).get("pipeline_tag", ""),
        "description": (card.get("text") or card.get("summary") or "").strip()[:2000],
        "file_size_bytes": (entry or {}).get("size") or lfs.get("size"),
        "file_sha256": content_sha256,
        "has_checksum": bool(content_sha256 and len(content_sha256) == 64),
    }
    print(json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
