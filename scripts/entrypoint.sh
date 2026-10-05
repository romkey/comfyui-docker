#!/usr/bin/env bash
# Translates environment variables into ComfyUI arguments and starts it.
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
DATA_DIR="${DATA_DIR:-/data}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

is_true() {
    case "${1:-}" in
        1 | true | TRUE | True | yes | YES | on | ON) return 0 ;;
        *) return 1 ;;
    esac
}

# Re-exec as the unprivileged user after fixing ownership of the data volume.
if [ "$(id -u)" = "0" ]; then
    groupmod -o -g "$PGID" comfy
    usermod -o -u "$PUID" comfy
    mkdir -p "$DATA_DIR"
    chown comfy:comfy "$DATA_DIR"
    if is_true "${COMFYUI_CHOWN_DATA:-false}"; then
        chown -R comfy:comfy "$DATA_DIR"
    fi
    export HOME=/home/comfy
    exec gosu comfy "$0" "$@"
fi

mkdir -p "$DATA_DIR"/{models,input,output,temp,user,custom_nodes}
for d in checkpoints clip clip_vision configs controlnet diffusers diffusion_models embeddings \
    gligen hypernetworks loras text_encoders unet upscale_models vae vae_approx; do
    mkdir -p "$DATA_DIR/models/$d"
done

# Optionally install requirements of custom nodes (e.g. ones added via Manager or git clone).
if is_true "${COMFYUI_INSTALL_NODE_REQUIREMENTS:-false}"; then
    for req in "$DATA_DIR"/custom_nodes/*/requirements.txt; do
        [ -f "$req" ] || continue
        echo "[entrypoint] pip install -r $req"
        pip install -r "$req" || echo "[entrypoint] WARNING: failed to install $req"
    done
fi

args=(
    --listen "${COMFYUI_LISTEN:-0.0.0.0}"
    --port "${COMFYUI_PORT:-8188}"
    --base-directory "$DATA_DIR"
    --disable-auto-launch
)

# Device selection: auto-detect CUDA unless COMFYUI_CPU is set explicitly.
cpu="${COMFYUI_CPU:-auto}"
if [ "$cpu" = "auto" ]; then
    if python -c 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)' 2>/dev/null; then
        cpu=false
    else
        echo "[entrypoint] No CUDA device available; running on CPU (set COMFYUI_CPU=false to disable this fallback)"
        cpu=true
    fi
fi
is_true "$cpu" && args+=(--cpu)

# Memory mode: gpu-only | highvram | normalvram | lowvram | novram
case "${COMFYUI_VRAM_MODE:-}" in
    "" | normalvram) ;;
    gpu-only | highvram | lowvram | novram) args+=("--${COMFYUI_VRAM_MODE}") ;;
    *) echo "[entrypoint] Unknown COMFYUI_VRAM_MODE='${COMFYUI_VRAM_MODE}'" >&2; exit 2 ;;
esac

[ -n "${COMFYUI_CUDA_DEVICE:-}" ] && args+=(--cuda-device "$COMFYUI_CUDA_DEVICE")
[ -n "${COMFYUI_PREVIEW_METHOD:-}" ] && args+=(--preview-method "$COMFYUI_PREVIEW_METHOD")
[ -n "${COMFYUI_RESERVE_VRAM:-}" ] && args+=(--reserve-vram "$COMFYUI_RESERVE_VRAM")
[ -n "${COMFYUI_ATTENTION:-}" ] && args+=("--use-${COMFYUI_ATTENTION}-attention")
[ -n "${COMFYUI_CACHE_LRU:-}" ] && args+=(--cache-lru "$COMFYUI_CACHE_LRU")
[ -n "${COMFYUI_MAX_UPLOAD_SIZE:-}" ] && args+=(--max-upload-size "$COMFYUI_MAX_UPLOAD_SIZE")
[ -n "${COMFYUI_CORS_ORIGIN:-}" ] && args+=(--enable-cors-header "$COMFYUI_CORS_ORIGIN")
[ -n "${COMFYUI_TLS_KEYFILE:-}" ] && args+=(--tls-keyfile "$COMFYUI_TLS_KEYFILE")
[ -n "${COMFYUI_TLS_CERTFILE:-}" ] && args+=(--tls-certfile "$COMFYUI_TLS_CERTFILE")
[ -n "${COMFYUI_EXTRA_MODEL_PATHS_CONFIG:-}" ] && args+=(--extra-model-paths-config "$COMFYUI_EXTRA_MODEL_PATHS_CONFIG")
[ -n "${COMFYUI_FAST:-}" ] && args+=(--fast "$COMFYUI_FAST")

is_true "${COMFYUI_ENABLE_MANAGER:-true}" && args+=(--enable-manager)
is_true "${COMFYUI_FORCE_FP16:-false}" && args+=(--force-fp16)
is_true "${COMFYUI_FORCE_FP32:-false}" && args+=(--force-fp32)
is_true "${COMFYUI_DISABLE_SMART_MEMORY:-false}" && args+=(--disable-smart-memory)
is_true "${COMFYUI_DISABLE_CUDA_MALLOC:-false}" && args+=(--disable-cuda-malloc)
is_true "${COMFYUI_DETERMINISTIC:-false}" && args+=(--deterministic)
is_true "${COMFYUI_HIGH_RAM:-false}" && args+=(--high-ram)
is_true "${COMFYUI_VERBOSE_DEBUG:-false}" && args+=(--verbose DEBUG)

# Anything else: free-form extra arguments (word-split on purpose).
if [ -n "${COMFYUI_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    args+=(${COMFYUI_ARGS})
fi

# With no command given, start ComfyUI; otherwise run the given command (e.g. bash).
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

cd "$COMFYUI_DIR"
echo "[entrypoint] python main.py ${args[*]}"
exec python main.py "${args[@]}"
