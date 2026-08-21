#!/usr/bin/env bash
#
# Model downloads: DreamID-V weights, enhancement models, optional Wan.

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
# Profile models
# ----------------------------------------------------------------------------
#
# A profile declares MODELS as "repo|remote_path|dest_subdir|filename|min_bytes".
# min_bytes is ~90% of the real size, so a truncated download is caught rather
# than silently loading a corrupt file.
#
# Not every profile needs this: some nodes fetch their own weights on first use.
# Those profiles declare no MODELS and say so.

do_profile_models() {
  local entry repo remote dir name min total=0 avail
  [ "${#MODELS[@]}" -eq 0 ] && {
    ok "no models to pre-download for this profile"
    [ -n "${MODELS_NOTE:-}" ] && printf '       %s\n' "$MODELS_NOTE"
    return 0
  }

  for entry in "${MODELS[@]}"; do
    IFS='|' read -r _ _ _ _ min <<<"$entry"
    total=$(( total + min ))
  done

  phase "Profile models (~$(( total / 1000000000 )) GB)"
  avail=$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt $(( total / 1000000000 + 10 )) ]; then
    die "need ~$(( total / 1000000000 + 10 ))GB free, have ${avail}GB. Disk is not resizable — start a bigger box."
  fi
  warn "vast bills bandwidth per GB — this download is a real charge"

  for entry in "${MODELS[@]}"; do
    IFS='|' read -r repo remote dir name min <<<"$entry"
    hf_get "$repo" "$remote" "$COMFY_DIR/$dir" "$name" "$min"
  done
}
