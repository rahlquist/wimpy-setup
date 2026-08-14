#!/usr/bin/env python3
"""resolve_and_fetch_mmproj.py — HF-repo-grounded projector resolution + download.

Determines whether a model repo ships a multimodal projector by inspecting the
Hugging Face repo tree (NOT local GGUF keys — per project rule). Picks the best
candidate (f16 > bf16 > others), downloads it to the models dir, renamed to
<base_stem>.mmproj.gguf so it never collides with other models' projectors that
share an upstream name like mmproj-F16.gguf.

Exit semantics:
  0  + stdout path   -> projector resolved and present at that path
  0  + stdout empty  -> repo has no external mmproj; caller leaves MMPROJ_PATH unset
  >0                -> something went wrong (network, auth, repo unavailable);
                         fetch-model.sh refuses registration unless --no-mmproj was
                         explicitly supplied. It warns loudly.
"""
import os
import sys
import json
import urllib.request
import urllib.parse
import urllib.error

HF_TOKEN = os.environ.get("HF_TOKEN", "")
MODELS_DIR = os.environ.get("MODELS_DIR", os.path.expanduser("~/.cache/llama.cpp"))
API_BASE = "https://huggingface.co/api"


def auth_headers():
    h = {}
    if HF_TOKEN:
        h["Authorization"] = f"Bearer {HF_TOKEN}"
    return h


def api_get(url):
    req = urllib.request.Request(url, headers=auth_headers())
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def tree(repo_id):
    """List top-level file tree of a repo (non-recursive)."""
    url = f"{API_BASE}/models/{urllib.parse.quote(repo_id, safe='/')}/tree/main"
    return api_get(url)


def pick_mmproj(tree_items):
    """From a repo tree, return (filename, size_bytes) of the best mmproj,
    or (None, None) if the repo ships none."""
    cands = []
    for item in tree_items:
        path = item.get("path", "")
        size = item.get("size", 0)
        low = path.lower()
        if "mmproj" in low and (low.endswith(".gguf") or low.endswith(".bin")):
            cands.append((path, size))
    if not cands:
        return None, None
    # prefer f16, then bf16, then smallest by size
    def key(c):
        n = c[0].lower()
        if "f16" in n:
            return (0, -c[1])
        if "bf16" in n:
            return (1, -c[1])
        return (2, -c[1])
    cands.sort(key=key)
    return cands[0]


def download(repo_id, remote_name, dest):
    url = f"https://huggingface.co/{urllib.parse.quote(repo_id, safe='/')}/resolve/main/{urllib.parse.quote(remote_name, safe='/')}"
    req = urllib.request.Request(url, headers=auth_headers())
    with urllib.request.urlopen(req, timeout=600) as resp, open(dest, "wb") as out:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def main():
    if len(sys.argv) < 3:
        print("Usage: resolve_and_fetch_mmproj.py <repo_id> <base_gguf_filename>",
              file=sys.stderr)
        sys.exit(2)

    repo_id = sys.argv[1]
    base_file = sys.argv[2]
    if not base_file.endswith(".gguf"):
        print(f"Unexpected base file (not .gguf): {base_file}", file=sys.stderr)
        sys.exit(2)

    stem = base_file[: -len(".gguf")]
    dest = os.path.join(MODELS_DIR, f"{stem}.mmproj.gguf")

    # 1) already present? short-circuit.
    if os.path.exists(dest):
        print(dest)
        return 0

    # 2) repo tree
    try:
        items = tree(repo_id)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            print("HF_TOKEN appears invalid (HTTP 401) — projector resolution skipped.",
                  file=sys.stderr)
        elif e.code == 403:
            print(f"HF access forbidden for repo {repo_id} (HTTP 403) — skipped.",
                  file=sys.stderr)
        else:
            print(f"HF API error reading repo {repo_id}: {e.code} {e.reason} — skipped.",
                  file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        print(f"Cannot reach HF API ({e.reason}) — projector resolution skipped.",
              file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Unexpected error reading repo tree for {repo_id}: {e} — skipped.",
              file=sys.stderr)
        return 2

    chosen_name, _chosen_size = pick_mmproj(items)
    if chosen_name is None:
        # No projector shipped by this repo — not a vision model (or no external
        # projector needed). Return empty so caller leaves MMPROJ_PATH unset.
        print("", end="")
        return 0

    # 3) download
    try:
        os.makedirs(MODELS_DIR, exist_ok=True)
        download(repo_id, chosen_name, dest)
    except urllib.error.HTTPError as e:
        print(f"Download of {chosen_name} from {repo_id} failed: {e.code} {e.reason}",
              file=sys.stderr)
        return 2
    except urllib.error.URLError as e:
        print(f"Download of {chosen_name} from {repo_id} failed: {e.reason}",
              file=sys.stderr)
        return 2
    except OSError as e:
        print(f"Cannot write projector to {dest}: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"Unexpected error downloading projector {chosen_name}: {e}",
              file=sys.stderr)
        return 2

    if not os.path.exists(dest) or os.path.getsize(dest) == 0:
        print(f"Download finished but {dest} is missing/empty", file=sys.stderr)
        return 2

    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
