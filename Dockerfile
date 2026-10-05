# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

# Which PyTorch wheel index to use:
#   cu130 (default) - CUDA 13: Blackwell, DGX Spark (GB10), Jetson Thor, recent drivers (>= 580)
#   cu128           - CUDA 12.8: older NVIDIA drivers (>= 570)
#   cpu             - CPU only (smallest; use on macOS / Docker Desktop, which has no GPU passthrough)
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
# Git tag/branch/commit of ComfyUI to build
ARG COMFYUI_REF=master

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl ffmpeg git gosu libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv "$VIRTUAL_ENV" \
    && pip install torch torchvision torchaudio --index-url "$TORCH_INDEX_URL"

RUN git clone --depth 1 --branch "$COMFYUI_REF" https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI

WORKDIR /opt/ComfyUI
RUN pip install -r requirements.txt \
    && if [ -f manager_requirements.txt ]; then pip install -r manager_requirements.txt; fi

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && useradd --create-home --uid 1000 --shell /bin/bash comfy \
    && mkdir -p /data && chown comfy:comfy /data

ENV COMFYUI_DIR=/opt/ComfyUI \
    DATA_DIR=/data

VOLUME /data
EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
