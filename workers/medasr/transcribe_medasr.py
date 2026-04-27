#!/usr/bin/env python3
"""Tracer Google MedASR dictation worker.

Reads a 16 kHz mono WAV and writes JSON:

    {"text": "...", "confidence": null, "model": "google/medasr"}

The worker intentionally has a tiny contract so the Swift app can launch it
through the same WorkerProcess spine used by nnU-Net/MONAI. Dependencies:

    pip install torch transformers accelerate soundfile

For protected Hugging Face model access, export HF_TOKEN or pass it through
Tracer's MedASR environment field.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


def _select_device(device: str) -> tuple[int, str, str]:
    if device == "cpu":
        return -1, "cpu", "cpu"
    try:
        import torch
    except Exception:
        return -1, "cpu", "cpu"
    if device == "cuda":
        if torch.cuda.is_available():
            return 0, "cuda", "cuda"
        return -1, "cpu", "cpu"
    if device == "mps":
        has_mps = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()
        # pipeline historically accepts -1/0 rather than "mps" consistently;
        # direct model execution can use the torch device string.
        return -1, "mps" if has_mps else "cpu", "mps" if has_mps else "cpu"
    if torch.cuda.is_available():
        return 0, "cuda", "cuda"
    has_mps = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()
    return -1, "mps" if has_mps else "cpu", "mps" if has_mps else "cpu"


def _normalise_pipeline_output(value: Any) -> str:
    if isinstance(value, dict):
        return str(value.get("text", "")).strip()
    if isinstance(value, list) and value:
        first = value[0]
        if isinstance(first, dict):
            return str(first.get("text", "")).strip()
    return str(value).strip()


def transcribe(args: argparse.Namespace) -> dict[str, Any]:
    try:
        import soundfile as sf
    except Exception as exc:
        raise RuntimeError(
            "Missing MedASR dependencies. Install: pip install -r workers/medasr/requirements.txt"
        ) from exc

    audio, sample_rate = sf.read(args.input, dtype="float32", always_2d=False)
    if sample_rate != 16000:
        raise RuntimeError(f"Expected 16000 Hz WAV from Tracer, got {sample_rate} Hz.")

    device_index, device_label, torch_device = _select_device(args.device)
    if args.backend == "direct":
        text = _transcribe_direct(args, audio, sample_rate, torch_device)
    else:
        text = _transcribe_pipeline(args, audio, sample_rate, device_index)
    return {
        "text": text,
        "confidence": None,
        "model": args.model,
        "device": device_label,
        "backend": args.backend,
    }


def _transcribe_pipeline(args: argparse.Namespace, audio: Any, sample_rate: int, device_index: int) -> str:
    from transformers import pipeline

    kwargs: dict[str, Any] = {
        "task": "automatic-speech-recognition",
        "model": args.model,
        "device": device_index,
    }
    if args.trust_remote_code:
        kwargs["trust_remote_code"] = True

    recognizer = pipeline(**kwargs)
    result = recognizer(
        {"array": audio, "sampling_rate": sample_rate},
        chunk_length_s=args.chunk_length_s,
        stride_length_s=args.stride_length_s,
    )
    return _normalise_pipeline_output(result)


def _transcribe_direct(args: argparse.Namespace, audio: Any, sample_rate: int, torch_device: str) -> str:
    import torch
    from transformers import AutoModelForCTC, AutoProcessor

    processor = AutoProcessor.from_pretrained(args.model)
    try:
        model = AutoModelForCTC.from_pretrained(args.model, dtype=args.dtype)
    except TypeError:
        model = AutoModelForCTC.from_pretrained(args.model, torch_dtype=args.dtype)
    model = model.to(torch_device)
    model.eval()
    inputs = processor(audio, sampling_rate=sample_rate, return_tensors="pt", padding=True)
    inputs = inputs.to(torch_device)
    with torch.inference_mode():
        # MedASR's HF example uses generate(); fall back to greedy logits for
        # CTC-style checkpoints that do not expose a generation helper.
        if hasattr(model, "generate"):
            outputs = model.generate(**inputs)
            return processor.batch_decode(outputs)[0].strip()
        logits = model(**inputs).logits
        ids = torch.argmax(logits, dim=-1)
        return processor.batch_decode(ids)[0].strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Transcribe Tracer dictation WAV with Google MedASR.")
    parser.add_argument("--input", required=True, help="Input 16 kHz mono WAV")
    parser.add_argument("--output-json", required=True, help="Output JSON path")
    parser.add_argument("--model", default="google/medasr", help="Hugging Face model id or local model path")
    parser.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda", "mps"])
    parser.add_argument("--backend", default="direct", choices=["direct", "pipeline"])
    parser.add_argument("--dtype", default="auto")
    parser.add_argument("--chunk-length-s", type=float, default=20.0)
    parser.add_argument("--stride-length-s", type=float, default=2.0)
    parser.add_argument("--trust-remote-code", action="store_true")
    args = parser.parse_args()

    try:
        payload = transcribe(args)
    except Exception as exc:
        print(f"MedASR worker failed: {exc}", file=sys.stderr)
        return 2

    output = Path(args.output_json)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    raise SystemExit(main())
