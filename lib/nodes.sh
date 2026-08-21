#!/usr/bin/env bash
#
# Custom nodes: install, core-package pinning, profiles, mid-session changes.

# nodes
# ----------------------------------------------------------------------------

do_nodes() {
  phase "Custom nodes"

  local before after np_before np_after
  before=$(torch_version)
  np_before=$(numpy_version)

  for entry in "${NODES[@]}"; do
    local name="${entry%%|*}" repo="${entry##*|}"
    local dest="$COMFY_DIR/custom_nodes/$name"

    # ComfyUI loads a directory node through its __init__.py. A clone that was
    # interrupted leaves .git behind without it, which reads as "installed" but
    # fails at import — so check for the file, not just the directory.
    if [ -d "$dest/.git" ] && [ -f "$dest/__init__.py" ]; then
      ok "$name already cloned"
    else
      if [ -d "$dest" ]; then
        warn "$name present but incomplete (no __init__.py) — re-cloning"
        rm -rf "$dest"
      fi
      step "cloning $name"
      if git clone --depth 1 "$repo" "$dest" 2>/dev/null; then
        ok "$name"
      else
        warn "$name clone failed — install it from the ComfyUI Manager UI"
        continue
      fi
    fi

    [ -f "$dest/requirements.txt" ] && pip_reqs "$dest/requirements.txt" "$name"
  done

  step "deps the wrappers forget"
  # shellcheck disable=SC2086
  pip install -q $EXTRA_PIP
  ok "dependencies"

  ensure_decord

  after=$(torch_version)
  [ "$before" = "$after" ] || \
    die "torch changed during install: '$before' -> '$after'. A dependency downgraded it."
  ok "torch unchanged ($after)"

  # KJNodes and friends pull packages that happily jump numpy to 2.x, which
  # breaks mediapipe -- and mediapipe is how the wrapper extracts pose. Repair
  # rather than abort: the node requirements are already satisfied by this point.
  np_after=$(numpy_version)
  if [ "$np_before" != "MISSING" ] && [ "$np_before" != "$np_after" ]; then
    warn "numpy moved $np_before -> $np_after during install; pinning back"
    pip install -q "numpy==$np_before" 2>/dev/null || true
    np_after=$(numpy_version)
    if [ "$np_before" = "$np_after" ]; then
      ok "numpy restored ($np_after)"
    else
      warn "numpy is $np_after, wanted $np_before — if pose extraction fails, run:"
      printf '           pip install "numpy==%s"\n' "$np_before"
    fi
  else
    ok "numpy unchanged ($np_after)"
  fi
}
# ----------------------------------------------------------------------------
# Profiles — one pipeline, one small node set.
#
# Every custom node installs into ONE shared Python environment, so conflicts
# scale with node count, not with how many you actually use. Five nodes for the
# job at hand beats fifty installed "just in case". On rented hardware a
# rebuild costs minutes, which makes per-job installs the cheap option.

# Repo root, not lib/. SETUP_DIR is exported by setup.sh; the fallback keeps
# this module usable if it is ever sourced on its own.
REPO_DIR="${SETUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONSTRAINTS="${CONSTRAINTS:-$REPO_DIR/constraints.txt}"

list_profiles() {
  phase "Profiles"
  local f name desc
  for f in "$REPO_DIR"/profiles/*.conf; do
    [ -f "$f" ] || { echo "  none found in $REPO_DIR/profiles"; return; }
    name=$(basename "$f" .conf)
    desc=$(sed -n 's/^# *DESC: *//p' "$f" | head -1)
    printf '  %-12s %s\n' "$name" "$desc"
  done
  echo
  echo "  ./setup.sh profile <name>"
}

# Pin the packages that node requirements most often break, so pip refuses to
# move them instead of silently downgrading torch mid-install.
do_pin() {
  phase "Pinning core packages"
  pip freeze 2>/dev/null \
    | grep -iE "^(torch|torchvision|torchaudio|numpy|opencv-python|opencv-python-headless)==" \
    > "$CONSTRAINTS" || true
  if [ -s "$CONSTRAINTS" ]; then
    sed 's/^/  /' "$CONSTRAINTS"
    ok "written to $CONSTRAINTS"
  else
    warn "nothing to pin — is this the right Python environment?"
    rm -f "$CONSTRAINTS"
  fi
}

# Add one node mid-session, without redoing a whole profile.
#
# Accepts a git URL or a profile name -- adding a profile is additive here,
# unlike `profile`, which declares the set for a run. Restarts and then checks
# the log to say whether the thing actually imported, because a clone that
# succeeds tells you nothing.
do_add() {
  local what="$1" name repo f offset failed
  [ -n "$what" ] || die "usage: ./setup.sh add <git-url|profile-name>"

  if [ -f "$REPO_DIR/profiles/$what.conf" ]; then
    phase "Adding profile: $what"
    MODELS=(); MODELS_NOTE=""
    # shellcheck disable=SC1090
    source "$REPO_DIR/profiles/$what.conf"
    [ -f "$CONSTRAINTS" ] || do_pin
    do_nodes
    do_profile_models
    do_restart
    return
  fi

  case "$what" in
    http*://*|git@*) ;;
    *) list_profiles; die "'$what' is neither a git URL nor a profile" ;;
  esac

  name=$(basename "$what" .git)
  repo="$what"
  local dest="$COMFY_DIR/custom_nodes/$name"

  phase "Adding node: $name"
  [ -f "$CONSTRAINTS" ] || do_pin

  if [ -d "$dest/.git" ] && [ -f "$dest/__init__.py" ]; then
    step "already present — pulling latest"
    git -C "$dest" pull --ff-only 2>/dev/null || warn "pull failed, keeping what is there"
  else
    [ -d "$dest" ] && { warn "incomplete install present — replacing"; rm -rf "$dest"; }
    step "cloning"
    git clone --depth 1 "$repo" "$dest" 2>/dev/null || die "clone failed: $repo"
  fi

  [ -f "$dest/requirements.txt" ] && pip_reqs "$dest/requirements.txt" "$name"

  offset=$(wc -l < "$COMFY_LOG" 2>/dev/null || echo 0)
  step "restarting to load it"
  supervisorctl restart comfyui >/dev/null 2>&1 || warn "restart failed"
  sleep 25

  failed=$(tail -n +$((offset + 1)) "$COMFY_LOG" 2>/dev/null \
           | grep -c "IMPORT FAILED.*$name" || true)
  if [ "${failed:-0}" -gt 0 ]; then
    warn "$name is installed but FAILED to import"
    warn "  run: ./setup.sh doctor"
  else
    ok "$name loaded"
  fi
  echo "  Refresh the ComfyUI browser tab — the node list is cached at page load."
}

# Disable rather than uninstall: ComfyUI skips any directory ending .disabled.
# Reversible, and it removes a node as a variable without losing the install.
do_toggle() {
  local action="$1" name="$2" base
  [ -n "$name" ] || die "usage: ./setup.sh $action <node-name>"
  base="$COMFY_DIR/custom_nodes/$name"

  case "$action" in
    disable)
      [ -d "$base" ] || die "no such node: $name"
      mv "$base" "$base.disabled" && ok "$name disabled"
      ;;
    enable)
      [ -d "$base.disabled" ] || die "not disabled: $name"
      mv "$base.disabled" "$base" && ok "$name enabled"
      ;;
  esac
  step "restart to apply: supervisorctl restart comfyui"
}

do_profile() {
  local name="$1" f
  [ -n "$name" ] || { list_profiles; die "usage: ./setup.sh profile <name>"; }
  f="$REPO_DIR/profiles/$name.conf"
  [ -f "$f" ] || { list_profiles; die "no profile '$name'"; }

  phase "Profile: $name"
  sed -n 's/^# *DESC: *//p' "$f" | head -1 | sed 's/^/  /'

  # Profiles set NODES / REQUIRED_NODES / EXTRA_PIP / MODELS for this run only.
  MODELS=(); MODELS_NOTE=""
  # shellcheck disable=SC1090
  source "$f"

  [ -f "$CONSTRAINTS" ] || do_pin
  do_nodes
  do_profile_models
  do_restart
}
