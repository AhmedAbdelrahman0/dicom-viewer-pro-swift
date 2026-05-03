#!/usr/bin/env python3
"""Generate a tiny non-PHI DICOM Part 10 file for smoke tests."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


SOP_CLASS_UID = "1.2.840.10008.5.1.4.1.1.7"
TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.1"
IMPLEMENTATION_CLASS_UID = "1.2.826.0.1.3680043.10.54321.1"
STUDY_UID = "1.2.826.0.1.3680043.10.54321.2.20260503.1"
SERIES_UID = "1.2.826.0.1.3680043.10.54321.2.20260503.2"
INSTANCE_UID = "1.2.826.0.1.3680043.10.54321.2.20260503.3"


LONG_VR = {"OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UN", "UR", "UT"}


def _pad(value: bytes, vr: str) -> bytes:
    if len(value) % 2 == 0:
        return value
    if vr in {"OB", "OD", "OF", "OL", "OW", "UN"} or vr == "UI":
        return value + b"\0"
    return value + b" "


def _value_bytes(vr: str, value: str | bytes | int) -> bytes:
    if isinstance(value, bytes):
        return _pad(value, vr)
    if isinstance(value, int):
        if vr == "US":
            return struct.pack("<H", value)
        if vr == "UL":
            return struct.pack("<I", value)
        raise ValueError(f"Integer value is not supported for VR {vr}")
    return _pad(value.encode("ascii"), vr)


def element(group: int, elem: int, vr: str, value: str | bytes | int) -> bytes:
    payload = _value_bytes(vr, value)
    head = struct.pack("<HH", group, elem) + vr.encode("ascii")
    if vr in LONG_VR:
        return head + b"\0\0" + struct.pack("<I", len(payload)) + payload
    if len(payload) > 0xFFFF:
        raise ValueError(f"Value too large for short VR {vr}")
    return head + struct.pack("<H", len(payload)) + payload


def build_dicom() -> bytes:
    meta_without_length = b"".join([
        element(0x0002, 0x0001, "OB", b"\0\1"),
        element(0x0002, 0x0002, "UI", SOP_CLASS_UID),
        element(0x0002, 0x0003, "UI", INSTANCE_UID),
        element(0x0002, 0x0010, "UI", TRANSFER_SYNTAX_UID),
        element(0x0002, 0x0012, "UI", IMPLEMENTATION_CLASS_UID),
        element(0x0002, 0x0013, "SH", "TracerSmoke"),
    ])
    meta = element(0x0002, 0x0000, "UL", len(meta_without_length)) + meta_without_length
    dataset = b"".join([
        element(0x0008, 0x0005, "CS", "ISO_IR 192"),
        element(0x0008, 0x0016, "UI", SOP_CLASS_UID),
        element(0x0008, 0x0018, "UI", INSTANCE_UID),
        element(0x0008, 0x0020, "DA", "20260503"),
        element(0x0008, 0x0030, "TM", "120000"),
        element(0x0008, 0x0060, "CS", "OT"),
        element(0x0008, 0x0070, "LO", "Tracer"),
        element(0x0008, 0x1030, "LO", "Tracer Non-PHI Smoke Study"),
        element(0x0008, 0x103E, "LO", "Synthetic Secondary Capture"),
        element(0x0010, 0x0010, "PN", "TRACER^NONPHI"),
        element(0x0010, 0x0020, "LO", "TRACER-SMOKE"),
        element(0x0010, 0x0040, "CS", "O"),
        element(0x0020, 0x000D, "UI", STUDY_UID),
        element(0x0020, 0x000E, "UI", SERIES_UID),
        element(0x0020, 0x0010, "SH", "1"),
        element(0x0020, 0x0011, "IS", "1"),
        element(0x0020, 0x0013, "IS", "1"),
        element(0x0028, 0x0002, "US", 1),
        element(0x0028, 0x0004, "CS", "MONOCHROME2"),
        element(0x0028, 0x0010, "US", 1),
        element(0x0028, 0x0011, "US", 1),
        element(0x0028, 0x0100, "US", 16),
        element(0x0028, 0x0101, "US", 16),
        element(0x0028, 0x0102, "US", 15),
        element(0x0028, 0x0103, "US", 0),
        element(0x7FE0, 0x0010, "OW", struct.pack("<H", 0)),
    ])
    return (b"\0" * 128) + b"DICM" + meta + dataset


def write_dicom(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(build_dicom())
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a non-PHI DICOM smoke object.")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    path = write_dicom(args.output)
    print(f"NON_PHI_DICOM_OK {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
