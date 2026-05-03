#!/usr/bin/env python3
"""SimpleITK worker for Tracer.

The contract is intentionally file-based: Swift writes NIfTI/MetaImage inputs,
this script transforms them with SimpleITK, then writes a new image and compact
JSON metadata. Keeping the dependency behind a process boundary lets Tracer
ship without bundling Python wheels.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _parse_spacing(raw: str | None) -> tuple[float, float, float] | None:
    if not raw:
        return None
    parts = [float(part.strip()) for part in raw.split(",") if part.strip()]
    if len(parts) != 3:
        raise ValueError("--spacing expects x,y,z")
    return (parts[0], parts[1], parts[2])


def _interpolator(sitk, name: str):
    if name == "nearest":
        return sitk.sitkNearestNeighbor
    if name == "bspline":
        return sitk.sitkBSpline
    return sitk.sitkLinear


def _resample_to_spacing(sitk, image, spacing, interpolator):
    original_spacing = image.GetSpacing()
    original_size = image.GetSize()
    size = [
        max(1, int(round(original_size[i] * (original_spacing[i] / spacing[i]))))
        for i in range(3)
    ]
    return sitk.Resample(
        image,
        size,
        sitk.Transform(),
        interpolator,
        image.GetOrigin(),
        spacing,
        image.GetDirection(),
        0.0,
        image.GetPixelID(),
    )


def _run(args):
    try:
        import SimpleITK as sitk
    except Exception as exc:  # pragma: no cover - depends on local environment
        raise RuntimeError(
            "Missing SimpleITK. Install with: python3 -m pip install SimpleITK"
        ) from exc

    image = sitk.ReadImage(args.input)
    interpolator = _interpolator(sitk, args.interpolator)

    if args.operation == "n4-bias-correction":
        filter_ = sitk.N4BiasFieldCorrectionImageFilter()
        filter_.SetMaximumNumberOfIterations([max(1, args.iterations)])
        mask = sitk.OtsuThreshold(image, 0, 1, 200)
        result = filter_.Execute(image, mask)
    elif args.operation == "curvature-flow":
        result = sitk.CurvatureFlow(
            image1=image,
            timeStep=max(1e-6, args.time_step),
            numberOfIterations=max(1, args.iterations),
        )
    elif args.operation == "histogram-match":
        if not args.reference:
            raise ValueError("histogram-match requires --reference")
        reference = sitk.ReadImage(args.reference)
        filter_ = sitk.HistogramMatchingImageFilter()
        filter_.SetNumberOfHistogramLevels(256)
        filter_.SetNumberOfMatchPoints(12)
        filter_.ThresholdAtMeanIntensityOn()
        result = filter_.Execute(image, reference)
    elif args.operation == "resample-to-reference":
        if args.reference:
            reference = sitk.ReadImage(args.reference)
            result = sitk.Resample(
                image,
                reference,
                sitk.Transform(),
                interpolator,
                0.0,
                image.GetPixelID(),
            )
        else:
            spacing = _parse_spacing(args.spacing)
            if spacing is None:
                raise ValueError("resample-to-reference requires --reference or --spacing")
            result = _resample_to_spacing(sitk, image, spacing, interpolator)
    else:
        raise ValueError(f"Unsupported operation: {args.operation}")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    sitk.WriteImage(result, str(output))
    metadata = {
        "operation": args.operation,
        "output": str(output),
        "size": list(result.GetSize()),
        "spacing": list(result.GetSpacing()),
    }
    payload = json.dumps(metadata, indent=2)
    if args.output_json:
        Path(args.output_json).write_text(payload, encoding="utf-8")
    print(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run SimpleITK operation for Tracer")
    parser.add_argument("--operation", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--reference")
    parser.add_argument("--spacing")
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--time-step", type=float, default=0.0625)
    parser.add_argument("--conductance", type=float, default=3.0)
    parser.add_argument("--interpolator", default="linear",
                        choices=["linear", "nearest", "bspline"])
    parser.add_argument("--output-json")
    args = parser.parse_args()
    try:
        _run(args)
        return 0
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
