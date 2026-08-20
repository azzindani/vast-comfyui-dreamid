#!/usr/bin/env python3
"""
Queue a long clip as overlapping chunks, in one command.

Video models have a fixed frame window (81 for Wan-family models), so a clip
longer than that has to be rendered in passes. Doing it by hand means editing
skip_first_frames and re-queueing for every chunk, which is where mistakes and
missed frames come from.

    # see the plan without queueing anything
    python scripts/queue-chunks.py workflow_api.json --total 216 --dry-run

    # queue it
    python scripts/queue-chunks.py workflow_api.json --total 216

Export the workflow as API format first: Workflow > Export (API) in ComfyUI.
The normal .json save is the UI format and will not work here.

Chunks overlap so you have frames to cross-dissolve across in the editor --
without an overlap, every join is a hard cut with a visible pop.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import urllib.error
import urllib.request

LOADER = "VHS_LoadVideo"
COMBINE = "VHS_VideoCombine"


def find(wf, class_type):
    return [(nid, n) for nid, n in wf.items() if n.get("class_type") == class_type]


def resolve(wf, node, key):
    """Return ('literal', node_id, key) or ('link', upstream_id, 'value').

    A widget fed by a link (an INTConstant, say) ignores its own value, so
    writing to it silently does nothing. Follow the link to the real source.
    """
    val = node["inputs"].get(key)
    if isinstance(val, list) and len(val) == 2:
        up = str(val[0])
        if up in wf and "value" in wf[up].get("inputs", {}):
            return "link", up, "value"
        return "unwritable", up, key
    return "literal", None, key


def probe_frames(video, fps):
    """Frame count via ffprobe. Returns None if it cannot be determined."""
    for d in ("/workspace/ComfyUI/input", os.getcwd()):
        path = video if os.path.isabs(video) else os.path.join(d, video)
        if os.path.isfile(path):
            break
    else:
        return None
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "format=duration", "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=30).stdout.strip()
        return int(float(out) * fps)
    except Exception:
        return None


def plan(total, frames, overlap):
    """Chunk start offsets covering `total` frames, with no gaps.

    Spaces chunks evenly rather than stepping at a fixed interval and clamping
    the last one. Fixed stepping leaves a final chunk that can overlap its
    predecessor almost entirely -- a whole render pass for a handful of new
    frames. Even spacing uses the same chunk count and spreads the slack as
    extra overlap, which the dissolves want anyway.
    """
    step_max = frames - overlap
    if step_max <= 0:
        sys.exit(f"overlap ({overlap}) must be smaller than frames ({frames})")
    if total <= frames:
        return [0]
    span = total - frames
    n = math.ceil(span / step_max) + 1
    return [round(i * span / (n - 1)) for i in range(n)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workflow", help="workflow exported as API format")
    ap.add_argument("--frames", type=int, default=81,
                    help="frames per chunk; keep to 4n+1 (default: 81)")
    ap.add_argument("--overlap", type=int, default=13,
                    help="frames shared between chunks, for dissolves (default: 13)")
    ap.add_argument("--total", type=int,
                    help="total frames in the clip (default: probe with ffprobe)")
    ap.add_argument("--fps", type=float, default=24.0, help="used only when probing")
    ap.add_argument("--server", default="http://127.0.0.1:18188")
    ap.add_argument("--prefix", default="chunk",
                    help="output filename prefix; chunk index is appended")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, queue nothing")
    args = ap.parse_args()

    with open(args.workflow) as fh:
        wf = json.load(fh)
    if not isinstance(wf, dict) or "nodes" in wf:
        sys.exit("that looks like a UI workflow — re-export with Workflow > Export (API)")

    loaders = find(wf, LOADER)
    if not loaders:
        sys.exit(f"no {LOADER} node found")
    if len(loaders) > 1:
        sys.exit(f"{len(loaders)} {LOADER} nodes — this script handles one")
    lid, loader = loaders[0]

    total = args.total or probe_frames(loader["inputs"].get("video", ""), args.fps)
    if not total:
        sys.exit("could not determine clip length — pass --total FRAMES")

    starts = plan(total, args.frames, args.overlap)

    # Point the frame cap at args.frames, following a link if one feeds it.
    kind, up, key = resolve(wf, loader, "frame_load_cap")
    if kind == "link":
        wf[up]["inputs"][key] = args.frames
        capnote = f"via node {up}"
    elif kind == "literal":
        loader["inputs"]["frame_load_cap"] = args.frames
        capnote = "direct"
    else:
        capnote = "NOT SET — driven by a node this script cannot write"

    outputs = [(nid, n) for nid, n in find(wf, COMBINE)
               if n["inputs"].get("save_output")]

    print(f"clip      {total} frames")
    print(f"chunks    {len(starts)} x {args.frames} frames, {args.overlap} overlap")
    print(f"frame cap {args.frames} ({capnote})")
    if not outputs:
        print(f"WARNING   no {COMBINE} has save_output enabled — renders will go to temp/")
    print()
    for i, s in enumerate(starts, 1):
        end = min(s + args.frames, total) - 1
        print(f"  {i}/{len(starts)}  skip={s:<5} frames {s}-{end}")
    print()

    if args.dry_run:
        print("dry run — nothing queued")
        return

    if capnote.startswith("NOT SET"):
        sys.exit("refusing to queue: the frame cap could not be set, chunks would be wrong")

    for i, s in enumerate(starts, 1):
        loader["inputs"]["skip_first_frames"] = s
        for nid, n in outputs:
            n["inputs"]["filename_prefix"] = f"{args.prefix}_{i:02d}"
        body = json.dumps({"prompt": wf}).encode()
        req = urllib.request.Request(f"{args.server}/prompt", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                pid = json.load(r).get("prompt_id", "?")
            print(f"  queued {i}/{len(starts)}  skip={s:<5} prompt_id={pid}")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:400]
            sys.exit(f"\nComfyUI rejected chunk {i}: {e.code}\n{detail}")
        except urllib.error.URLError as e:
            sys.exit(f"\ncannot reach {args.server}: {e.reason}")

    print(f"\n{len(starts)} chunks queued. Watch progress in the ComfyUI queue.")
    print(f"Outputs land as {args.prefix}_01, {args.prefix}_02, ... in the output dir.")


if __name__ == "__main__":
    main()
