#!/usr/bin/env bash
#
# Compact render status — built for a phone screen. Ten lines, no scrolling.
# Use health.sh when you want the full diagnostic instead.
#
# Note: pipefail means a failing curl/find poisons the whole pipeline's exit
# status even when the consumer succeeded, so each check captures its input
# first and tests that, rather than relying on `|| fallback` after a pipe.

set -uo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
PORT="${COMFY_PORT:-18188}"

CMD=$(ps aux 2>/dev/null | grep "[m]ain\.py" | head -1)
OUT=$(sed -n 's/.*--output-directory[= ]\([^ ]*\).*/\1/p' <<<"$CMD")
OUT="${OUT:-$COMFY_DIR/output}"

echo "-- queue --"
QUEUE=$(curl -s --max-time 5 "127.0.0.1:$PORT/queue" 2>/dev/null || true)
if [ -z "$QUEUE" ]; then
  echo "  ComfyUI not responding on $PORT"
else
  printf '%s' "$QUEUE" | python3 -c '
import json, sys
try:
    q = json.load(sys.stdin)
except Exception:
    print("  unreadable response"); raise SystemExit(0)
r, p = len(q.get("queue_running", [])), len(q.get("queue_pending", []))
print(f"  running {r}   pending {p}")
print("  IDLE — nothing queued" if not r and not p else f"  {r + p} job(s) to go")
'
fi

echo "-- gpu --"
GPU=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
                 --format=csv,noheader 2>/dev/null || true)
[ -n "$GPU" ] && sed 's/^/  /' <<<"$GPU" || echo "  no GPU visible"

echo "-- last renders --"
RECENT=$(find "$OUT" -type f \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.png' \) \
              -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -5 || true)
if [ -z "$RECENT" ]; then
  echo "  none yet in $OUT"
else
  while read -r ts path; do
    printf '  %s  %-6s %s\n' \
      "$(date -d "@${ts%.*}" '+%H:%M')" \
      "$(du -h "$path" 2>/dev/null | cut -f1)" \
      "$(basename "$path")"
  done <<<"$RECENT"
fi

echo "-- disk --"
df -h "$COMFY_DIR" 2>/dev/null | tail -1 | awk '{print "  "$4" free of "$2}'
