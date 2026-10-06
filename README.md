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

The `-sage` image adds [SageAttention](https://github.com/thu-ml/SageAttention), compiled for compute
capabilities 10.0, 12.0 and 12.1. With the default `COMFYUI_ATTENTION=auto` it turns on `--use-sage-attention`
only when it detects one of those GPUs, and otherwise falls back to ComfyUI's default attention. Upstream
SageAttention doesn't support Jetson Thor (sm_110), so use the default image there. Set
`COMFYUI_ATTENTION=pytorch` to turn Sage off.

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
| `COMFYUI_CPU`                    | `auto`    | `auto` falls back to CPU when no CUDA device is found |
| `COMFYUI_VRAM_MODE`              | –         | `gpu-only`, `highvram`, `lowvram`, `novram`           |
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

CI lints the Dockerfile (hadolint), shell scripts (ShellCheck), YAML (yamllint), workflows (actionlint) and
compose files, then builds the CPU variant and boots ComfyUI as a smoke test. To force a rebuild of a
version, run the **Build and publish** workflow manually.

## License

[MIT](LICENSE). ComfyUI itself is GPL-3.0 licensed.
