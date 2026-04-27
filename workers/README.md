# Tracer Worker Images

Tracer can run heavy model workloads either through local binaries or through
containerized workers behind `WorkerProcess`.

## Images

- `workers/nnunet`: nnU-Net v2 worker image for `nnUNetv2_predict` and
  `nnUNetv2_predict_from_modelfolder`.
- `workers/lesiontracer`: legacy PET Segmentator / LesionTracer dependency
  image. Tracer mounts the DGX-side model folder and nnU-Net source tree at
  runtime, so the large checkpoint stays on Spark and dependencies are not
  reinstalled for every inference.
- `workers/monai`: MONAI/MONAI Label worker base for local server or
  scripted inference workflows.
- `workers/medasr`: Google MedASR medical dictation worker. Tracer writes
  one 16 kHz mono WAV per push-to-talk utterance and expects JSON with
  recognised text.

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

## MedASR Dictation

Local setup:

```bash
python3 -m venv .venv-medasr
.venv-medasr/bin/python -m pip install -r workers/medasr/requirements.txt
python3 workers/medasr/transcribe_medasr.py \
  --input utterance.wav \
  --output-json result.json \
  --model google/medasr \
  --device auto
```

If the model requires protected Hugging Face access, pass `HF_TOKEN=...` in
Tracer's MedASR environment field or the shell environment.
