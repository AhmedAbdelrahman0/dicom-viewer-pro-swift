#!/usr/bin/env python3
"""Run the DICOMweb smoke test against a local non-PHI test server."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import dicomweb_smoke  # noqa: E402
import generate_non_phi_dicom  # noqa: E402


def dicom_json(study_uid: str, series_uid: str | None = None,
               instance_uid: str | None = None) -> dict[str, object]:
    payload: dict[str, object] = {
        "0020000D": {"vr": "UI", "Value": [study_uid]},
        "00100010": {"vr": "PN", "Value": [{"Alphabetic": "TRACER^NONPHI"}]},
        "00100020": {"vr": "LO", "Value": ["TRACER-SMOKE"]},
        "00080020": {"vr": "DA", "Value": ["20260503"]},
    }
    if series_uid:
        payload["0020000E"] = {"vr": "UI", "Value": [series_uid]}
        payload["00080060"] = {"vr": "CS", "Value": ["OT"]}
    if instance_uid:
        payload["00080018"] = {"vr": "UI", "Value": [instance_uid]}
    return payload


class LocalDICOMwebHandler(BaseHTTPRequestHandler):
    server_version = "TracerLocalDICOMweb/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        return

    @property
    def state(self) -> dict[str, object]:
        return self.server.state  # type: ignore[attr-defined]

    def _send_json(self, value: object, status: int = 200) -> None:
        payload = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/dicom+json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_dicom(self) -> None:
        payload = self.state["dicom_bytes"]  # type: ignore[index]
        self.send_response(200)
        self.send_header("Content-Type", "application/dicom")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        if not parts or parts[0] != "dicomweb":
            self._send_json({"error": "not found"}, status=404)
            return

        study_uid = str(self.state["study_uid"])
        series_uid = str(self.state["series_uid"])
        instance_uid = str(self.state["instance_uid"])

        if parts == ["dicomweb", "studies"]:
            self._send_json([dicom_json(study_uid)])
        elif len(parts) == 4 and parts[1] == "studies" and parts[3] == "series":
            self._send_json([dicom_json(study_uid, series_uid)])
        elif len(parts) == 6 and parts[1] == "studies" and parts[3] == "series" and parts[5] == "instances":
            self._send_json([dicom_json(study_uid, series_uid, instance_uid)])
        elif len(parts) == 7 and parts[1] == "studies" and parts[3] == "series" and parts[5] == "instances":
            self._send_dicom()
        else:
            self._send_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        parts = [part for part in parsed.path.split("/") if part]
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        if parts == ["dicomweb", "studies"] and body:
            self.state["stored_count"] = int(self.state.get("stored_count", 0)) + 1
            self._send_json([{"00081190": {"vr": "UR", "Value": ["/dicomweb/studies"]}}])
        else:
            self._send_json({"error": "not found"}, status=404)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tracer-dicomweb-local-") as tmp:
        dicom_path = Path(tmp) / "tracer-non-phi-smoke.dcm"
        generate_non_phi_dicom.write_dicom(dicom_path)

        server = ThreadingHTTPServer(("127.0.0.1", 0), LocalDICOMwebHandler)
        server.state = {
            "dicom_bytes": dicom_path.read_bytes(),
            "study_uid": generate_non_phi_dicom.STUDY_UID,
            "series_uid": generate_non_phi_dicom.SERIES_UID,
            "instance_uid": generate_non_phi_dicom.INSTANCE_UID,
            "stored_count": 0,
        }
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}/dicomweb"
        print(f"DICOMWEB_LOCAL_SERVER {url}")
        print(f"DICOMWEB_LOCAL_STOW_FILE {dicom_path}")

        old_url = os.environ.get("TRACER_DICOMWEB_URL")
        old_stow = os.environ.get("TRACER_DICOMWEB_STOW_FILE")
        os.environ["TRACER_DICOMWEB_URL"] = url
        os.environ["TRACER_DICOMWEB_STOW_FILE"] = str(dicom_path)
        try:
            return dicomweb_smoke.main()
        finally:
            if old_url is None:
                os.environ.pop("TRACER_DICOMWEB_URL", None)
            else:
                os.environ["TRACER_DICOMWEB_URL"] = old_url
            if old_stow is None:
                os.environ.pop("TRACER_DICOMWEB_STOW_FILE", None)
            else:
                os.environ["TRACER_DICOMWEB_STOW_FILE"] = old_stow
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
