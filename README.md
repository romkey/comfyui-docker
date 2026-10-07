# comfyui-docker

[![CI](https://github.com/romkey/comfyui-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/romkey/comfyui-docker/actions/workflows/ci.yml)
[![Build and publish](https://github.com/romkey/comfyui-docker/actions/workflows/release.yml/badge.svg)](https://github.com/romkey/comfyui-docker/actions/workflows/release.yml)
[![Version](https://img.shields.io/github/v/release/romkey/comfyui-docker?label=comfyui&color=blue)](https://github.com/romkey/comfyui-docker/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Multi-arch (`linux/amd64`, `linux/arm64`) Docker images for [ComfyUI](https://github.com/Comfy-Org/ComfyUI).
A GitHub Actions job checks every few hours for a new ComfyUI release and publishes an image tagged with the same
version (without the leading `v`) to `ghcr.io/romkey/comfyui-docker`. `latest` always tracks the newest release.

## AI disclosure

This project was built with the help of AI (Claude, by Anthropic). The Dockerfile, entrypoint script,
workflows and documentation were AI-generated and reviewed by the maintainer. ComfyUI itself is a separate
upstream project and is not affiliated with this repository.

## Image variants

| Tag                          | PyTorch  | Use on                                                           |
| ---------------------------- | -------- | ---------------------------------------------------------------- |
| `latest`, `0.38.0`           | CUDA 13  | Linux + NVIDIA (driver ≥ 580), DGX Spark (GB10), Jetson Thor     |
| `latest-cu128`, `0.38.0-cu128` | CUDA 12.8 | Linux + NVIDIA with older drivers (≥ 570)                     |
| `latest-cpu`, `0.38.0-cpu`   | CPU      | macOS (Docker Desktop), any machine without a GPU                |
| `latest-sage`, `0.38.0-sage` | CUDA 13 + SageAttention | Blackwell GPUs: DGX Spark (GB10), RTX 50, B200 |
| `latest-rocm-gfx1151`, `0.38.0-rocm-gfx1151` | ROCm 7.13 | AMD Strix Halo (Ryzen AI Max); x86_64 only |
| `latest-xpu`, `0.38.0-xpu`   | XPU (oneAPI) | Intel Arc: B580, Arc Pro B70, other Battlemage and Alchemist cards; x86_64 only |

The `-sage` image adds [SageAttention](https://github.com/thu-ml/SageAttention), compiled for compute
capabilities 10.0, 12.0 and 12.1. With the default `COMFYUI_ATTENTION=auto` it turns on `--use-sage-attention`
only when it detects one of those GPUs, and otherwise falls back to ComfyUI's default attention. Upstream
SageAttention doesn't support Jetson Thor (sm_110), so use the default image there. Set
`COMFYUI_ATTENTION=pytorch` to turn Sage off.

### DGX Spark and Jetson Thor

Both share 128 GB between CPU and GPU, so ComfyUI's default habit of offloading models to "CPU RAM" is just a
copy within the same memory, and it will happily treat nearly all of it as VRAM. Suggested `.env` settings:

```bash
# DGX Spark (GB10)
COMFYUI_TAG=latest-sage        # SageAttention turns on automatically for sm_121
COMFYUI_VRAM_MODE=highvram     # keep models on the GPU; gpu-only also works with 128 GB
COMFYUI_RESERVE_VRAM=12        # GB left for the OS and anything else running (more if you run an LLM too)

# Jetson Thor
COMFYUI_TAG=latest             # not -sage: SageAttention doesn't support sm_110
COMFYUI_VRAM_MODE=highvram
COMFYUI_RESERVE_VRAM=16
```

Both are Blackwell, so `COMFYUI_FAST=fp8_matrix_mult` can speed up FP8 models; `fp16_accumulation` is faster
still at a small cost in precision. Benchmark your own workflows before keeping either. xformers isn't
installed, so `--disable-xformers` is unnecessary.

On Thor, the host power mode matters more than any ComfyUI setting. It ships in a reduced mode; on the host run
`sudo nvpmodel -m 0` and `sudo jetson_clocks` for full performance.

### AMD Strix Halo

Strix Halo (Ryzen AI Max, gfx1151) uses ROCm, so it needs its own image: `-rocm-gfx1151` (x86_64 only). It
installs PyTorch from [AMD's gfx1151 wheel index](https://repo.amd.com/rocm/whl/gfx1151/), which bundles the ROCm
libraries, so the host only needs the amdgpu kernel driver.

```bash
docker compose -f docker-compose.rocm.yml up -d
```

The compose file passes `/dev/kfd` and `/dev/dri` through and sets `seccomp:unconfined` and `ipc: host`, which
ROCm needs. The entrypoint adds the container user to whichever groups own those device nodes, so no
`group_add` is required. The image defaults to settings the Strix Halo community reports as necessary for
unified-memory APUs: `HSA_ENABLE_SDMA=0`, `HSA_USE_SVM=0`, `--disable-mmap` and `--bf16-vae`. Override any of them
in `.env` (see [`.env.example`](.env.example)); `COMFYUI_CACHE_NONE=true` also helps when memory is tight.

Host setup matters more than the container: in the BIOS give the iGPU only a small dedicated allocation and let
it use system memory (GTT), and raise the kernel's GTT limit (`amdgpu.gttsize`, `ttm.pages_limit`) to use most of
your RAM. See the [Strix Halo setup guide](https://strix-halo-toolboxes.com/) for current values.

Other AMD GPUs have their own wheel index (`gfx1150`, `gfx110X-all`, `gfx120X-all`, ...). To build for one:

```bash
docker build -t comfyui-rocm --build-arg FLAVOR=rocm \
  --build-arg TORCH_INDEX_URL=https://repo.amd.com/rocm/whl/gfx120X-all/ .
```

### Intel Arc

Intel Arc GPUs use PyTorch's native XPU backend, so they get their own image: `-xpu` (x86_64 only). It installs
PyTorch from the [xpu wheel index](https://download.pytorch.org/whl/xpu) and bundles Intel's user-space GPU
driver ([compute runtime](https://github.com/intel/compute-runtime): Level Zero and OpenCL), so the host only
needs the kernel driver. It is aimed at the Battlemage cards (Arc B580, 12 GB; Arc Pro B70, 32 GB) and also
works with Alchemist (A-series). Because Intel's current driver packages need a newer glibc than Debian 12, this
image is built on Debian 13 (trixie); the other images are unchanged.

```bash
docker compose -f docker-compose.xpu.yml up -d
```

#### Host setup

1. **Kernel.** Battlemage uses the `xe` kernel driver. The B580 needs Linux 6.12 or newer (Ubuntu 24.04 with the
   HWE kernel, or 25.04+). The Arc Pro B70 needs Linux 6.17 or newer (Ubuntu 25.10 or 26.04). See Intel's
   [supported GPU table](https://dgpu-docs.intel.com/overview/supported-hardware/xe-driver-gpus.html) for other
   cards. Check that the driver is bound:

   ```bash
   lspci -nnk -d 8086: | grep -A3 -E 'VGA|Display'
   ```

   You should see `Kernel driver in use: xe`. If the card shows no driver, the kernel is too old for it.
2. **Firmware.** Install a current `linux-firmware` package (it provides the GuC/HuC firmware under
   `/lib/firmware/xe/`). `sudo dmesg | grep -i xe` should show the GuC firmware loading without errors.
3. **BIOS.** Enable **Resizable BAR** (also called "Smart Access Memory" or "Re-Size BAR Support") and
   **Above 4G Decoding**. Arc cards run much slower without it. Check the BAR size:

   ```bash
   sudo lspci -vv -d 8086: | grep -A3 'Resizable BAR'
   ```

   The current size should cover the card's memory (16 GB on a B580, 32 GB on a B70), not 256 MB.
4. **Nothing else.** You don't need oneAPI or the compute runtime on the host. `/dev/dri/renderD*` must exist; the
   compose file passes `/dev/dri` through and the entrypoint adds the container user to the group that owns
   the render nodes (usually `render`), so no `group_add` is needed.

Check that PyTorch sees the GPU(s):

```bash
docker exec comfyui python -c "import torch; print([torch.xpu.get_device_name(i) for i in range(torch.xpu.device_count())])"
```

#### Multiple GPUs in one host

With both cards in one machine, ComfyUI sees both but uses only the first one. To choose a card, set
`COMFYUI_ONEAPI_DEVICE_SELECTOR` to `level_zero:<index>`, where `<index>` is the card's position in the list
the command above prints. To use both cards at once, run one instance per card, each with its own env file,
project name, container name and port:

```bash
# b70.env
COMFYUI_CONTAINER_NAME=comfyui-b70
COMFYUI_HOST_PORT=8188
COMFYUI_DATA=./data
COMFYUI_ONEAPI_DEVICE_SELECTOR=level_zero:0

# b580.env
COMFYUI_CONTAINER_NAME=comfyui-b580
COMFYUI_HOST_PORT=8189
COMFYUI_DATA=./data-b580
COMFYUI_ONEAPI_DEVICE_SELECTOR=level_zero:1
```

```bash
docker compose -p comfyui-b70 --env-file b70.env -f docker-compose.xpu.yml up -d
```

```bash
docker compose -p comfyui-b580 --env-file b580.env -f docker-compose.xpu.yml up -d
```

Shared settings still come from `.env`. Pointing both at the same `COMFYUI_DATA` shares models, outputs and
settings. To share only the models, give each its own data directory and use `COMFYUI_EXTRA_MODEL_PATHS_CONFIG`.

#### Tuning

- **Arc B580 (12 GB):** SDXL and SD 1.5 run as-is. For Flux, Qwen-Image, Wan and other large models, use fp8
  or GGUF quantized weights, and set `COMFYUI_VRAM_MODE=lowvram` if you still run out of memory.
- **Arc Pro B70 (32 GB):** most image models fit in fp8 or bf16 with the default memory mode.
- **The first generation is slow.** Kernels are compiled the first time each one is used. The image keeps
  those caches on the data volume (`/data/cache/sycl`, `/data/cache/neo`), so later runs and restarts are fast.
- **Black or noisy images:** a [PyTorch bug](https://github.com/pytorch/pytorch/issues/199179) reported on the
  Arc Pro B70 gives NaNs from some fp16/bf16 convolutions and matmuls. If you hit it, try
  `COMFYUI_ARGS=--fp32-vae` first, then `COMFYUI_FORCE_FP32=true` (slower, uses more memory).
- The `-sage` image and SageAttention are NVIDIA-only. Leave `COMFYUI_ATTENTION` unset on Intel.

### macOS

Docker on macOS cannot pass the GPU through to containers, so the Mac image runs on CPU. For GPU speed on
Apple Silicon, run ComfyUI natively (MPS) instead, for example with the official desktop app:

```bash
brew install --cask comfy
```

For a lightweight, headless setup without the desktop app, use Comfy-Org's official
[comfy-cli](https://github.com/Comfy-Org/comfy-cli) (not in Homebrew core; install with pipx):

```bash
brew install pipx
pipx install comfy-cli
comfy install     # sets up ComfyUI in ~/comfy with the Apple Silicon (MPS) PyTorch build
comfy launch      # starts the server on http://127.0.0.1:8188
```

Use the `-cpu` image on a Mac only when you need a CPU-only or reproducible containerized setup.

## Quick start

NVIDIA GPU (needs the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)):

```bash
cp .env.example .env
docker compose up -d
```

Intel Arc (see [Intel Arc](#intel-arc) for host setup):

```bash
docker compose -f docker-compose.xpu.yml up -d
```

macOS / CPU:

```bash
docker compose -f docker-compose.cpu.yml up -d
```

Open <http://localhost:8188>. Everything persistent (models, custom nodes, inputs, outputs, user settings)
lives in `./data` (mounted at `/data`).

## Configuration

Everything is configured by environment variables; see [`.env.example`](.env.example) for the full list.
Common ones:

| Variable                         | Default   | Purpose                                               |
| -------------------------------- | --------- | ----------------------------------------------------- |
| `PUID` / `PGID`                  | 1000      | User/group the process runs as (owner of `/data`)     |
| `COMFYUI_PORT`                   | 8188      | Port inside the container                             |
| `COMFYUI_CPU`                    | `auto`    | `auto` falls back to CPU when no GPU is found         |
| `COMFYUI_VRAM_MODE`              | –         | `gpu-only`, `highvram`, `lowvram`, `novram`           |
| `COMFYUI_RESERVE_VRAM`           | –         | GB of VRAM to leave free                              |
| `COMFYUI_FAST`                   | –         | `all`, or a list such as `fp8_matrix_mult,fp16_accumulation` |
| `COMFYUI_ENABLE_MANAGER`         | `true`    | Enable ComfyUI-Manager                                |
| `COMFYUI_INSTALL_NODE_REQUIREMENTS` | `false` | Install custom nodes' `requirements.txt` on start     |
| `COMFYUI_ARGS`                   | –         | Any extra raw ComfyUI arguments                       |

## What's bundled

- **ComfyUI-Manager**, installed with the ComfyUI release it belongs to.
- **[ComfyUI-VideoHelperSuite](https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite)**, needed by most video workflows (ffmpeg is in the image).
- **[Comfier agent](https://github.com/romkey/comfier-ui/tree/main/comfyui/comfier_agent)**, which stays idle until
  `COMFIER_URL` and `COMFIER_API_KEY` are set.
- CLI tools: `hf` (Hugging Face), `comfy` ([comfy-cli](https://github.com/Comfy-Org/comfy-cli), pre-pointed at the
  bundled ComfyUI), and `aria2c`. Set `HF_TOKEN` / `HF_ENDPOINT` for the Hugging Face tools.
  Example: `docker exec -it comfyui hf download <repo> <file> --local-dir /data/models/checkpoints`

Bundled nodes are symlinked into `/data/custom_nodes` at every start, so image updates reach existing volumes.
A real folder of the same name in `custom_nodes` always wins. Use `COMFYUI_BUNDLED_NODES` (`all`, `none`, or a
comma-separated list) to choose which are linked, and `COMFYUI_PRELOAD_NODES` to clone extra nodes (git URLs,
optionally `URL@ref`) on first start.

The image is rebuilt automatically when ComfyUI releases a new version, or when the Comfier agent,
VideoHelperSuite or SageAttention changes (checked every 6 hours).

## Development

Build locally (pick a variant with `TORCH_INDEX_URL`, a ComfyUI version with `COMFYUI_REF`):

```bash
docker build -t comfyui \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu \
  --build-arg COMFYUI_REF=v0.38.0 .
```

The Intel image also needs its flavor and the trixie base (on an Apple Silicon Mac, add `--platform linux/amd64`):

```bash
docker build -t comfyui-xpu --build-arg FLAVOR=xpu \
  --build-arg BASE_IMAGE=python:3.12-slim-trixie \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/xpu .
```

The Intel driver versions are pinned in the Dockerfile (`NEO_VERSION`, `IGC_VERSION`, `LEVEL_ZERO_VERSION` and
their checksums). Bump them together from the
[compute runtime releases](https://github.com/intel/compute-runtime/releases).

CI lints the Dockerfile (hadolint), shell scripts (ShellCheck), YAML (yamllint), workflows (actionlint) and
compose files, then builds the CPU variant and boots ComfyUI as a smoke test. To force a rebuild of a
version, run the **Build and publish** workflow manually.

## License

[MIT](LICENSE). ComfyUI itself is GPL-3.0 licensed.
