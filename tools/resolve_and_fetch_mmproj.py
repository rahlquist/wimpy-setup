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
import time
import re

MAX_RETRIES = int(os.environ.get("MMPROJ_MAX_RETRIES", "3"))
CHUNK_SIZE = 1 << 20

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
    """List the complete repository tree, following HF pagination."""
    url = (
        f"{API_BASE}/models/{urllib.parse.quote(repo_id, safe='/')}/tree/main"
        "?recursive=true&expand=true&limit=100"
    )
    items = []
    while url:
        req = urllib.request.Request(url, headers=auth_headers())
        with urllib.request.urlopen(req, timeout=60) as resp:
            page = json.load(resp)
            link = resp.headers.get("Link", "")
        if not isinstance(page, list):
            raise ValueError("HF repo tree response was not a list")
        items.extend(page)
        next_url = None
        for match in re.finditer(r'<([^>]+)>;\s*rel="([^"]+)"', link):
            if match.group(2) == "next":
                next_url = match.group(1)
                break
        url = next_url
    return items


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
    # Prefer exact BF16/F16 tokens. Check BF16 first because the substring
    # "f16" is also present in "bf16".
    def key(c):
        n = c[0].lower()
        if re.search(r"(?:^|[-_.])bf16(?:[-_.]|$)", n):
            return (0, -c[1])
        if re.search(r"(?:^|[-_.])f16(?:[-_.]|$)", n):
            return (1, -c[1])
        if "bf16" in n:
            return (0, -c[1])
        if "f16" in n:
            return (1, -c[1])
        # If no precision token is present, prefer the largest candidate;
        # projector files are generally not useful when truncated or tiny.
        return (2, -c[1])
    cands.sort(key=key)
    return cands[0]


def download_once(repo_id, remote_name, dest):
    url = f"https://huggingface.co/{urllib.parse.quote(repo_id, safe='/')}/resolve/main/{urllib.parse.quote(remote_name, safe='/')}"
    req = urllib.request.Request(url, headers=auth_headers())
    part = f"{dest}.part"
    with urllib.request.urlopen(req, timeout=600) as resp, open(part, "wb") as out:
        total = int(resp.headers.get("Content-Length", "0") or 0)
        downloaded = 0
        started = time.monotonic()
        last_report = 0.0
        print(
            f"[..] projector download started: {remote_name}"
            + (f" ({total / (1024**3):.2f} GiB)" if total else " (size unknown)"),
            file=sys.stderr,
            flush=True,
        )
        while True:
            chunk = resp.read(CHUNK_SIZE)
            if not chunk:
                break
            out.write(chunk)
            downloaded += len(chunk)
            now = time.monotonic()
            if now - last_report >= 1.0:
                if total:
                    percent = downloaded * 100 / total
                    detail = f"{percent:6.2f}% {downloaded / (1024**2):.0f}/{total / (1024**2):.0f} MiB"
                else:
                    detail = f"{downloaded / (1024**2):.0f} MiB"
                elapsed = max(now - started, 0.001)
                speed = downloaded / elapsed / (1024**2)
                print(f"[..] projector download: {detail} at {speed:.1f} MiB/s", file=sys.stderr, flush=True)
                last_report = now
        out.flush()
        os.fsync(out.fileno())
    if total and downloaded != total:
        raise IOError(f"short projector download: received {downloaded} of {total} bytes")
    if downloaded == 0:
        raise IOError("projector download returned an empty file")
    os.replace(part, dest)
    print(
        f"[OK] projector download complete: {dest} ({downloaded / (1024**2):.0f} MiB)",
        file=sys.stderr,
        flush=True,
    )


def download(repo_id, remote_name, dest):
    part = f"{dest}.part"
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            if os.path.exists(part):
                os.unlink(part)
            print(f"[..] projector download attempt {attempt}/{MAX_RETRIES}", file=sys.stderr, flush=True)
            download_once(repo_id, remote_name, dest)
            return
        except Exception as exc:
            if os.path.exists(part):
                os.unlink(part)
            print(f"[!!] projector download attempt {attempt} failed: {exc}", file=sys.stderr, flush=True)
            if attempt == MAX_RETRIES:
                raise
            delay = attempt
            print(f"[..] retrying projector download in {delay}s", file=sys.stderr, flush=True)
            time.sleep(delay)


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

    # 1) repo tree. This is intentionally checked even when a destination
    # exists, so a partial/stale projector cannot permanently short-circuit a
    # later fetch.
    print(f"[..] projector lookup: querying HF repo tree for {repo_id}", file=sys.stderr, flush=True)
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

    print(f"[..] projector candidate: {chosen_name}", file=sys.stderr, flush=True)

    # 2) reuse only a complete projector whose size matches HF metadata.
    if os.path.exists(dest):
        actual_size = os.path.getsize(dest)
        if _chosen_size and actual_size == _chosen_size:
            print(f"[OK] projector already present: {dest} ({actual_size / (1024**2):.0f} MiB)", file=sys.stderr, flush=True)
            print(dest)
            return 0
        print(
            f"[!!] existing projector size mismatch: {actual_size} bytes; expected {_chosen_size} — redownloading",
            file=sys.stderr,
            flush=True,
        )
        os.unlink(dest)

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
