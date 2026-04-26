# Tracer Worker Images

Tracer can run heavy model workloads either through local binaries or through
containerized workers behind `WorkerProcess`.

## Images

- `workers/nnunet`: nnU-Net v2 worker image for `nnUNetv2_predict` and
  `nnUNetv2_predict_from_modelfolder`.
- `workers/monai`: MONAI/MONAI Label worker base for local server or
  scripted inference workflows.

The GitHub workflow publishes images to GHCR on pushes to `main` that touch
`workers/**`.

## Runtime Contract

The Swift app launches workers with explicit arguments, mounted folders, and
environment variables. nnU-Net expects these paths inside the container unless
overridden:

- `nnUNet_raw=/workspace/nnUNet_raw`
- `nnUNet_preprocessed=/workspace/nnUNet_preprocessed`
- `nnUNet_results=/workspace/nnUNet_results`

GPU execution uses `docker run --gpus all`; CPU-only or Apple Silicon local
execution should use the local subprocess path instead.
