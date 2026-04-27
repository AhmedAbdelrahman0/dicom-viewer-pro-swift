FROM nvcr.io/nvidia/pytorch:25.03-py3

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN python3 -m pip install -q "setuptools<77" wheel && \
    python3 -m pip install --no-build-isolation --no-cache-dir -q \
      "dynamic-network-architectures>=0.3.1,<0.4" \
      "acvl-utils==0.2.5" \
      batchgenerators \
      batchgeneratorsv2 \
      SimpleITK \
      scikit-image \
      einops \
      nibabel \
      pandas \
      tqdm \
      dicom2nifti \
      imagecodecs \
      yacs \
      graphviz \
      seaborn

WORKDIR /workspace
ENTRYPOINT []
