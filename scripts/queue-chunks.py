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


def locate(video):
    for d in ("/workspace/ComfyUI/input", os.getcwd()):
        path = video if os.path.isabs(video) else os.path.join(d, video)
        if os.path.isfile(path):
            return path
    return None


def probe_frames(video, force_rate):
    """(frames, description) for the clip as the loader will see it.

    force_rate resamples on load, so the frame count that matters is
    duration x force_rate, NOT the source frame count. A 25fps clip loaded at
    force_rate 24 yields fewer frames than it contains, and planning chunks
    off the source count sends the last pass past the end of the clip.

    Returns (None, reason) when it cannot be determined.
    """
    path = locate(video)
    if not path:
        return None, f"{video!r} not found"
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=r_frame_rate,nb_frames:format=duration",
             "-of", "json", path],
            capture_output=True, text=True, timeout=30).stdout
        d = json.loads(out)
        st = (d.get("streams") or [{}])[0]
        dur = float(d.get("format", {}).get("duration", 0)) or 0.0

        num, _, den = st.get("r_frame_rate", "0/1").partition("/")
        src_fps = float(num) / float(den or 1) if float(den or 1) else 0.0

        fps = force_rate if force_rate else src_fps
        if dur and fps:
            return round(dur * fps), f"{dur:.2f}s x {fps:g}fps"
        nb = int(st.get("nb_frames") or 0)
        if nb:
            return nb, f"{nb} frames in container"
        return None, "ffprobe gave no duration or frame count"
    except Exception as e:
        return None, f"ffprobe failed: {e}"


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

    video = loader["inputs"].get("video", "")
    force_rate = loader["inputs"].get("force_rate") or 0
    if isinstance(force_rate, list):
        force_rate = 0                       # driven by a link; fall back to source fps
    probed, why = probe_frames(video, force_rate)

    total = args.total or probed
    if not total:
        sys.exit(f"could not determine clip length ({why}) — pass --total FRAMES")

    # A --total larger than the clip is the usual reason chunking "does not
    # work": later passes start past the end and render nothing.
    if args.total and probed and abs(args.total - probed) > max(2, probed * 0.02):
        print(f"WARNING   --total {args.total} but the clip measures {probed} ({why})")
        if args.total > probed:
            print("          chunks past the end will come back empty or short")
        print()

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
    # Show what each pass actually adds. A chunk contributing a handful of new
    # frames costs a full render for almost nothing -- better seen than buried.
    thin = []
    for i, s in enumerate(starts, 1):
        end = min(s + args.frames, total) - 1
        new = min(s + args.frames, total) - (starts[i - 2] + args.frames) if i > 1 \
              else min(args.frames, total)
        mark = ""
        if i > 1 and new < args.frames * 0.25:
            mark, _ = "  <-- thin", thin.append((i, new))
        print(f"  {i}/{len(starts)}  skip={s:<5} frames {s}-{end}   +{new} new{mark}")
    print()
    for i, new in thin:
        print(f"NOTE      chunk {i} adds only {new} frame(s) for a full render pass;")
        print(f"          consider --overlap or trimming the clip instead")
    if thin:
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
