#!/usr/bin/env python3
"""Read selected GGUF metadata without loading tensors or third-party packages.

Also emits best-effort multimodal signals so callers can decide whether a
model needs an external --mmproj projector file. The authoritative source for
"which projector file" remains the model's source repository file listing; the
signals here only narrow the search and guard against passing a projector to a
model that embeds its own.
"""

from __future__ import annotations

import json
import re
import struct
import sys
from pathlib import Path
from typing import BinaryIO, Any

# GGUF value type IDs from the published GGUF specification.
SCALAR_FORMATS = {
    0: "<B",   # uint8
    1: "<b",   # int8
    2: "<H",   # uint16
    3: "<h",   # int16
    4: "<I",   # uint32
    5: "<i",   # int32
    6: "<f",   # float32
    7: "<?",   # bool
    10: "<Q",  # uint64
    11: "<q",  # int64
    12: "<d",  # float64
}
SCALAR_SIZE = {k: struct.calcsize(v) for k, v in SCALAR_FORMATS.items()}  # type-id -> byte size

# Multimodal architectures whose projector is MERGED into the main GGUF.
# These must never receive an external --mmproj file.
EMBEDDED_MULTIMODAL_ARCHS = {
    "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_5_vl",
    "smolvlm", "smollm2", "pixtral", "molmo", "ovis", "janus",
}
# Architectures that are multimodal AND require a separate --mmproj file.
# (llama is intentionally excluded: a text llama and a llama-vision model share
#  the same architecture string in the main GGUF, so the repo file listing is
#  the only reliable arbiter for llama-family vision models.)
EXTERNAL_PROJECTOR_ARCHS = {
    "gemma", "gemma2", "gemma3", "minicpmv", "phi3v",
    "internvl", "idefics", "mistral", "llava", "deepseek_vl",
}

VISION_KEY_RE = re.compile(
    r"(mmproj|mm_projector|projector|vision_tower|visual|image_encoder|"
    r"vision.*(embd|block|proj)|merger|resampler)", re.IGNORECASE)


def read_exact(handle: BinaryIO, length: int) -> bytes:
    data = handle.read(length)
    if len(data) != length:
        raise ValueError("unexpected end of GGUF metadata")
    return data


def read_u32(handle: BinaryIO) -> int:
    return struct.unpack("<I", read_exact(handle, 4))[0]


def read_u64(handle: BinaryIO) -> int:
    return struct.unpack("<Q", read_exact(handle, 8))[0]


def read_string(handle: BinaryIO) -> str:
    length = read_u64(handle)
    return read_exact(handle, length).decode("utf-8", errors="replace")


def skip_value(handle: BinaryIO, value_type: int) -> None:
    if value_type in SCALAR_SIZE:
        handle.seek(SCALAR_SIZE[value_type], 1)
        return
    if value_type == 8:  # string
        handle.seek(read_u64(handle), 1)
        return
    if value_type == 9:  # array: element type + count + values
        element_type = read_u32(handle)
        count = read_u64(handle)
        for _ in range(count):
            skip_value(handle, element_type)
        return
    raise ValueError(f"unsupported GGUF metadata type {value_type}")


def read_value(handle: BinaryIO, value_type: int) -> Any:
    if value_type in SCALAR_SIZE:
        return struct.unpack(SCALAR_FORMATS[value_type], read_exact(handle, SCALAR_SIZE[value_type]))[0]
    if value_type == 8:
        return read_string(handle)
    raise ValueError(f"cannot read selected GGUF metadata type {value_type}")


def read_metadata(path: Path) -> dict[str, Any]:
    wanted_suffixes = {
        ".context_length",
        ".block_count",
        ".expert_count",
        ".expert_used_count",
        ".embedding_length",
        ".attention.head_count",
        ".attention.head_count_kv",
        ".attention.key_length",
        ".attention.value_length",
    }
    wanted_exact = {"general.architecture", "general.name", "general.description"}
    result: dict[str, Any] = {}

    with path.open("rb") as handle:
        if read_exact(handle, 4) != b"GGUF":
            raise ValueError("not a GGUF file")
        version = read_u32(handle)
        if version not in {2, 3}:
            raise ValueError(f"unsupported GGUF version {version}")
        _tensor_count = read_u64(handle)
        metadata_count = read_u64(handle)
        if metadata_count > 1_000_000:
            raise ValueError("unreasonable GGUF metadata count")

        embedded = False
        for _ in range(metadata_count):
            key = read_string(handle)
            value_type = read_u32(handle)
            if VISION_KEY_RE.search(key):
                embedded = True
            if key in wanted_exact or key.endswith(tuple(wanted_suffixes)):
                result[key] = read_value(handle, value_type)
            else:
                skip_value(handle, value_type)

        # --- Tensor-info pass: scan tensor NAMES for MTP / nextn markers ----------
        # MTP (multi-token prediction) heads appear as per-block tensors like
        # blk.N.nextn.* (Qwen3-Next family) or blk.N.mtp.*. llama.cpp enables them
        # with --spec-type draft-mtp. Reading names only (no tensor data).
        mtp_tensors = []
        try:
            tensor_count = _tensor_count
            for _ in range(tensor_count):
                tname = read_string(handle)
                n_dims = read_u32(handle)
                handle.seek(n_dims * 8, 1)      # dims (u64 each)
                read_u32(handle)                # type
                read_u64(handle)                # offset
                low = tname.lower()
                if ".nextn." in low or ".mtp." in low or low.endswith(".nextn") or low.startswith("nextn"):
                    mtp_tensors.append(tname)
                    if len(mtp_tensors) >= 5:
                        break  # enough to confirm; stop scanning early
        except (ValueError, OSError):
            mtp_tensors = []  # malformed tensor info -> treat as no MTP evidence

        has_mtp = bool(mtp_tensors)

    architecture = result.get("general.architecture")
    if not isinstance(architecture, str) or not architecture:
        raise ValueError("GGUF is missing general.architecture")

    multimodal = bool(architecture) and (
        embedded
        or architecture in EMBEDDED_MULTIMODAL_ARCHS
        or architecture in EXTERNAL_PROJECTOR_ARCHS
    )
    needs_external = bool(multimodal and not embedded and architecture in EXTERNAL_PROJECTOR_ARCHS)
    # llama-family: text vs vision cannot be distinguished from the main GGUF.
    # Surface it so the caller can require an explicit --mmproj decision.
    ambiguous_vision = (architecture == "llama" and not embedded)

    prefix = f"{architecture}."
    output = {
        "architecture": architecture,
        "context_length": result.get(prefix + "context_length"),
        "block_count": result.get(prefix + "block_count"),
        "expert_count": result.get(prefix + "expert_count", 0),
        "expert_used_count": result.get(prefix + "expert_used_count", 0),
        "embedding_length": result.get(prefix + "embedding_length"),
        "attention_head_count": result.get(prefix + "attention.head_count"),
        "attention_head_count_kv": result.get(prefix + "attention.head_count_kv"),
        "attention_key_length": result.get(prefix + "attention.key_length"),
        "attention_value_length": result.get(prefix + "attention.value_length"),
        "name": result.get("general.name", ""),
        "description": result.get("general.description", ""),
        "multimodal": multimodal,
        "embedded_projector": embedded,
        "needs_external_projector": needs_external,
        "ambiguous_vision": ambiguous_vision,
        "has_mtp": has_mtp,
        "mtp_tensor_sample": mtp_tensors[:5],
        "mtp_flag": "--spec-type draft-mtp" if has_mtp else None,
    }
    for field in ("context_length", "block_count", "expert_count", "expert_used_count",
                  "embedding_length", "attention_head_count", "attention_head_count_kv",
                  "attention_key_length", "attention_value_length"):
        if output[field] is not None and not isinstance(output[field], int):
            raise ValueError(f"GGUF {field} has an invalid type")
    return output


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} MODEL.gguf", file=sys.stderr)
        return 2
    try:
        print(json.dumps(read_metadata(Path(sys.argv[1])), sort_keys=True))
    except (OSError, ValueError) as exc:
        print(f"GGUF metadata error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
