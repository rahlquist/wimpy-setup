#!/usr/bin/env python3
"""hugs_canonical_persist.py — mirror a registered model into the Llama Hugs
canonical registry (hugs_models / hugs_model_assets / hugs_smoke_tests) via
the fork's canonical API.

POSTs, in order:
    POST /api/hugs/models/{model_id}          -> hugs_models upsert
    POST /api/hugs/models/{model_id}/assets   -> one per asset (upsert)
    POST /api/hugs/models/{model_id}/smoke    -> smoke-test history (optional)

Additionally, if --meta-tags is supplied, the tool does a READ-MERGE-POST to
/api/hugs/meta/{model_id}: it GETs the existing tags, merges the new ones
(deduped, preserving order), and writes the union back. This lets the
pipeline's GGUF-derived signals (hf:mtp, hf:vision, hf:tools, etc.) be the
authoritative source, while still preserving any tags the fork's HF scanner
may have set independently.

The payload is one JSON file:
{
  "model_id": "hugs-...",     # runtime id the API accepts (path param)
  "model":   { ... },         # hugs.Model JSON  (model_id taken from path)
  "assets":  [ { ... }, ...], # hugs.Asset JSON (model_id taken from path)
  "smoke":   { ... } | null   # hugs.SmokeTest JSON (model_id taken from path)
}

The caller supplies every value. VRAM fields are stored verbatim (0 means
"not measured"); this tool never fabricates measurements.

Exit codes: 0 all routes succeeded; 1 usage/payload error; 2 model upsert
failed; 3 asset upsert failed; 4 smoke insert failed; 5 meta tags
read-merge-post failed (non-fatal, warned)."""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def req(method, url, obj=None, timeout=10):
    """HTTP request. Returns (status, body_str). Raises on transport error."""
    body = json.dumps(obj).encode("utf-8") if obj is not None else None
    r = urllib.request.Request(url, data=body, method=method)
    if body is not None:
        r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def post(api_url, path, obj, timeout, attempts=2):
    """POST obj to api_url+path; returns (status, body). Retries transient
    connection errors once; HTTP error responses are returned immediately."""
    url = api_url.rstrip("/") + path
    body = json.dumps(obj).encode("utf-8")
    last_exc = None
    for attempt in range(1, attempts + 1):
        r = urllib.request.Request(url, data=body, method="POST",
                                   headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:
            last_exc = e
            if attempt < attempts:
                time.sleep(1)
    if last_exc is not None:
        raise last_exc
    raise RuntimeError(f"POST {url} failed after {attempts} attempts")


def fail(rc, msg):
    print(f"hugs_canonical_persist: {msg}", file=sys.stderr)
    return rc


def merge_tags(existing, incoming):
    """Merge two comma-separated tag strings, deduped, preserving order
    (existing first, then any new from incoming)."""
    seen = set()
    out = []
    incoming_tags = {t.strip() for t in (incoming or "").split(",") if t.strip()}
    # MTP state is pipeline-authoritative. Replace the prior state rather than
    # accumulating a stale red badge after a later successful smoke test.
    replace_mtp = bool(incoming_tags & {"hf:mtp", "hf:mtp-broken"})
    for t in (existing or "").split(",") + (incoming or "").split(","):
        t = t.strip()
        if not t or t in seen:
            continue
        if replace_mtp and t in {"hf:mtp", "hf:mtp-broken"} and t not in incoming_tags:
            continue
        seen.add(t)
        out.append(t)
    return ", ".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--api-url", required=True,
                    help="Llama Hugs base URL, e.g. http://127.0.0.1:8080")
    ap.add_argument("--payload", required=True,
                    help="JSON payload file (see docstring)")
    ap.add_argument("--timeout", type=float, default=10.0,
                    help="per-request timeout in seconds")
    ap.add_argument("--meta-tags", default=None,
                    help="comma-separated hf: tags derived from GGUF inspection "
                         "(e.g. hf:vision,hf:tools,hf:mtp). Read-merged-POSTed "
                         "to /api/hugs/meta/{model} so pipeline signals are "
                         "authoritative without clobbering scanner tags.")
    args = ap.parse_args()

    try:
        with open(args.payload, encoding="utf-8") as f:
            payload = json.load(f)
    except Exception as e:
        return fail(1, f"cannot read payload {args.payload}: {e}")

    model_id = str(payload.get("model_id", "")).strip()
    if not model_id:
        return fail(1, "payload.model_id is required")
    model = payload.get("model") or {}
    assets = payload.get("assets") or []
    smoke = payload.get("smoke")
    safe_id = urllib.parse.quote(model_id, safe="")
    base_path = f"{args.api_url.rstrip('/')}/api/hugs/models/{safe_id}"

    # 1) canonical model row
    try:
        status, resp = post(args.api_url,
                            f"/api/hugs/models/{safe_id}",
                            model, args.timeout)
    except Exception as e:
        return fail(2, f"model upsert for {model_id} unreachable: {e}")
    if status < 200 or status >= 300:
        return fail(2, f"model upsert failed: HTTP {status} {resp[:300]}")
    print(f"  [OK] canonical model {model_id} (HTTP {status})")

    # 2) ancillary assets
    for asset in assets:
        a_type = str(asset.get("asset_type", "")).strip()
        if not a_type:
            return fail(3, "asset without asset_type in payload")
        try:
            status, resp = post(args.api_url,
                                f"/api/hugs/models/{safe_id}/assets",
                                asset, args.timeout)
        except Exception as e:
            return fail(3, f"asset {a_type} upsert unreachable: {e}")
        if status < 200 or status >= 300:
            return fail(3, f" asset {a_type}/{asset.get('asset_name', '')} "
                           f"upsert failed: HTTP {status} {resp[:300]}")
        print(f"  [OK] canonical asset {a_type}/{asset.get('asset_name', '')} "
              f"(HTTP {status})")

    # 3) smoke-test history (optional)
    if smoke is not None:
        try:
            status, resp = post(args.api_url,
                                f"/api/hugs/models/{safe_id}/smoke",
                                smoke, args.timeout)
        except Exception as e:
            return fail(4, f"smoke insert for {model_id} unreachable: {e}")
        if status < 200 or status >= 300:
            return fail(4, f"smoke insert failed: HTTP {status} {resp[:300]}")
        print(f"  [OK] canonical smoke test (HTTP {status})")

    # 4) meta tags — read-merge-POST (best-effort, non-fatal)
    meta_rc = 0
    if args.meta_tags:
        meta_path = (f"{args.api_url.rstrip('/')}"
                     f"/api/hugs/meta/{safe_id}")
        existing = ""
        try:
            s, body = req("GET", meta_path, timeout=args.timeout)
            if 200 <= s < 300:
                existing = json.loads(body).get("tags", "") or ""
        except Exception:
            pass  # proceed with merge anyway
        merged = merge_tags(existing, args.meta_tags)
        if merged.strip():
            try:
                s, body = post(args.api_url,
                               f"/api/hugs/meta/{safe_id}",
                               {"tags": merged}, args.timeout)
                if 200 <= s < 300:
                    # Detect whether we added anything the HF scanner missed
                    before = set(t.strip() for t in existing.split(",") if t.strip())
                    after = set(t.strip() for t in merged.split(",") if t.strip())
                    added = after - before
                    if added:
                        print(f"  [OK] canonical meta tags updated: {merged} "
                              f"(new from pipeline: {', '.join(sorted(added))})")
                    else:
                        print(f"  [OK] canonical meta tags unchanged: {merged}")
                else:
                    print(f"  [!] canonical meta tags POST failed: HTTP {s} "
                          f"{body[:200]}", file=sys.stderr)
                    meta_rc = 5
            except Exception as e:
                print(f"  [!] canonical meta tags write unreachable: {e}",
                      file=sys.stderr)
                meta_rc = 5

    summary = f"persisted {model_id}: model + {len(assets)} asset(s)"
    summary += ", smoke" if smoke is not None else ", no smoke"
    if args.meta_tags:
        summary += ", meta-tags"
    print(f"hugs_canonical_persist: {summary}")
    return meta_rc


if __name__ == "__main__":
    sys.exit(main())
