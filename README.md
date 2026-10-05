# comfyui-docker

[![CI](https://github.com/romkey/comfyui-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/romkey/comfyui-docker/actions/workflows/ci.yml)
[![Build and publish](https://github.com/romkey/comfyui-docker/actions/workflows/release.yml/badge.svg)](https://github.com/romkey/comfyui-docker/actions/workflows/release.yml)
[![Version](https://img.shields.io/github/v/release/romkey/comfyui-docker?label=comfyui&color=blue)](https://github.com/romkey/comfyui-docker/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Multi-arch (`linux/amd64`, `linux/arm64`) Docker images for [ComfyUI](https://github.com/Comfy-Org/ComfyUI).
A GitHub Actions job checks daily for a new ComfyUI release and publishes an image tagged with the same
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

Docker on macOS cannot pass the GPU through to containers, so the Mac image runs on CPU. For GPU speed on
Apple Silicon, run ComfyUI natively (MPS) instead, for example with the official desktop app:

```bash
brew install --cask comfy
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
