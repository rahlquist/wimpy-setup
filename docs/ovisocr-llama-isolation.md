# OvisOCR / Llama Hugs post-deploy verification

Run this after changing or restarting either OvisOCR or Llama Hugs:

```bash
cd ~/wimpy-setup
python3 tools/verify_ovisocr_llama_isolation.py
```

The check is read-only with respect to Llama Hugs. It verifies both user services are active, the Ovis page exposes only OvisOCR2 and TeleOCR with cache disabled, and Ovis completes a synthetic OCR request using its CPU-only CLI settings. It snapshots Llama Hugs' process identity and `/v1/models` IDs before the OCR request and requires both to remain unchanged afterward. It does not issue a Llama Hugs generation request or restart either service.

The fixture is deployed with Quill of Hermes at `~/ovisocr/tests/fixtures/ocr-smoke.png`. Override the Ovis URL, Llama Hugs URL, fixture path, or expected Hugs model ID with `OVISOCR_URL`, `LLAMA_HUGS_URL`, `OVISOCR_TEST_IMAGE`, and `LLAMA_HUGS_EXPECT_MODEL` when needed.
