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
    # gosu drops the container's supplementary groups, so grant the unprivileged user access to GPU device
    # nodes (AMD /dev/kfd and /dev/dri/*) by adding it to whichever groups own them.
    for dev in /dev/kfd /dev/dri/*; do
        [ -e "$dev" ] || continue
        dev_gid="$(stat -c %g "$dev")"
        [ "$dev_gid" = "0" ] && continue
        dev_group="$(getent group "$dev_gid" | cut -d: -f1 || true)"
        if [ -z "$dev_group" ]; then
            dev_group="gpu$dev_gid"
            groupadd -g "$dev_gid" "$dev_group"
        fi
        usermod -aG "$dev_group" comfy
    done
    export HOME=/home/comfy
    exec gosu comfy "$0" "$@"
fi

mkdir -p "$DATA_DIR"/{models,input,output,temp,user,custom_nodes,cache/huggingface,cache/miopen}
for d in checkpoints clip clip_vision configs controlnet diffusers diffusion_models embeddings \
    gligen hypernetworks loras text_encoders unet upscale_models vae vae_approx; do
    mkdir -p "$DATA_DIR/models/$d"
done

# Bundled nodes: COMFYUI_BUNDLED_NODES = all (default) | none | comma-separated folder names.
# They are symlinked into custom_nodes on every start so image updates reach existing volumes.
# A real (non-symlink) folder of the same name in custom_nodes always wins.
bundled="${COMFYUI_BUNDLED_NODES:-all}"
for link in "$DATA_DIR"/custom_nodes/*; do
    if [ -L "$link" ] && [[ "$(readlink "$link")" == /opt/bundled_nodes/* ]]; then
        rm -f "$link"
    fi
done
if [ "$bundled" != "none" ]; then
    for src in /opt/bundled_nodes/*; do
        [ -d "$src" ] || continue
        name="$(basename "$src")"
        if [ "$bundled" != "all" ] && [[ ",${bundled// /}," != *",$name,"* ]]; then
            continue
        fi
        dest="$DATA_DIR/custom_nodes/$name"
        if [ -e "$dest" ]; then
            echo "[entrypoint] custom_nodes/$name already exists; not linking the bundled copy"
        else
            ln -s "$src" "$dest"
        fi
    done
fi

# Preload extra custom nodes: COMFYUI_PRELOAD_NODES = whitespace/comma/newline-separated git URLs,
# each optionally pinned as URL@ref. Existing folders are left untouched (use Manager or git to update).
if [ -n "${COMFYUI_PRELOAD_NODES:-}" ]; then
    for spec in ${COMFYUI_PRELOAD_NODES//,/ }; do
        url="${spec%@*}"
        ref=""
        # Only treat a trailing @ref as a ref when it is not part of user@host in the URL.
        if [[ "$spec" == *@* && "${spec##*@}" != *[/:]* ]]; then
            ref="${spec##*@}"
        else
            url="$spec"
        fi
        name="$(basename "${url%.git}")"
        dest="$DATA_DIR/custom_nodes/$name"
        if [ -e "$dest" ]; then
            continue
        fi
        echo "[entrypoint] Cloning $url ${ref:+(at $ref) }into custom_nodes/$name"
        if git clone --quiet "$url" "$dest" && { [ -z "$ref" ] || git -C "$dest" checkout --quiet "$ref"; }; then
            if [ -f "$dest/requirements.txt" ]; then
                pip install -r "$dest/requirements.txt" || echo "[entrypoint] WARNING: requirements failed for $name"
            fi
        else
            echo "[entrypoint] WARNING: could not clone $url"
            rm -rf "$dest"
        fi
    done
fi

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
        echo "[entrypoint] No GPU available; running on CPU (set COMFYUI_CPU=false to disable this fallback)"
        if python -c 'import sys, torch; sys.exit(0 if torch.version.hip else 1)' 2>/dev/null; then
            echo "[entrypoint] This is a ROCm build: pass /dev/kfd and /dev/dri into the container (see docker-compose.rocm.yml)"
        fi
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

# Attention backend: pytorch | split | quad | sage | flash | auto (auto = SageAttention if built in and the GPU is supported).
attention="${COMFYUI_ATTENTION:-}"
if [ "$attention" = "auto" ]; then
    attention="$(python - <<'PY' 2>/dev/null || true
import os, torch
try:
    import sageattention  # noqa: F401
    supported = {a.split("+")[0] for a in os.environ.get("SAGE_ARCHS", "").replace(",", ";").split(";") if a}
    major, minor = torch.cuda.get_device_capability()
    print("sage" if f"{major}.{minor}" in supported else "")
except Exception:
    print("")
PY
)"
    [ -n "$attention" ] && echo "[entrypoint] SageAttention supports this GPU; enabling it"
fi
[ -n "$attention" ] && args+=("--use-${attention}-attention")
[ -n "${COMFYUI_CACHE_LRU:-}" ] && args+=(--cache-lru "$COMFYUI_CACHE_LRU")
[ -n "${COMFYUI_MAX_UPLOAD_SIZE:-}" ] && args+=(--max-upload-size "$COMFYUI_MAX_UPLOAD_SIZE")
[ -n "${COMFYUI_CORS_ORIGIN:-}" ] && args+=(--enable-cors-header "$COMFYUI_CORS_ORIGIN")
[ -n "${COMFYUI_TLS_KEYFILE:-}" ] && args+=(--tls-keyfile "$COMFYUI_TLS_KEYFILE")
[ -n "${COMFYUI_TLS_CERTFILE:-}" ] && args+=(--tls-certfile "$COMFYUI_TLS_CERTFILE")
[ -n "${COMFYUI_EXTRA_MODEL_PATHS_CONFIG:-}" ] && args+=(--extra-model-paths-config "$COMFYUI_EXTRA_MODEL_PATHS_CONFIG")
# Performance features: all (bare --fast, enables everything) or a whitespace/comma-separated list.
if [ "${COMFYUI_FAST:-}" = "all" ]; then
    args+=(--fast)
elif [ -n "${COMFYUI_FAST:-}" ]; then
    read -r -a fast_features <<<"${COMFYUI_FAST//,/ }"
    args+=(--fast "${fast_features[@]}")
fi

is_true "${COMFYUI_ENABLE_MANAGER:-true}" && args+=(--enable-manager)
is_true "${COMFYUI_FORCE_FP16:-false}" && args+=(--force-fp16)
is_true "${COMFYUI_FORCE_FP32:-false}" && args+=(--force-fp32)
is_true "${COMFYUI_DISABLE_SMART_MEMORY:-false}" && args+=(--disable-smart-memory)
is_true "${COMFYUI_DISABLE_CUDA_MALLOC:-false}" && args+=(--disable-cuda-malloc)
is_true "${COMFYUI_DETERMINISTIC:-false}" && args+=(--deterministic)
is_true "${COMFYUI_HIGH_RAM:-false}" && args+=(--high-ram)
is_true "${COMFYUI_DISABLE_MMAP:-false}" && args+=(--disable-mmap)
is_true "${COMFYUI_BF16_VAE:-false}" && args+=(--bf16-vae)
is_true "${COMFYUI_CACHE_NONE:-false}" && args+=(--cache-none)
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
