#!/usr/bin/env python3
"""Post-deploy OvisOCR smoke test and Llama Hugs non-interference check."""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

OVIS_URL = os.environ.get("OVISOCR_URL", "http://127.0.0.1:7860").rstrip("/")
HUGS_URL = os.environ.get("LLAMA_HUGS_URL", "http://127.0.0.1:8080").rstrip("/")
FIXTURE = Path(os.environ.get(
    "OVISOCR_TEST_IMAGE",
    str(Path.home() / "ovisocr/tests/fixtures/ocr-smoke.png"),
))
# Renamed to the 'lc-' prefix by the 2026-10-01 integrations pass. Override with
# LLAMA_HUGS_EXPECT_MODEL if the alias changes again.
EXPECTED_HUGS_MODEL = os.environ.get(
    "LLAMA_HUGS_EXPECT_MODEL", "lc-qwen3-8-27b-ktopt-cuda"
)


def fetch(url: str, *, data: bytes | None = None, headers: dict[str, str] | None = None):
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method="POST" if data is not None else "GET",
    )
    with urllib.request.urlopen(request, timeout=330 if data is not None else 10) as response:
        return response.read(), {key.lower(): value for key, value in response.headers.items()}


def fetch_json(url: str, *, data: bytes | None = None, headers: dict[str, str] | None = None):
    body, response_headers = fetch(url, data=data, headers=headers)
    return json.loads(body), response_headers


def unit_snapshot(unit: str) -> dict[str, str]:
    result = subprocess.run(
        [
            "systemctl", "--user", "show", unit,
            "-p", "ActiveState", "-p", "MainPID", "-p", "ActiveEnterTimestamp",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def hugs_model_ids() -> set[str]:
    payload, _ = fetch_json(f"{HUGS_URL}/v1/models")
    rows = payload.get("data")
    if not isinstance(rows, list):
        raise RuntimeError("Llama Hugs /v1/models response has no data list")
    ids = {
        row.get("id") for row in rows
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }
    if not ids:
        raise RuntimeError("Llama Hugs returned an empty model inventory")
    return ids


def ocr_multipart(image: bytes) -> dict:
    boundary = "----quill-of-hermes-" + uuid.uuid4().hex
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\novisocr2\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ocr-smoke.png\"\r\nContent-Type: image/png\r\n\r\n".encode(),
        image,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    payload, _ = fetch_json(
        f"{OVIS_URL}/api/ocr",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    return payload


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    require(FIXTURE.is_file(), f"OCR smoke fixture missing: {FIXTURE}")

    ovis_before = unit_snapshot("ovisocr.service")
    hugs_before = unit_snapshot("llama-hugs.service")
    require(ovis_before.get("ActiveState") == "active", "ovisocr.service is not active")
    require(hugs_before.get("ActiveState") == "active", "llama-hugs.service is not active")
    hugs_ids_before = hugs_model_ids()
    require(EXPECTED_HUGS_MODEL in hugs_ids_before, f"expected Llama Hugs model missing: {EXPECTED_HUGS_MODEL}")

    env_result = subprocess.run(
        ["systemctl", "--user", "show", "ovisocr.service", "-p", "Environment", "--value"],
        check=True,
        capture_output=True,
        text=True,
    )
    ovis_env = dict(item.split("=", 1) for item in shlex.split(env_result.stdout) if "=" in item)
    required_env = {
        "OVISOCR_CLI": str(Path.home() / "ovisocr/llama-mtmd-cli-patched"),
        "LLAMA_ARG_DEVICE": "none",
        "LLAMA_ARG_N_GPU_LAYERS": "0",
        "MTMD_BACKEND_DEVICE": "none",
        "LLAMA_ARG_THREADS": "4",
    }
    for key, expected in required_env.items():
        require(ovis_env.get(key) == expected, f"Ovis isolation setting {key}={ovis_env.get(key)!r}; expected {expected!r}")

    health, _ = fetch_json(f"{OVIS_URL}/health")
    require(health.get("ok") is True, "Ovis health check failed")
    require(health.get("models", {}).get("ovisocr2") is True, "OvisOCR2 model or projector is unavailable")
    require(health.get("models", {}).get("teleocr") is True, "TeleOCR model or projector is unavailable")

    html_bytes, page_headers = fetch(f"{OVIS_URL}/")
    html = html_bytes.decode("utf-8", "replace")
    require("OvisOCR2-F16" in html, "OvisOCR2 option missing from page")
    require("TeleOCR (NaviDC-OCR)" in html, "TeleOCR option missing from page")
    require("holo" not in html.lower(), "unexpected Holo model appears in Ovis page")
    require("no-store" in page_headers.get("cache-control", "").lower(), "Ovis page is cacheable")

    result = ocr_multipart(FIXTURE.read_bytes())
    markdown = result.get("markdown", "")
    normalized = markdown.upper()
    require(result.get("model") == "ovisocr2", f"unexpected OCR model response: {result.get('model')!r}")
    require(result.get("page_count") == 1, f"expected one OCR page, got {result.get('page_count')!r}")
    require("OVIS OCR SMOKE TEST" in normalized and "ORANGE 42" in normalized, "OCR smoke text was not recognized")

    ovis_after = unit_snapshot("ovisocr.service")
    hugs_after = unit_snapshot("llama-hugs.service")
    hugs_ids_after = hugs_model_ids()
    require(ovis_after.get("ActiveState") == "active", "Ovis service stopped during OCR")
    require(hugs_after.get("ActiveState") == "active", "Llama Hugs stopped during OCR")
    require(ovis_after.get("MainPID") == ovis_before.get("MainPID"), "Ovis service restarted during its OCR request")
    require(hugs_after.get("MainPID") == hugs_before.get("MainPID"), "Llama Hugs process changed during Ovis OCR")
    require(hugs_after.get("ActiveEnterTimestamp") == hugs_before.get("ActiveEnterTimestamp"), "Llama Hugs restarted during Ovis OCR")
    require(hugs_ids_after == hugs_ids_before, "Llama Hugs model inventory changed during Ovis OCR")

    print(f"PASS Ovis OCR: model=ovisocr2, pages={result['page_count']}, elapsed={result['elapsed_seconds']:.3f}s")
    print(f"PASS Ovis page: OvisOCR2 + TeleOCR only; Cache-Control={page_headers['cache-control']}")
    print(f"PASS CPU isolation: {len(required_env)} service-local settings verified")
    print(f"PASS Llama Hugs unchanged: PID={hugs_after['MainPID']}, models={len(hugs_ids_after)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
