#!/usr/bin/env bash
#
# Preflight, environment, path reporting, service restart.

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
