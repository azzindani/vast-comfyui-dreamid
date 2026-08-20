#!/usr/bin/env bash
#
# One-command provisioning for DreamID-V on a vast.ai ComfyUI instance.
#
#   ./setup.sh              run every phase
#   ./setup.sh verify       preflight checks only
#   ./setup.sh env          apt packages, HF_HOME, directories
#   ./setup.sh node         clone + install the DreamID-V wrapper
#   ./setup.sh models       download the three model files
#   ./setup.sh facerestore  CodeFormer / GFPGAN for cleaning source photos
#   ./setup.sh restart      restart ComfyUI and check the log
#
# Safe to re-run. Downloads and clones are skipped if already present.
#
# Everything runs on hardware you rent. No image or video leaves the box.

set -euo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
WORKSPACE="${WORKSPACE:-/workspace}"
NODE_REPO="${NODE_REPO:-https://github.com/TTPlanetPig/Comfyui_DreamID-V_wrapper}"
NODE_NAME="Comfyui_DreamID-V_wrapper"
COMFY_LOG="${COMFY_LOG:-/var/log/portal/comfyui.log}"
MIN_DISK_GB="${MIN_DISK_GB:-60}"

FACERESTORE_REPO="${FACERESTORE_REPO:-https://github.com/mav-rik/facerestore_cf}"
FACERESTORE_NAME="facerestore_cf"

# Minimum expected file sizes, used to detect a truncated download.
SZ_DREAMIDV=6000000000     # ~6.4 GB
SZ_UMT5=10000000000        # ~11 GB
SZ_VAE=400000000           # ~485 MB

# ----------------------------------------------------------------------------
# output helpers
# ----------------------------------------------------------------------------

if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

phase() { printf '\n%s=== %s ===%s\n' "$B" "$1" "$N"; }
ok()    { printf '%s  ok%s   %s\n' "$G" "$N" "$1"; }
warn()  { printf '%s  warn%s %s\n' "$Y" "$N" "$1"; }
die()   { printf '%s  FAIL%s %s\n' "$R" "$N" "$1" >&2; exit 1; }
step()  { printf '  ->   %s\n' "$1"; }

torch_version() {
  python -c "import torch; print(torch.__version__, torch.version.cuda)" 2>/dev/null || echo "MISSING"
}

# ----------------------------------------------------------------------------
# verify — run before anything expensive
# ----------------------------------------------------------------------------

do_verify() {
  phase "Preflight"

  [ -d "$COMFY_DIR" ] || die "ComfyUI not found at $COMFY_DIR. Set COMFY_DIR if it lives elsewhere."
  ok "ComfyUI found at $COMFY_DIR"

  # DreamID-V requires torch >= 2.4
  if ! python -c "
import torch, sys
v = tuple(int(x) for x in torch.__version__.split('+')[0].split('.')[:2])
sys.exit(0 if v >= (2, 4) else 1)
" 2>/dev/null; then
    die "torch is $(torch_version) — DreamID-V needs >= 2.4. Destroy this instance and pick a newer template."
  fi
  ok "torch $(torch_version)"

  command -v nvidia-smi >/dev/null || die "nvidia-smi missing — no GPU visible."
  local gpu
  gpu=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)
  ok "GPU: $gpu"

  local avail
  avail=$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt "$MIN_DISK_GB" ]; then
    die "only ${avail}GB free on $WORKSPACE, need >= ${MIN_DISK_GB}GB. Disk is NOT resizable — re-rent with more."
  fi
  ok "disk: ${avail}GB free"

  # Not fatal, but tells us which restart path to use later.
  if command -v supervisorctl >/dev/null; then
    ok "supervisor present (ComfyUI is service-managed)"
  else
    warn "no supervisor — you will need to start ComfyUI manually"
  fi
}

# ----------------------------------------------------------------------------
# env — packages, HF cache location, directories
# ----------------------------------------------------------------------------

do_env() {
  phase "Environment"

  step "installing tmux + ffmpeg + curl"
  apt-get update -qq && apt-get install -y -qq tmux ffmpeg curl >/dev/null
  ok "tmux + ffmpeg + curl"

  # Without this, models land in ~/.cache/huggingface AND get copied into
  # ComfyUI/models — paying for ~18GB twice.
  export HF_HOME="$WORKSPACE/hf_cache"
  if ! grep -q "HF_HOME=$WORKSPACE/hf_cache" ~/.bashrc 2>/dev/null; then
    echo "export HF_HOME=$WORKSPACE/hf_cache" >> ~/.bashrc
  fi
  ok "HF_HOME=$HF_HOME"

  mkdir -p "$WORKSPACE"/{input,output,tmp} \
           "$COMFY_DIR"/models/{diffusion_models,vae,text_encoders} \
           "$COMFY_DIR"/models/{facerestore_models,facedetection} \
           "$COMFY_DIR"/input
  ok "directories"

  step "installing huggingface_hub CLI"
  pip install -q -U "huggingface_hub[cli]"
  ok "hf CLI"
}

# ----------------------------------------------------------------------------
# node — clone the wrapper and install its (incomplete) requirements
# ----------------------------------------------------------------------------

do_node() {
  phase "DreamID-V node"

  local dest="$COMFY_DIR/custom_nodes/$NODE_NAME"
  local before after
  before=$(torch_version)

  if [ -d "$dest/.git" ]; then
    ok "already cloned"
  else
    step "cloning $NODE_REPO"
    git clone --depth 1 "$NODE_REPO" "$dest"
    ok "cloned"
  fi

  step "installing requirements.txt"
  pip install -q -r "$dest/requirements.txt"

  # requirements.txt is incomplete. These are the modules that actually
  # failed to import on a clean install, plus close relatives that commonly
  # follow in this repo family.
  step "installing the deps requirements.txt forgets"
  pip install -q \
    easydict \
    diffusers transformers accelerate \
    sentencepiece ftfy \
    omegaconf einops imageio-ffmpeg av
  ok "dependencies"

  after=$(torch_version)
  if [ "$before" != "$after" ]; then
    die "torch changed during install: '$before' -> '$after'. A dependency downgraded it. Reinstall the correct wheel before continuing."
  fi
  ok "torch unchanged ($after)"
}

# ----------------------------------------------------------------------------
# models — ~18GB across three files
# ----------------------------------------------------------------------------

# have_file <path> <min_bytes>
have_file() {
  [ -f "$1" ] && [ "$(stat -c%s "$1" 2>/dev/null || echo 0)" -ge "$2" ]
}

do_models() {
  phase "Models (~18GB)"

  export HF_HOME="$WORKSPACE/hf_cache"
  cd "$COMFY_DIR"

  local dreamidv="models/diffusion_models/dreamidv.pth"
  local vae="models/vae/Wan2.1_VAE.pth"
  local umt5="models/text_encoders/umt5-xxl-enc-bf16.pth"

  if have_file "$dreamidv" "$SZ_DREAMIDV"; then
    ok "dreamidv.pth present"
  else
    step "downloading dreamidv.pth (~6.4GB)"
    hf download XuGuo699/DreamID-V dreamidv.pth --local-dir models/diffusion_models
    ok "dreamidv.pth"
  fi

  if have_file "$vae" "$SZ_VAE"; then
    ok "Wan2.1_VAE.pth present"
  else
    step "downloading Wan2.1_VAE.pth (~485MB)"
    hf download Wan-AI/Wan2.1-T2V-1.3B Wan2.1_VAE.pth --local-dir models/vae
    ok "Wan2.1_VAE.pth"
  fi

  if have_file "$umt5" "$SZ_UMT5"; then
    ok "umt5-xxl-enc-bf16.pth present"
  else
    step "downloading umt5 encoder (~11GB, slowest step)"
    hf download Wan-AI/Wan2.1-T2V-1.3B models_t5_umt5-xxl-enc-bf16.pth \
      --local-dir models/text_encoders
    # The repo filename and the name the wrapper expects differ.
    mv models/text_encoders/models_t5_umt5-xxl-enc-bf16.pth "$umt5"
    ok "umt5-xxl-enc-bf16.pth (renamed)"
  fi

  # --local-dir normally downloads in place, but check for a duplicate copy.
  if [ -d "$HF_HOME" ]; then
    local cache_kb
    cache_kb=$(du -sk "$HF_HOME" 2>/dev/null | cut -f1)
    if [ "${cache_kb:-0}" -gt 1000000 ]; then
      warn "hf_cache is $((cache_kb / 1024))MB — likely duplicate copies. rm -rf $HF_HOME to reclaim."
    fi
  fi

  printf '\n'
  ls -lh models/diffusion_models/dreamidv.pth models/vae/Wan2.1_VAE.pth "$umt5"
  df -h "$WORKSPACE" | tail -1
}

# ----------------------------------------------------------------------------
# facerestore — CodeFormer / GFPGAN, for cleaning up low-res source photos
#
# DreamID-V builds identity from the source image, so a soft photo gives a soft
# identity. Doing this on-box rather than via a web tool keeps faces private.
# ----------------------------------------------------------------------------

# fetch <url> <dest> <min_bytes> <label>
fetch() {
  local url="$1" dest="$2" min="$3" label="$4"
  if have_file "$dest" "$min"; then
    ok "$label present"
    return 0
  fi
  step "downloading $label"
  mkdir -p "$(dirname "$dest")"
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 -o "$dest" "$url" || { warn "could not fetch $label"; return 1; }
  else
    wget -q --tries=3 -O "$dest" "$url" || { warn "could not fetch $label"; return 1; }
  fi
  ok "$label"
}

do_facerestore() {
  phase "Face restoration (CodeFormer / GFPGAN)"

  local dest="$COMFY_DIR/custom_nodes/$FACERESTORE_NAME"

  if [ -d "$dest/.git" ]; then
    ok "node already cloned"
  else
    step "cloning $FACERESTORE_REPO"
    if git clone --depth 1 "$FACERESTORE_REPO" "$dest" 2>/dev/null; then
      ok "cloned"
    else
      warn "clone failed — install 'facerestore' from the ComfyUI Manager UI instead."
      warn "the models below still download, so Manager's node will find them."
    fi
  fi

  if [ -f "$dest/requirements.txt" ]; then
    step "installing requirements"
    pip install -q -r "$dest/requirements.txt" || warn "requirements install reported problems"
  fi

  # Restoration weights. Direct GitHub release URLs — versioned and stable.
  # ~700MB total, negligible next to the 18GB of DreamID-V models.
  fetch "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth" \
        "$COMFY_DIR/models/facerestore_models/codeformer.pth" \
        300000000 "codeformer.pth" || true

  fetch "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth" \
        "$COMFY_DIR/models/facerestore_models/GFPGANv1.4.pth" \
        300000000 "GFPGANv1.4.pth" || true

  # Detection + parsing, required by both restorers.
  fetch "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth" \
        "$COMFY_DIR/models/facedetection/detection_Resnet50_Final.pth" \
        100000000 "detection_Resnet50_Final.pth" || true

  fetch "https://github.com/xinntao/facexlib/releases/download/v0.2.2/parsing_parsenet.pth" \
        "$COMFY_DIR/models/facedetection/parsing_parsenet.pth" \
        50000000 "parsing_parsenet.pth" || true

  printf '\n'
  ls -lh "$COMFY_DIR"/models/facerestore_models/ "$COMFY_DIR"/models/facedetection/ 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# restart — ComfyUI is supervisor-managed; never run main.py by hand
# ----------------------------------------------------------------------------

do_restart() {
  phase "Restart ComfyUI"

  if command -v supervisorctl >/dev/null && supervisorctl status comfyui >/dev/null 2>&1; then
    step "supervisorctl restart comfyui"
    supervisorctl restart comfyui
  else
    warn "not supervisor-managed — start it yourself:"
    warn "  cd $COMFY_DIR && python main.py --listen 0.0.0.0 --port 8188"
    return 0
  fi

  step "waiting for startup"
  sleep 20

  if [ ! -f "$COMFY_LOG" ]; then
    warn "log not found at $COMFY_LOG — check startup manually"
    return 0
  fi

  if grep -q "IMPORT FAILED.*$NODE_NAME" "$COMFY_LOG"; then
    printf '\n'
    grep -iA2 "ModuleNotFoundError" "$COMFY_LOG" | tail -10
    printf '\n'
    die "node failed to import. Install the missing module above, then: ./setup.sh restart"
  fi

  if grep -q "DreamID-V Wrapper.*Loaded" "$COMFY_LOG"; then
    grep "DreamID-V Wrapper.*Loaded" "$COMFY_LOG" | tail -1
    ok "node loaded"
  else
    warn "no load confirmation in log — inspect: tail -50 $COMFY_LOG"
  fi
}

# ----------------------------------------------------------------------------

do_all() {
  do_verify
  do_env
  do_node
  do_models
  do_facerestore
  do_restart

  phase "Done"
  cat <<EOF
  Tunnel from your machine (note 18188, not 8188):

    ssh -p PORT root@HOST -L 8188:localhost:18188 -t "tmux attach -t work || tmux new -s work"

  Then open http://localhost:8188

  Order of work on this box:

    1. Restore your source photos   FaceRestoreCFWithModel, codeformer,
                                    fidelity 0.5 and 0.7 -- keep whichever
                                    still looks like the person
    2. Swap a 2-second test clip    confirm resolution, VRAM, output format
    3. Swap the real clips
    4. Download results, then DESTROY the instance

  Put source images and clips in $COMFY_DIR/input/

  Nothing leaves this machine.
EOF
}

case "${1:-all}" in
  all)          do_all ;;
  verify)       do_verify ;;
  env)          do_env ;;
  node)         do_node ;;
  models)       do_models ;;
  facerestore)  do_facerestore ;;
  restart)      do_restart ;;
  *)            die "unknown phase '$1' (use: all|verify|env|node|models|facerestore|restart)" ;;
esac
