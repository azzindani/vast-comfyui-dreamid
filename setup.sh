#!/usr/bin/env bash
#
# One-command provisioning for AI video, image, 3D and audio work on a
# vast.ai ComfyUI instance.
#
#   ./setup.sh                  everything except `wan`
#
# Setup phases
#   ./setup.sh verify           preflight — aborts before anything expensive
#   ./setup.sh env              apt packages, HF_HOME, directories
#   ./setup.sh nodes            custom nodes + the deps they forget
#   ./setup.sh models           DreamID-V weights (~18GB)
#   ./setup.sh enhance          face restore, upscalers, interpolation (~1GB)
#   ./setup.sh restart          restart ComfyUI, confirm nodes loaded
#   ./setup.sh wan              OPTIONAL: Wan 2.2 Animate (~20GB). Not in `all`.
#
# Inspect
#   ./setup.sh paths            where ComfyUI actually reads and writes
#   ./setup.sh doctor           find AND FIX missing models + failed imports
#   ./setup.sh profiles         list available pipelines
#
# Change things mid-session
#   ./setup.sh profile <name>   install one pipeline's node set
#   ./setup.sh add <url|name>   add a node or a profile, then restart
#   ./setup.sh disable <node>   skip a node without uninstalling it
#   ./setup.sh enable <node>    put it back
#   ./setup.sh pin              pin torch/numpy so installs cannot move them
#
# Safe to re-run — clones and downloads are skipped when already present, with
# size checks so a truncated download retries instead of silently passing.
#
# Everything runs on hardware you rent. No image, video or audio leaves the box.

set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for module in common env nodes models doctor; do
  # shellcheck source=/dev/null
  source "$SETUP_DIR/lib/$module.sh"
done

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
    KJNodes            resize, constants, masks, VRAM debug
    facerestore_cf     CodeFormer / GFPGAN for source photos
    upscalers          RealESRGAN x2/x4, 4x-UltraSharp

  Order of work:
    1. restore source photos    fidelity 0.5 and 0.7, keep whichever still
                                looks like the person
    2. swap a 2s test clip      confirm resolution, VRAM, output format
    3. swap the real clips
    4. download, then DESTROY the instance

  Other pipelines:
    ./setup.sh profiles         video editing, generation, restore, 3D, audio
    ./setup.sh add <git-url>    pull in one more node without a rebuild
    ./setup.sh doctor           auto-fix missing models and failed imports

  What each task is and which tool does it:  docs/taxonomy.md
  Copy-paste recipes per task group:         docs/recipes.md

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
  pin)      do_pin ;;
  profile)  do_profile "${2:-}" ;;
  profiles) list_profiles ;;
  add)      do_add "${2:-}" ;;
  disable)  do_toggle disable "${2:-}" ;;
  enable)   do_toggle enable  "${2:-}" ;;
  *)        die "unknown phase '$1'
         setup:   all verify env nodes models enhance wan restart
         inspect: paths doctor profiles
         change:  profile <name>  add <url|profile>  disable <node>  enable <node>  pin" ;;
esac
