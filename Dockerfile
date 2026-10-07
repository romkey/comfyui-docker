# syntax=docker/dockerfile:1

# Image flavor: "plain" (default), "sage" (adds SageAttention compiled for Blackwell GPUs; needs a CUDA torch index),
# "rocm" (AMD Strix Halo defaults; use with an AMD ROCm TORCH_INDEX_URL)
# or "xpu" (Intel Arc user-space GPU driver; use with the xpu torch index and a trixie BASE_IMAGE).
# BuildKit only builds the stages the chosen flavor needs, so plain builds never touch the CUDA toolkit stage.
ARG FLAVOR=plain
# Intel's GPU driver packages need glibc >= 2.38, so the xpu flavor builds on python:3.12-slim-trixie.
ARG BASE_IMAGE=python:3.12-slim-bookworm

FROM ${BASE_IMAGE} AS runtime

# Which PyTorch wheel index to use:
#   cu130 (default) - CUDA 13: Blackwell, DGX Spark (GB10), Jetson Thor, recent drivers (>= 580)
#   cu128           - CUDA 12.8: older NVIDIA drivers (>= 570)
#   cpu             - CPU only (smallest; use on macOS / Docker Desktop, which has no GPU passthrough)
#   https://repo.amd.com/rocm/whl/gfx1151/ - AMD Strix Halo (Ryzen AI Max); pair with FLAVOR=rocm. Other AMD
#                     families have their own index there (gfx1150, gfx110X-all, gfx120X-all, ...). x86_64 only.
#   xpu             - Intel Arc (Battlemage B580, Arc Pro B70, Alchemist); pair with FLAVOR=xpu. x86_64 only.
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
    && ln -s /opt/tools/bin/hf /usr/local/bin/hf
COPY --chmod=755 scripts/comfy /usr/local/bin/comfy

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

# ---------------------------------------------------------------------------
# SageAttention flavor
# ---------------------------------------------------------------------------
FROM runtime AS sage-builder
# CUDA toolkit used only to compile; Debian 12's arm64 (sbsa) repo starts at 13.1, so use 13.1 for both arches.
ARG CUDA_VERSION=13.1
ARG SAGE_REF=HEAD
# Blackwell: 10.0 = B200/GB200, 12.0 = RTX 50, 12.1 = DGX Spark (GB10). Upstream does not support 11.0 (Jetson Thor).
ARG SAGE_ARCHS="10.0;12.0;12.1"
# nvcc on these kernels needs ~3-4 GB per job; keep this low on small runners.
ARG MAX_JOBS=2
ARG NVCC_THREADS=2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN case "$(dpkg --print-architecture)" in amd64) repo=x86_64 ;; arm64) repo=sbsa ;; *) exit 1 ;; esac \
    && curl -fsSLO "https://developer.download.nvidia.com/compute/cuda/repos/debian12/${repo}/cuda-keyring_1.1-1_all.deb" \
    && dpkg -i cuda-keyring_1.1-1_all.deb \
    && rm cuda-keyring_1.1-1_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends "cuda-toolkit-${CUDA_VERSION//./-}" \
    && rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda-${CUDA_VERSION}
RUN git init -q /src/sage \
    && git -C /src/sage remote add origin https://github.com/thu-ml/SageAttention.git \
    && git -C /src/sage fetch -q --depth 1 origin "$SAGE_REF" \
    && git -C /src/sage checkout -q FETCH_HEAD

WORKDIR /src/sage
# Current PyTorch headers require C++20 but SageAttention's setup.py pins C++17.
ARG CXX_STD=c++20
RUN sed -i -e "s/-std=c++17/-std=${CXX_STD}/g" -e "s/--threads=8/--threads=${NVCC_THREADS}/" setup.py \
    && pip install ninja setuptools wheel packaging \
    && TORCH_CUDA_ARCH_LIST="$SAGE_ARCHS" EXT_PARALLEL="${MAX_JOBS}" \
       pip wheel --no-build-isolation --no-deps -w /wheels .

FROM runtime AS runtime-sage
ARG CUDA_VERSION=13.1
ARG SAGE_ARCHS="10.0;12.0;12.1"
COPY --from=sage-builder /wheels /tmp/wheels
# Triton's bundled ptxas predates sm_121 (DGX Spark); point it at the CUDA toolkit's ptxas.
COPY --from=sage-builder /usr/local/cuda-${CUDA_VERSION}/bin/ptxas /usr/local/bin/ptxas-cuda
RUN umask 000 \
    && pip install /tmp/wheels/*.whl triton \
    && rm -rf /tmp/wheels \
    && python -c "import sageattention"
# COMFYUI_ATTENTION=auto: the entrypoint enables --use-sage-attention only on GPUs this build supports.
ENV TRITON_PTXAS_PATH=/usr/local/bin/ptxas-cuda \
    SAGE_ARCHS=${SAGE_ARCHS} \
    COMFYUI_ATTENTION=auto

# ---------------------------------------------------------------------------
# AMD ROCm flavor (Strix Halo, gfx1151). Defaults are community-reported fixes for unified-memory APUs;
# all can be overridden at run time.
# ---------------------------------------------------------------------------
FROM runtime AS runtime-rocm
# HSA_OVERRIDE_GFX_VERSION pins the ISA; SDMA/SVM off avoid GPU ring timeouts and corrupted VAE output on
# unified memory. mmap off avoids very slow/hanging loads above 64 GB; bf16 VAE avoids OOM while decoding.
# The MIOpen kernel cache goes on the data volume so tuning survives container restarts.
ENV HSA_OVERRIDE_GFX_VERSION=11.5.1 \
    HSA_ENABLE_SDMA=0 \
    HSA_USE_SVM=0 \
    MIOPEN_USER_DB_PATH=/data/cache/miopen \
    MIOPEN_CUSTOM_CACHE_DIR=/data/cache/miopen \
    COMFYUI_DISABLE_MMAP=true \
    COMFYUI_BF16_VAE=true

# ---------------------------------------------------------------------------
# Intel Arc flavor (Battlemage: B580, Arc Pro B70; also Alchemist). The xpu PyTorch wheels bundle the SYCL/oneAPI
# runtime but not the GPU's user-space driver, so install Intel's compute runtime (Level Zero + OpenCL) here.
# The host only needs the xe (or i915) kernel driver. x86_64 only.
# ---------------------------------------------------------------------------
FROM runtime AS runtime-xpu
# Bump together from https://github.com/intel/compute-runtime/releases (its notes name the matching IGC version).
# The compute runtime's own packages are checked against its published sum file; IGC and the Level Zero loader
# publish no sums, so their SHA-256s are pinned here.
ARG NEO_VERSION=26.35.39758.10
ARG GMMLIB_VERSION=22.10.0
ARG IGC_VERSION=2.41.5+22716
ARG IGC_CORE_SHA256=0a6e64a663ae65a0fa02d6912ae3b6b37cf85b90c21cc423fd9fef70aaf4f628
ARG IGC_OPENCL_SHA256=779e1b9e88098eb25711e9a8f67c2752665bad22f134aa40ed5649f6e1b87058
ARG LEVEL_ZERO_VERSION=1.34.0
ARG LEVEL_ZERO_SHA256=45210e4549cd965ad7b9f160eefe53cbcdba01af341bea7ac7ba0aedeeb613ba

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /tmp/neo
RUN [ "$(dpkg --print-architecture)" = amd64 ] || { echo "Intel GPU drivers are x86_64 only" >&2; exit 1; } \
    && python -c "import torch; assert torch.xpu._is_compiled(), 'TORCH_INDEX_URL must be the xpu index'" \
    && neo="https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}" \
    && igc="https://github.com/intel/intel-graphics-compiler/releases/download/v${IGC_VERSION%+*}" \
    && curl -fsSL --remote-name-all \
        "$neo/libze-intel-gpu1_${NEO_VERSION}-0_amd64.deb" \
        "$neo/intel-opencl-icd_${NEO_VERSION}-0_amd64.deb" \
        "$neo/libigdgmm12_${GMMLIB_VERSION}_amd64.deb" \
        "$igc/intel-igc-core-2_${IGC_VERSION}_amd64.deb" \
        "$igc/intel-igc-opencl-2_${IGC_VERSION}_amd64.deb" \
        "https://github.com/oneapi-src/level-zero/releases/download/v${LEVEL_ZERO_VERSION}/libze1_${LEVEL_ZERO_VERSION}+u24.04_amd64.deb" \
    && curl -fsSL "$neo/ww$(cut -d. -f2 <<<"$NEO_VERSION").sum" | sha256sum -c --ignore-missing \
    && printf '%s  %s\n' \
        "$IGC_CORE_SHA256" "intel-igc-core-2_${IGC_VERSION}_amd64.deb" \
        "$IGC_OPENCL_SHA256" "intel-igc-opencl-2_${IGC_VERSION}_amd64.deb" \
        "$LEVEL_ZERO_SHA256" "libze1_${LEVEL_ZERO_VERSION}+u24.04_amd64.deb" | sha256sum -c \
    && apt-get update \
    && apt-get install -y --no-install-recommends ./*.deb ocl-icd-libopencl1 \
    && rm -rf /var/lib/apt/lists/* /tmp/neo
WORKDIR /opt/ComfyUI
# Keep the SYCL and compute-runtime kernel caches on the data volume so JIT-compiled kernels survive restarts.
ENV SYCL_CACHE_PERSISTENT=1 \
    SYCL_CACHE_DIR=/data/cache/sycl \
    NEO_CACHE_PERSISTENT=1 \
    NEO_CACHE_DIR=/data/cache/neo

FROM runtime AS runtime-plain

FROM runtime-${FLAVOR} AS final
