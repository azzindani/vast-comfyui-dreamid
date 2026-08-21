#!/usr/bin/env bash
#
# Shared helpers: output, package guards, path resolution, downloads.
# Sourced by setup.sh — not meant to be run directly.

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_LOG="${COMFY_LOG:-/var/log/portal/comfyui.log}"
MIN_DISK_GB="${MIN_DISK_GB:-60}"

# --- custom nodes -----------------------------------------------------------
# name|repo — cloned into custom_nodes, requirements.txt installed if present
NODES=(
  "Comfyui_DreamID-V_wrapper|https://github.com/TTPlanetPig/Comfyui_DreamID-V_wrapper"
  "ComfyUI-VideoHelperSuite|https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "ComfyUI-KJNodes|https://github.com/kijai/ComfyUI-KJNodes"
  "facerestore_cf|https://github.com/mav-rik/facerestore_cf"
  "ComfyUI-Frame-Interpolation|https://github.com/Fannovel16/ComfyUI-Frame-Interpolation"
)

# The wrapper's requirements.txt is incomplete; these fail to import without it.
# Face-swap will not run without these. Everything else is a nice-to-have.
#
# KJNodes is not a DreamID-V dependency, but the wrapper's own example workflow
# is built with ImageResizeKJv2 / ImageConcatMulti / INTConstant, so the
# workflow will not open without it.
REQUIRED_NODES="Comfyui_DreamID-V_wrapper ComfyUI-VideoHelperSuite ComfyUI-KJNodes"

EXTRA_PIP="easydict diffusers transformers accelerate sentencepiece ftfy omegaconf einops imageio-ffmpeg av"

# Minimum expected sizes, used to detect truncated downloads.
SZ_DREAMIDV=6000000000     # ~6.4 GB
SZ_UMT5=10000000000        # ~11 GB
SZ_VAE=400000000           # ~485 MB

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

numpy_version() {
  python -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "MISSING"
}

# decord is imported INSIDE the sampler's generate(), not at node load. So a
# missing decord passes every startup check, then fails ~90s into a render
# after the models are already loaded. Install it up front.
#
# Upstream decord is unmaintained and its last release predates current
# Pythons; eva-decord is the maintained fork that provides the same `decord`
# module. Try upstream first so a working install is never shadowed.
# Install a node's requirements under the core pins when they exist.
#
# pip is last-writer-wins: a node that pins an older torch will happily
# downgrade a working CUDA build with no warning. A constraints file makes pip
# refuse instead. When it refuses, skipping that node's deps is the safer
# failure -- one broken node beats a broken environment.
pip_reqs() {
  local req="$1" label="$2" log
  log=$(mktemp)

  if [ -f "$CONSTRAINTS" ]; then
    if pip install -q -r "$req" -c "$CONSTRAINTS" >"$log" 2>&1; then
      rm -f "$log"; return 0
    fi
    warn "$label: requirements conflict with the pinned core packages"
    grep -iE "conflict|incompatible|constraint|cannot install|ResolutionImpossible" "$log" \
      | head -3 | sed 's/^/           /'
    warn "  its deps were NOT installed, to protect torch/numpy"
    warn "  if the node fails to import, install what it needs by hand"
    rm -f "$log"; return 1
  fi

  pip install -q -r "$req" >"$log" 2>&1 || \
    warn "$label: some requirements failed (run ./setup.sh doctor)"
  rm -f "$log"
}

ensure_decord() {
  python -c "import decord" 2>/dev/null && { ok "decord present"; return 0; }
  step "installing decord (lazy import — otherwise fails mid-render)"
  pip install -q decord 2>/dev/null || true
  python -c "import decord" 2>/dev/null && { ok "decord"; return 0; }
  warn "no upstream decord wheel for this Python — trying the eva-decord fork"
  pip install -q eva-decord 2>/dev/null || true
  python -c "import decord" 2>/dev/null && { ok "decord (eva-decord fork)"; return 0; }
  warn "decord unavailable — the sampler will fail when reading video reference input"
  return 1
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
