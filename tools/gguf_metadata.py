#!/usr/bin/env python3
"""Read selected GGUF metadata without loading tensors or third-party packages."""

from __future__ import annotations

import json
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
    if value_type in SCALAR_FORMATS:
        handle.seek(struct.calcsize(SCALAR_FORMATS[value_type]), 1)
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
    if value_type in SCALAR_FORMATS:
        return struct.unpack(SCALAR_FORMATS[value_type], read_exact(handle, struct.calcsize(SCALAR_FORMATS[value_type])))[0]
    if value_type == 8:
        return read_string(handle)
    raise ValueError(f"cannot read selected GGUF metadata type {value_type}")


def read_metadata(path: Path) -> dict[str, Any]:
    wanted_suffixes = {
        ".context_length",
        ".block_count",
        ".expert_count",
        ".expert_used_count",
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

        for _ in range(metadata_count):
            key = read_string(handle)
            value_type = read_u32(handle)
            if key in wanted_exact or key.endswith(tuple(wanted_suffixes)):
                result[key] = read_value(handle, value_type)
            else:
                skip_value(handle, value_type)

    architecture = result.get("general.architecture")
    if not isinstance(architecture, str) or not architecture:
        raise ValueError("GGUF is missing general.architecture")

    prefix = f"{architecture}."
    output = {
        "architecture": architecture,
        "context_length": result.get(prefix + "context_length"),
        "block_count": result.get(prefix + "block_count"),
        "expert_count": result.get(prefix + "expert_count", 0),
        "expert_used_count": result.get(prefix + "expert_used_count", 0),
        "name": result.get("general.name", ""),
        "description": result.get("general.description", ""),
    }
    for field in ("context_length", "block_count", "expert_count", "expert_used_count"):
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
