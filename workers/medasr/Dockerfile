FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip setuptools wheel && \
    python3 -m pip install \
      --index-url https://download.pytorch.org/whl/cu124 \
      torch torchaudio && \
    python3 -m pip install \
      transformers \
      accelerate \
      soundfile

COPY transcribe_medasr.py /opt/tracer/transcribe_medasr.py
WORKDIR /workspace
ENTRYPOINT ["python3", "/opt/tracer/transcribe_medasr.py"]
