#!/usr/bin/env bash
#
# Doctor: find and fix missing models and failed imports.

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

  # Checked explicitly: decord is imported at render time, not at node load,
  # so it never appears in the startup log the module loop below reads.
  step "checking lazy imports"
  ensure_decord || true

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
