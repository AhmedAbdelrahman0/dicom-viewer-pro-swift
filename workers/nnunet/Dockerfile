FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel && \
    python3 -m pip install \
      --index-url https://download.pytorch.org/whl/cu124 \
      torch torchvision torchaudio && \
    python3 -m pip install \
      nnunetv2 \
      nibabel \
      SimpleITK \
      scipy \
      scikit-image

ENV nnUNet_raw=/workspace/nnUNet_raw \
    nnUNet_preprocessed=/workspace/nnUNet_preprocessed \
    nnUNet_results=/workspace/nnUNet_results

WORKDIR /workspace
ENTRYPOINT []
