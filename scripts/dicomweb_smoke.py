#!/usr/bin/env python3
"""Live DICOMweb smoke test for Tracer.

The script is intentionally environment-driven so it can run in CI or from a
developer shell without writing credentials into the repo.

Required:
  TRACER_DICOMWEB_URL=https://host/dicomweb

Optional auth:
  TRACER_DICOMWEB_TOKEN=...
  TRACER_DICOMWEB_BASIC_USER=...
  TRACER_DICOMWEB_BASIC_PASSWORD=...

Optional STOW smoke:
  TRACER_DICOMWEB_STOW_FILE=/path/to/non-PHI-test.dcm
"""

from __future__ import annotations

import base64
import json
import os
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


SKIP = 77


def env(name: str) -> str:
    return os.environ.get(name, "").strip()


def url_join(base: str, path: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def headers(accept: str) -> dict[str, str]:
    values = {
        "Accept": accept,
        "User-Agent": "Tracer-DICOMweb-Smoke/1.0",
    }
    if token := env("TRACER_DICOMWEB_TOKEN"):
        values["Authorization"] = f"Bearer {token}"
    elif env("TRACER_DICOMWEB_BASIC_USER") or env("TRACER_DICOMWEB_BASIC_PASSWORD"):
        raw = f"{env('TRACER_DICOMWEB_BASIC_USER')}:{env('TRACER_DICOMWEB_BASIC_PASSWORD')}"
        values["Authorization"] = "Basic " + base64.b64encode(raw.encode()).decode()
    return values


def context() -> ssl.SSLContext | None:
    if env("TRACER_DICOMWEB_VERIFY_TLS").lower() in {"0", "false", "no"}:
        return ssl._create_unverified_context()
    return None


def request(method: str, url: str, *, accept: str, body: bytes | None = None,
            content_type: str | None = None) -> tuple[int, dict[str, str], bytes]:
    req_headers = headers(accept)
    if content_type:
        req_headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30, context=context()) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as exc:
        snippet = exc.read(500).decode("utf-8", "replace")
        raise RuntimeError(f"{method} {url} failed with HTTP {exc.code}: {snippet}") from exc


def dicom_json(url: str) -> list[dict[str, object]]:
    status, _, data = request("GET", url, accept="application/dicom+json")
    if status < 200 or status >= 300:
        raise RuntimeError(f"GET {url} failed with HTTP {status}")
    value = json.loads(data.decode("utf-8"))
    if not isinstance(value, list):
        raise RuntimeError(f"Expected DICOM JSON array from {url}")
    return value


def tag_value(item: dict[str, object], tag: str) -> str:
    entry = item.get(tag)
    if not isinstance(entry, dict):
        return ""
    values = entry.get("Value")
    if isinstance(values, list) and values:
        first = values[0]
        if isinstance(first, dict):
            return str(first.get("Alphabetic", ""))
        return str(first)
    return ""


def stow_file(base: str, path: Path) -> None:
    boundary = "TRACER-DICOMWEB-SMOKE"
    payload = (
        f"--{boundary}\r\n"
        "Content-Type: application/dicom\r\n\r\n"
    ).encode("ascii") + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode("ascii")
    status, _, _ = request(
        "POST",
        url_join(base, "studies"),
        accept="application/dicom+json",
        body=payload,
        content_type=f'multipart/related; type="application/dicom"; boundary={boundary}',
    )
    if status < 200 or status >= 300:
        raise RuntimeError(f"STOW failed with HTTP {status}")
    print("STOW_SMOKE_OK")


def main() -> int:
    base = env("TRACER_DICOMWEB_URL")
    if not base:
        print("DICOMWEB_SMOKE_SKIPPED missing TRACER_DICOMWEB_URL")
        return SKIP

    studies = dicom_json(url_join(base, "studies?limit=1"))
    if not studies:
        print("DICOMWEB_QIDO_OK studies=0")
        return 0

    study_uid = tag_value(studies[0], "0020000D")
    if not study_uid:
        raise RuntimeError("First study did not include StudyInstanceUID")
    print("DICOMWEB_QIDO_STUDIES_OK studies>=1")

    series = dicom_json(url_join(base, f"studies/{urllib.parse.quote(study_uid)}/series?limit=1"))
    if not series:
        print("DICOMWEB_QIDO_SERIES_OK series=0")
        return 0
    series_uid = tag_value(series[0], "0020000E")
    if not series_uid:
        raise RuntimeError("First series did not include SeriesInstanceUID")
    print("DICOMWEB_QIDO_SERIES_OK series>=1")

    instances = dicom_json(url_join(
        base,
        f"studies/{urllib.parse.quote(study_uid)}/series/{urllib.parse.quote(series_uid)}/instances?limit=1",
    ))
    if not instances:
        print("DICOMWEB_QIDO_INSTANCES_OK instances=0")
        return 0
    instance_uid = tag_value(instances[0], "00080018")
    if not instance_uid:
        raise RuntimeError("First instance did not include SOPInstanceUID")
    print("DICOMWEB_QIDO_INSTANCES_OK instances>=1")

    wado_url = url_join(
        base,
        "studies/{}/series/{}/instances/{}".format(
            urllib.parse.quote(study_uid),
            urllib.parse.quote(series_uid),
            urllib.parse.quote(instance_uid),
        ),
    )
    _, response_headers, body = request(
        "GET",
        wado_url,
        accept='multipart/related; type="application/dicom", application/dicom',
    )
    if not body:
        raise RuntimeError("WADO returned an empty body")
    content_type = response_headers.get("Content-Type", "")
    with tempfile.NamedTemporaryFile(prefix="tracer-dicomweb-smoke-", suffix=".bin", delete=True) as tmp:
        tmp.write(body)
        tmp.flush()
        print(f"DICOMWEB_WADO_OK bytes={len(body)} content_type={content_type}")

    if stow := env("TRACER_DICOMWEB_STOW_FILE"):
        stow_path = Path(stow).expanduser()
        if not stow_path.is_file():
            raise RuntimeError(f"TRACER_DICOMWEB_STOW_FILE does not exist: {stow_path}")
        stow_file(base, stow_path)
    else:
        print("DICOMWEB_STOW_SKIPPED missing TRACER_DICOMWEB_STOW_FILE")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"DICOMWEB_SMOKE_FAILED {exc}", file=sys.stderr)
        raise SystemExit(2)
