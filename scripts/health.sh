#!/usr/bin/env bash
#
# Quick health check. Run any time — before a big render, after installing a
# node, or when something starts behaving oddly.

set -uo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_LOG="${COMFY_LOG:-/var/log/portal/comfyui.log}"

echo "--- torch ---"
python -c "import torch; print(torch.__version__, torch.version.cuda, 'cuda_available=', torch.cuda.is_available())" 2>&1

echo
echo "--- gpu ---"
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
           --format=csv,noheader 2>&1

echo
echo "--- disk ---"
df -h "$WORKSPACE" | tail -1
echo "hf_cache: $(du -sh "$WORKSPACE/hf_cache" 2>/dev/null | cut -f1 || echo n/a)"

echo
echo "--- models ---"
for f in \
  "$COMFY_DIR/models/diffusion_models/dreamidv.pth" \
  "$COMFY_DIR/models/vae/Wan2.1_VAE.pth" \
  "$COMFY_DIR/models/text_encoders/umt5-xxl-enc-bf16.pth"
do
  if [ -f "$f" ]; then
    printf '  ok   %s (%s)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  else
    printf '  MISSING %s\n' "$f"
  fi
done

echo
echo "--- attention backend ---"
# Absent is correct: the wrapper falls back to SDPA, which is what we want on
# cu130 where no flash-attn/sageattention wheels exist.
for m in flash_attn sageattention; do
  if python -c "import $m" 2>/dev/null; then
    printf '  %s installed (unexpected on cu130 — verify it actually runs)\n' "$m"
  else
    printf '  %s absent -> SDPA fallback (correct)\n' "$m"
  fi
done

echo
echo "--- comfyui paths ---"
# Templates relocate these with --input-directory / --output-directory, so read
# them off the running process rather than assuming.
CMD=$(ps aux 2>/dev/null | grep "[m]ain\.py" | head -1)
IN=$(sed -n 's/.*--input-directory[= ]\([^ ]*\).*/\1/p'  <<<"$CMD")
OUT=$(sed -n 's/.*--output-directory[= ]\([^ ]*\).*/\1/p' <<<"$CMD")
printf '  input:  %s\n' "${IN:-$COMFY_DIR/input}"
printf '  output: %s\n' "${OUT:-$COMFY_DIR/output}"
echo "  recent files (last 60 min):"
find "${IN:-$COMFY_DIR/input}" "${OUT:-$COMFY_DIR/output}" "$COMFY_DIR/temp" \
     -newermt '-60 minutes' -type f 2>/dev/null | head -10 | sed 's/^/    /' \
  || echo "    none"

echo
echo "--- services ---"
if command -v supervisorctl >/dev/null; then
  supervisorctl status 2>&1 | grep -E "comfyui|caddy" || echo "  none found"
else
  echo "  no supervisor"
fi

echo
echo "--- ports ---"
ss -tlnp 2>/dev/null | grep -E "8188|18188|18288" || echo "  nothing listening"

echo
echo "--- node load ---"
if [ -f "$COMFY_LOG" ]; then
  grep -E "DreamID-V Wrapper.*Loaded|IMPORT FAILED" "$COMFY_LOG" | tail -3 \
    || echo "  no DreamID lines in log"
else
  echo "  log not found at $COMFY_LOG"
fi
