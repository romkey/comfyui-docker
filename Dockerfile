# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

# Which PyTorch wheel index to use:
#   cu130 (default) - CUDA 13: Blackwell, DGX Spark (GB10), Jetson Thor, recent drivers (>= 580)
#   cu128           - CUDA 12.8: older NVIDIA drivers (>= 570)
#   cpu             - CPU only (smallest; use on macOS / Docker Desktop, which has no GPU passthrough)
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
# Git tag/branch/commit of ComfyUI to build
ARG COMFYUI_REF=master
# Bundled custom nodes: commit SHAs (or HEAD). CI passes the latest SHAs so a change upstream triggers a rebuild.
ARG COMFIER_AGENT_REF=HEAD
ARG VHS_REF=HEAD
# Identifies what is bundled in this image; CI compares it to decide whether to rebuild.
ARG BUNDLE_ID=dev

LABEL org.opencontainers.image.source="https://github.com/romkey/comfyui-docker" \
      org.opencontainers.image.licenses="MIT" \
      comfyui-docker.bundle-id="$BUNDLE_ID"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        aria2 build-essential ca-certificates curl ffmpeg git gosu libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# umask 000: the venv must stay writable by whatever PUID the container runs as, so ComfyUI-Manager and
# custom-node installers can pip install at runtime (and without a recursive chown that would double the layer).
RUN umask 000 \
    && python -m venv "$VIRTUAL_ENV" \
    && pip install torch torchvision torchaudio --index-url "$TORCH_INDEX_URL"

RUN git clone --depth 1 --branch "$COMFYUI_REF" https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI

WORKDIR /opt/ComfyUI
RUN umask 000 \
    && pip install -r requirements.txt \
    && if [ -f manager_requirements.txt ]; then pip install -r manager_requirements.txt; fi \
    && rm -rf models custom_nodes \
    && ln -s /data/models models \
    && ln -s /data/custom_nodes custom_nodes \
    && mkdir -p web/extensions \
    && chmod 777 web web/extensions

# (web/extensions is writable because older custom nodes install their JS there.)

# Bundled custom nodes live outside /data (a volume) and are symlinked into custom_nodes at start.
# Each is fetched at an exact ref (SHA or HEAD) so the image is reproducible.
RUN mkdir -p /opt/bundled_nodes \
    && git -C /opt/bundled_nodes init -q comfier-src \
    && git -C /opt/bundled_nodes/comfier-src remote add origin https://github.com/romkey/comfier-ui.git \
    && git -C /opt/bundled_nodes/comfier-src sparse-checkout set comfyui/comfier_agent \
    && git -C /opt/bundled_nodes/comfier-src fetch -q --depth 1 origin "$COMFIER_AGENT_REF" \
    && git -C /opt/bundled_nodes/comfier-src checkout -q FETCH_HEAD \
    && mv /opt/bundled_nodes/comfier-src/comfyui/comfier_agent /opt/bundled_nodes/comfier_agent \
    && rm -rf /opt/bundled_nodes/comfier-src \
    && git -C /opt/bundled_nodes init -q ComfyUI-VideoHelperSuite \
    && git -C /opt/bundled_nodes/ComfyUI-VideoHelperSuite remote add origin https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
    && git -C /opt/bundled_nodes/ComfyUI-VideoHelperSuite fetch -q --depth 1 origin "$VHS_REF" \
    && git -C /opt/bundled_nodes/ComfyUI-VideoHelperSuite checkout -q FETCH_HEAD \
    && rm -rf /opt/bundled_nodes/ComfyUI-VideoHelperSuite/.git
RUN umask 000 && pip install -r /opt/bundled_nodes/ComfyUI-VideoHelperSuite/requirements.txt

# CLI tools in their own venv so their dependencies can't conflict with ComfyUI's.
RUN umask 000 \
    && python -m venv /opt/tools \
    && /opt/tools/bin/pip install "huggingface_hub[cli]" comfy-cli \
    && ln -s /opt/tools/bin/hf /usr/local/bin/hf \
    && printf '#!/bin/sh\nexec /opt/tools/bin/comfy --skip-prompt --workspace="${COMFYUI_DIR:-/opt/ComfyUI}" "$@"\n' > /usr/local/bin/comfy \
    && chmod +x /usr/local/bin/comfy

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && useradd --create-home --uid 1000 --shell /bin/bash comfy \
    && mkdir -p /data && chown comfy:comfy /data

# Hugging Face downloads (hf CLI, node downloads) are cached on the data volume.
# Pass HF_TOKEN and HF_ENDPOINT at run time; they are deliberately not set here.
ENV COMFYUI_DIR=/opt/ComfyUI \
    DATA_DIR=/data \
    HF_HOME=/data/cache/huggingface

VOLUME /data
EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${COMFYUI_PORT:-8188}/system_stats >/dev/null"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
