#!/usr/bin/env bash
#
# One-command provisioning for AI video face-swap on a vast.ai ComfyUI instance.
#
#   ./setup.sh              everything below except `wan`
#   ./setup.sh verify       preflight only — aborts before anything expensive
#   ./setup.sh env          apt packages, HF_HOME, directories
#   ./setup.sh nodes        DreamID-V + VideoHelperSuite + face restore + RIFE
#   ./setup.sh models       DreamID-V weights (~18GB)
#   ./setup.sh enhance      face restore, upscalers, interpolation (~1GB)
#   ./setup.sh restart      restart ComfyUI, confirm nodes loaded
#   ./setup.sh paths        show where ComfyUI actually reads/writes files
#   ./setup.sh doctor       find AND FIX missing models + failed imports
#
#   ./setup.sh wan          OPTIONAL: Wan 2.2 Animate (~20GB more). Not in `all`.
#
# Safe to re-run — clones and downloads are skipped when already present, with
# size checks so a truncated download retries instead of silently passing.
#
# Everything runs on hardware you rent. No image or video leaves the box.

set -euo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_LOG="${COMFY_LOG:-/var/log/portal/comfyui.log}"
MIN_DISK_GB="${MIN_DISK_GB:-60}"

# --- custom nodes -----------------------------------------------------------
# name|repo — cloned into custom_nodes, requirements.txt installed if present
NODES=(
  "Comfyui_DreamID-V_wrapper|https://github.com/TTPlanetPig/Comfyui_DreamID-V_wrapper"
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "facerestore_cf|https://github.com/mav-rik/facerestore_cf"
  "ComfyUI-Frame-Interpolation|https://github.com/Fannovel16/ComfyUI-Frame-Interpolation"
)

# The wrapper's requirements.txt is incomplete; these fail to import without it.
# Face-swap will not run without these. Everything else is a nice-to-have.
REQUIRED_NODES="Comfyui_DreamID-V_wrapper ComfyUI-VideoHelperSuite"

EXTRA_PIP="easydict diffusers transformers accelerate sentencepiece ftfy omegaconf einops imageio-ffmpeg av"

# Minimum expected sizes, used to detect truncated downloads.
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

# have_file <path> <min_bytes>
have_file() {
  [ -f "$1" ] && [ "$(stat -c%s "$1" 2>/dev/null || echo 0)" -ge "$2" ]
}

# Where ComfyUI actually reads and writes. Templates often relocate these with
# --input-directory / --output-directory, so never assume $COMFY_DIR/input.
# Sets COMFY_IN, COMFY_OUT, COMFY_TMP.
comfy_paths() {
  local cmd
  cmd=$(ps aux 2>/dev/null | grep "[m]ain\.py" | head -1 || true)

  COMFY_IN=$(sed -n 's/.*--input-directory[= ]\([^ ]*\).*/\1/p'  <<<"$cmd")
  COMFY_OUT=$(sed -n 's/.*--output-directory[= ]\([^ ]*\).*/\1/p' <<<"$cmd")
  COMFY_TMP=$(sed -n 's/.*--temp-directory[= ]\([^ ]*\).*/\1/p'   <<<"$cmd")

  COMFY_IN="${COMFY_IN:-$COMFY_DIR/input}"
  COMFY_OUT="${COMFY_OUT:-$COMFY_DIR/output}"
  COMFY_TMP="${COMFY_TMP:-$COMFY_DIR/temp}"
}

# Shortcut so /workspace/input and /workspace/output reach the real dirs.
# ComfyUI's own paths live under $COMFY_DIR; people (and scp muscle memory)
# reach for the top level. Symlink rather than relocate -- relocating means
# editing supervisor config, which breaks on template updates.
#
# rmdir only succeeds on an EMPTY dir, so a leftover folder holding real files
# is left alone and reported instead of being clobbered.
comfy_links() {
  local name target link
  for name in input output; do
    case "$name" in
      input)  target="$COMFY_IN"  ;;
      output) target="$COMFY_OUT" ;;
    esac
    link="$WORKSPACE/$name"

    [ "$link" = "$target" ] && continue
    [ -L "$link" ] && { rm -f "$link"; }

    if [ -d "$link" ]; then
      if rmdir "$link" 2>/dev/null; then
        :                                  # was an empty leftover, now gone
      else
        warn "$link holds files and is NOT what ComfyUI reads — move them:"
        printf '           mv %s/* %s/\n' "$link" "$target"
        continue
      fi
    fi
    ln -s "$target" "$link" && ok "$link -> $target"
  done
}

do_paths() {
  phase "ComfyUI paths"
  comfy_paths
  mkdir -p "$COMFY_IN" "$COMFY_OUT"
  printf '  put clips and images here   %s\n' "$COMFY_IN"
  printf '  finished renders land here  %s\n' "$COMFY_OUT"
  printf '  scratch (wiped on restart)  %s\n' "$COMFY_TMP"
  echo
  comfy_links

  # "Where did my render go?" -- answered by looking, not by assuming. temp/
  # and the ComfyUI root are included precisely because that is where files
  # land when a node is misconfigured.
  echo
  step "files written in the last 2 hours"
  local found
  found=$(find "$COMFY_IN" "$COMFY_OUT" "$COMFY_TMP" "$COMFY_DIR" \
               -maxdepth 2 -type f -newermt '-120 minutes' \
               \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
                  -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' \
                  -o -iname '*.gif' -o -iname '*.mov' \) 2>/dev/null \
          | sort -u | head -25)
  if [ -n "$found" ]; then
    printf '%s\n' "$found" | while read -r f; do
      printf '  %-8s %s\n' "$(du -h "$f" 2>/dev/null | cut -f1)" "$f"
    done
  else
    echo "  none — nothing has been rendered or uploaded recently"
  fi

  cat <<EOF

  If your renders showed up in temp/ rather than output/, the node is the
  cause, not the path:

    * PreviewImage always writes to temp/. It is a preview, not a save.
      Use SaveImage.

    * VHS_VideoCombine writes to temp/ unless save_output is TICKED.
      Untick it and the render is discarded on the next restart.

  And after scp-ing into the input dir, hit Refresh in the ComfyUI menu or
  the LoadImage dropdown will not list the file. The list is cached.
EOF
}

# fetch <url> <dest> <min_bytes> <label>
fetch() {
  local url="$1" dest="$2" min="$3" label="$4"
  if have_file "$dest" "$min"; then ok "$label present"; return 0; fi
  step "downloading $label"
  mkdir -p "$(dirname "$dest")"
  if command -v curl >/dev/null; then
    curl -fsSL --retry 3 -o "$dest" "$url" || { warn "could not fetch $label"; return 1; }
  else
    wget -q --tries=3 -O "$dest" "$url" || { warn "could not fetch $label"; return 1; }
  fi
  ok "$label"
}

# hf_get <repo> <remote_path> <local_dir> <final_name> <min_bytes>
hf_get() {
  local repo="$1" remote="$2" dir="$3" name="$4" min="$5"
  local final="$dir/$name"
  if have_file "$final" "$min"; then ok "$name present"; return 0; fi
  step "downloading $name"
  mkdir -p "$dir"
  hf download "$repo" "$remote" --local-dir "$dir" >/dev/null || { warn "failed: $name"; return 1; }
  # Repackaged repos nest files under split_files/…; flatten and rename.
  local landed="$dir/$remote"
  [ -f "$landed" ] && [ "$landed" != "$final" ] && mv "$landed" "$final"
  find "$dir" -type d -empty -delete 2>/dev/null || true
  ok "$name"
}

# ----------------------------------------------------------------------------
# verify
# ----------------------------------------------------------------------------

do_verify() {
  phase "Preflight"

  [ -d "$COMFY_DIR" ] || die "ComfyUI not found at $COMFY_DIR. Set COMFY_DIR if it lives elsewhere."
  ok "ComfyUI at $COMFY_DIR"

  # DreamID-V requires torch >= 2.4
  if ! python -c "
import torch, sys
v = tuple(int(x) for x in torch.__version__.split('+')[0].split('.')[:2])
sys.exit(0 if v >= (2, 4) else 1)
" 2>/dev/null; then
    die "torch is $(torch_version) — need >= 2.4. Destroy this instance, pick a newer template."
  fi
  ok "torch $(torch_version)"

  command -v nvidia-smi >/dev/null || die "nvidia-smi missing — no GPU visible."
  ok "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"

  local avail
  avail=$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')
  [ "$avail" -ge "$MIN_DISK_GB" ] || \
    die "only ${avail}GB free, need >= ${MIN_DISK_GB}GB. Disk is NOT resizable — re-rent bigger."
  ok "disk: ${avail}GB free"

  command -v supervisorctl >/dev/null \
    && ok "supervisor present (ComfyUI is service-managed)" \
    || warn "no supervisor — you will start ComfyUI manually"
}

# ----------------------------------------------------------------------------
# env
# ----------------------------------------------------------------------------

do_env() {
  phase "Environment"

  step "apt packages"
  apt-get update -qq && apt-get install -y -qq tmux ffmpeg curl >/dev/null
  ok "tmux + ffmpeg + curl"

  # Without this, weights land in ~/.cache/huggingface AND get copied into
  # ComfyUI/models — paying for ~18GB of bandwidth and disk twice.
  export HF_HOME="$WORKSPACE/hf_cache"
  grep -q "HF_HOME=$WORKSPACE/hf_cache" ~/.bashrc 2>/dev/null || \
    echo "export HF_HOME=$WORKSPACE/hf_cache" >> ~/.bashrc
  ok "HF_HOME=$HF_HOME"

  # Model dirs only. Input/output are resolved from ComfyUI's actual launch
  # args in do_paths -- creating /workspace/{input,output} here would just
  # invent folders nothing reads from.
  mkdir -p "$COMFY_DIR"/models/{diffusion_models,vae,text_encoders,loras} \
           "$COMFY_DIR"/models/{facerestore_models,facedetection,upscale_models}
  ok "model directories"

  step "huggingface_hub CLI"
  pip install -q -U "huggingface_hub[cli]"
  ok "hf CLI"
}

# ----------------------------------------------------------------------------
# nodes
# ----------------------------------------------------------------------------

do_nodes() {
  phase "Custom nodes"

  local before after
  before=$(torch_version)

  for entry in "${NODES[@]}"; do
    local name="${entry%%|*}" repo="${entry##*|}"
    local dest="$COMFY_DIR/custom_nodes/$name"

    if [ -d "$dest/.git" ]; then
      ok "$name already cloned"
    else
      step "cloning $name"
      if git clone --depth 1 "$repo" "$dest" 2>/dev/null; then
        ok "$name"
      else
        warn "$name clone failed — install it from the ComfyUI Manager UI"
        continue
      fi
    fi

    [ -f "$dest/requirements.txt" ] && \
      pip install -q -r "$dest/requirements.txt" 2>/dev/null || true
  done

  step "deps the wrappers forget"
  # shellcheck disable=SC2086
  pip install -q $EXTRA_PIP
  ok "dependencies"

  after=$(torch_version)
  [ "$before" = "$after" ] || \
    die "torch changed during install: '$before' -> '$after'. A dependency downgraded it."
  ok "torch unchanged ($after)"
}

# ----------------------------------------------------------------------------
# models — DreamID-V, ~18GB
# ----------------------------------------------------------------------------

do_models() {
  phase "DreamID-V weights (~18GB)"

  export HF_HOME="$WORKSPACE/hf_cache"
  cd "$COMFY_DIR"

  hf_get XuGuo699/DreamID-V dreamidv.pth \
         models/diffusion_models dreamidv.pth "$SZ_DREAMIDV"

  hf_get Wan-AI/Wan2.1-T2V-1.3B Wan2.1_VAE.pth \
         models/vae Wan2.1_VAE.pth "$SZ_VAE"

  # Repo name and the name the wrapper expects differ — hf_get renames it.
  hf_get Wan-AI/Wan2.1-T2V-1.3B models_t5_umt5-xxl-enc-bf16.pth \
         models/text_encoders umt5-xxl-enc-bf16.pth "$SZ_UMT5"

  if [ -d "$HF_HOME" ]; then
    local kb; kb=$(du -sk "$HF_HOME" 2>/dev/null | cut -f1)
    [ "${kb:-0}" -gt 1000000 ] && \
      warn "hf_cache is $((kb / 1024))MB — duplicate copies. rm -rf $HF_HOME to reclaim."
  fi

  printf '\n'; df -h "$WORKSPACE" | tail -1
}

# ----------------------------------------------------------------------------
# enhance — restore, upscale, interpolate. ~1GB total.
# ----------------------------------------------------------------------------

do_enhance() {
  phase "Enhancement models (~1GB)"

  # Face restoration. DreamID-V derives identity from the source image, so a
  # soft photo gives a soft swap regardless of video quality.
  fetch "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth" \
        "$COMFY_DIR/models/facerestore_models/codeformer.pth" 300000000 "codeformer.pth" || true

  fetch "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth" \
        "$COMFY_DIR/models/facerestore_models/GFPGANv1.4.pth" 300000000 "GFPGANv1.4.pth" || true

  # Detection + parsing, required by both restorers.
  fetch "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth" \
        "$COMFY_DIR/models/facedetection/detection_Resnet50_Final.pth" 100000000 "detection_Resnet50_Final.pth" || true

  fetch "https://github.com/xinntao/facexlib/releases/download/v0.2.2/parsing_parsenet.pth" \
        "$COMFY_DIR/models/facedetection/parsing_parsenet.pth" 50000000 "parsing_parsenet.pth" || true

  # Upscalers. ComfyUI ships the nodes natively — weights only.
  # DreamID-V renders at 480p/720p, so a 1080p plate needs the swap lifted.
  fetch "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth" \
        "$COMFY_DIR/models/upscale_models/RealESRGAN_x2plus.pth" 50000000 "RealESRGAN_x2plus.pth" || true

  fetch "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" \
        "$COMFY_DIR/models/upscale_models/RealESRGAN_x4plus.pth" 50000000 "RealESRGAN_x4plus.pth" || true

  # Sharper on detail than Real-ESRGAN; softer on faces. Worth having both.
  fetch "https://huggingface.co/lokCX/4x-Ultrasharp/resolve/main/4x-UltraSharp.pth" \
        "$COMFY_DIR/models/upscale_models/4x-UltraSharp.pth" 50000000 "4x-UltraSharp.pth" || true

  # RIFE frame interpolation — smooth slow-motion without the judder you get
  # from simply retiming, and frame-rate conversion.
  fetch "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation/releases/download/models/rife47.pth" \
        "$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife47.pth" \
        10000000 "rife47.pth" || true

  printf '\n'
  ls -lh "$COMFY_DIR"/models/facerestore_models/ \
         "$COMFY_DIR"/models/upscale_models/ 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# wan — OPTIONAL. Wan 2.2 Animate, ~20GB on top of everything else.
#
# A different tool for the same job as DreamID-V: it regenerates the whole
# person from a reference image and matches scene lighting, rather than
# replacing the face region. Better identity from a single photo; slower,
# pricier, and it can drift on costume detail.
#
# Deliberately NOT part of `all` — only run it if you actually want to compare.
# ----------------------------------------------------------------------------

do_wan() {
  phase "Wan 2.2 Animate (OPTIONAL, ~20GB)"

  warn "this is ~20GB on top of DreamID-V's 18GB — bandwidth is billed separately"
  warn "skip unless you specifically want to compare against DreamID-V"
  printf '\n'

  local avail
  avail=$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')
  [ "$avail" -ge 45 ] || die "only ${avail}GB free — Wan needs ~45GB headroom."

  export HF_HOME="$WORKSPACE/hf_cache"
  cd "$COMFY_DIR"

  local repo="Comfy-Org/Wan_2.2_ComfyUI_Repackaged"

  # int8 rather than bf16: roughly half the size, fits 24GB comfortably.
  hf_get "$repo" split_files/diffusion_models/wan2.2_animate_14B_int8_convrot.safetensors \
         models/diffusion_models wan2.2_animate_14B_int8.safetensors 8000000000

  hf_get "$repo" split_files/vae/wan_2.1_vae.safetensors \
         models/vae wan_2.1_vae.safetensors 200000000

  hf_get "$repo" split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors \
         models/text_encoders umt5_xxl_fp8_scaled.safetensors 5000000000

  # Relight LoRA — matches the inserted character to scene lighting. This is
  # the thing that makes Animate blend rather than look pasted in.
  hf_get "$repo" split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors \
         models/loras wan2.2_animate_relight_lora.safetensors 100000000

  local wrapper="$COMFY_DIR/custom_nodes/ComfyUI-WanVideoWrapper"
  if [ -d "$wrapper/.git" ]; then
    ok "WanVideoWrapper already cloned"
  else
    step "cloning WanVideoWrapper"
    if git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper "$wrapper" 2>/dev/null; then
      pip install -q -r "$wrapper/requirements.txt" 2>/dev/null || true
      ok "WanVideoWrapper"
    else
      warn "clone failed — install 'ComfyUI-WanVideoWrapper' from ComfyUI Manager"
    fi
  fi

  printf '\n'; df -h "$WORKSPACE" | tail -1
  warn "restart ComfyUI to load the new nodes: ./setup.sh restart"
}

# ----------------------------------------------------------------------------
# doctor — find and fix what's missing, without you reading logs
#
# Custom node requirements.txt files are routinely incomplete, and each missing
# module only surfaces one at a time across separate restarts. This automates
# that loop: restart, read the new log lines, pip install whatever failed to
# import, repeat until clean.
# ----------------------------------------------------------------------------

# Import name -> pip name, where they differ.
declare -A PIP_ALIAS=(
  [cv2]=opencv-python  [PIL]=Pillow          [skimage]=scikit-image
  [sklearn]=scikit-learn [yaml]=PyYAML       [Crypto]=pycryptodome
  [git]=GitPython      [onnxruntime]=onnxruntime-gpu
  [dateutil]=python-dateutil [pkg_resources]=setuptools
)

do_doctor() {
  phase "Doctor"

  # --- models --------------------------------------------------------------
  step "checking models"
  local missing_models=0
  local -A want=(
    ["models/diffusion_models/dreamidv.pth"]=$SZ_DREAMIDV
    ["models/vae/Wan2.1_VAE.pth"]=$SZ_VAE
    ["models/text_encoders/umt5-xxl-enc-bf16.pth"]=$SZ_UMT5
    ["models/facerestore_models/codeformer.pth"]=300000000
    ["models/facedetection/detection_Resnet50_Final.pth"]=100000000
    ["models/upscale_models/RealESRGAN_x2plus.pth"]=50000000
  )
  for f in "${!want[@]}"; do
    if have_file "$COMFY_DIR/$f" "${want[$f]}"; then
      ok "$(basename "$f")"
    else
      warn "missing or truncated: $f"
      missing_models=1
    fi
  done

  if [ "$missing_models" -eq 1 ]; then
    step "re-running downloads (idempotent — present files are skipped)"
    do_models
    do_enhance
  fi

  # --- modules -------------------------------------------------------------
  if ! command -v supervisorctl >/dev/null || ! supervisorctl status comfyui >/dev/null 2>&1; then
    warn "ComfyUI not supervisor-managed — cannot auto-heal imports"
    return 0
  fi
  [ -f "$COMFY_LOG" ] || { warn "no log at $COMFY_LOG"; return 0; }

  local attempt offset missing failed pkg pkgs f
  for attempt in 1 2 3 4 5; do
    # Only read lines produced by THIS restart — the log accumulates, so old
    # errors would otherwise be re-detected forever.
    offset=$(wc -l < "$COMFY_LOG")
    step "restart $attempt/5"
    supervisorctl restart comfyui >/dev/null
    sleep 25

    missing=$(tail -n +$((offset + 1)) "$COMFY_LOG" \
              | grep -oP "No module named '\K[^']+" \
              | cut -d. -f1 | sort -u || true)

    # A node can fail to import for reasons that are NOT a missing module --
    # a compile error, a bad CUDA build, an API change. Checking only for
    # ModuleNotFoundError would call that a clean run.
    failed=$(tail -n +$((offset + 1)) "$COMFY_LOG" \
             | grep -oP "IMPORT FAILED\).*?custom_nodes/\K[^ /]+" | sort -u || true)

    if [ -z "$missing" ]; then
      if [ -n "$failed" ]; then
        warn "no missing modules, but these nodes still failed to import:"
        for f in $failed; do
          case " $REQUIRED_NODES " in
            *" $f "*) printf '         %s  <-- REQUIRED\n' "$f" ;;
            *)        printf '         %s  (optional)\n' "$f" ;;
          esac
        done
        warn "see why: grep -B25 'IMPORT FAILED' $COMFY_LOG | tail -40"
      else
        ok "all nodes imported cleanly"
      fi
      break
    fi

    pkgs=""
    for pkg in $missing; do
      pkgs="$pkgs ${PIP_ALIAS[$pkg]:-$pkg}"
    done
    step "installing:$pkgs"

    local before after
    before=$(torch_version)
    # shellcheck disable=SC2086
    pip install -q $pkgs 2>/dev/null || warn "some of$pkgs would not install"
    after=$(torch_version)
    [ "$before" = "$after" ] || \
      die "torch changed: '$before' -> '$after'. One of$pkgs downgraded it."

    [ "$attempt" -eq 5 ] && warn "still failing after 5 rounds — inspect: tail -50 $COMFY_LOG"
  done

  grep -E "IMPORT FAILED" "$COMFY_LOG" | tail -3 || true
  do_paths
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
  sleep 25

  [ -f "$COMFY_LOG" ] || { warn "log not found at $COMFY_LOG"; return 0; }

  if grep -q "IMPORT FAILED" "$COMFY_LOG"; then
    printf '\n'
    grep -i "ModuleNotFoundError" "$COMFY_LOG" | tail -5
    printf '\n'
    warn "a node failed to import. pip install the missing module above, then:"
    warn "  ./setup.sh restart"
  fi

  grep -E "DreamID-V Wrapper.*Loaded" "$COMFY_LOG" | tail -1 && ok "DreamID-V loaded" \
    || warn "no DreamID-V load line — check: tail -50 $COMFY_LOG"
}

# ----------------------------------------------------------------------------

do_all() {
  do_verify
  do_env
  do_nodes
  do_models
  do_enhance
  do_restart
  do_paths

  phase "Ready"
  cat <<EOF
  Tunnel from your machine (note 18188, NOT 8188):

    ssh -p PORT root@HOST -L 8188:localhost:18188 -t "tmux attach -t work || tmux new -s work"

  Then open http://localhost:8188

  Installed:
    DreamID-V          video face swap, no frame flicker
    VideoHelperSuite   video load/combine + inline player on the output node
    facerestore_cf     CodeFormer / GFPGAN for source photos
    Frame-Interpolation RIFE, for smooth slow-motion
    upscalers          RealESRGAN x2/x4, 4x-UltraSharp

  Order of work:
    1. restore source photos    fidelity 0.5 and 0.7, keep whichever still
                                looks like the person
    2. swap a 2s test clip      confirm resolution, VRAM, output format
    3. swap the real clips
    4. download, then DESTROY the instance

  Optional: ./setup.sh wan      Wan 2.2 Animate, ~20GB more
            ./setup.sh paths    re-print the input/output paths above
            ./setup.sh doctor   auto-fix missing models and failed imports

  Nothing leaves this machine.
EOF
}

case "${1:-all}" in
  all)      do_all ;;
  verify)   do_verify ;;
  env)      do_env ;;
  nodes)    do_nodes ;;
  models)   do_models ;;
  enhance)  do_enhance ;;
  wan)      do_wan ;;
  restart)  do_restart ;;
  paths)    do_paths ;;
  doctor)   do_doctor ;;
  *)        die "unknown phase '$1' (all|verify|env|nodes|models|enhance|wan|restart|paths|doctor)" ;;
esac
