#!/usr/bin/env python3
"""
Build a reference stack from a single photo.

Diffusion face swap conditions on a set of reference views, not one image. When
you only have one photo you cannot produce genuine 3/4 angles, but you can give
the encoder the face at two scales and mirrored -- which is what identity
encoders are trained with as augmentation, and is measurably better than
feeding the same crop four times.

    python scripts/make-refs.py photo.jpg

Writes ref_1..ref_4 into ComfyUI's input directory and prints them in the order
to wire into ImageConcatMulti.

Everything runs locally. No image leaves the machine.
"""

import argparse
import os
import subprocess
import sys

from PIL import Image

# How far to expand the detected face box. Tight is roughly eyebrows-to-chin
# filling the frame; wide includes hairline and shoulders. The pair gives the
# encoder both facial detail and head shape.
TIGHT = 1.6
WIDE = 2.7
OUT_PX = 512


def comfy_input_dir():
    """ComfyUI's real input dir, read off the running process rather than assumed."""
    try:
        ps = subprocess.run(["ps", "aux"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        ps = ""
    for line in ps.splitlines():
        if "main.py" in line and "--input-directory" in line:
            parts = line.replace("=", " ").split()
            i = parts.index("--input-directory")
            if i + 1 < len(parts):
                return parts[i + 1]
    for guess in ("/workspace/ComfyUI/input", os.path.expanduser("~/ComfyUI/input")):
        if os.path.isdir(guess):
            return guess
    return os.getcwd()


def detect_face(img):
    """Return (cx, cy, size) of the face box, or None if detection is unavailable."""
    try:
        import mediapipe as mp
        import numpy as np
    except ImportError:
        return None

    rgb = np.asarray(img.convert("RGB"))
    with mp.solutions.face_detection.FaceDetection(
        model_selection=1, min_detection_confidence=0.5
    ) as fd:
        res = fd.process(rgb)

    if not res.detections:
        return None

    # Largest detection, in case someone else is in the frame.
    best = max(res.detections, key=lambda d: d.location_data.relative_bounding_box.width)
    box = best.location_data.relative_bounding_box
    cx = (box.xmin + box.width / 2) * img.width
    cy = (box.ymin + box.height / 2) * img.height
    return cx, cy, max(box.width * img.width, box.height * img.height)


def square_crop(img, cx, cy, size):
    """Square crop clamped inside the image, shrinking rather than padding."""
    size = int(min(size, img.width, img.height))
    x = max(0, min(int(round(cx - size / 2)), img.width - size))
    y = max(0, min(int(round(cy - size / 2)), img.height - size))
    return img.crop((x, y, x + size, y + size))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("photo")
    ap.add_argument("-o", "--out", help="output dir (default: ComfyUI input dir)")
    ap.add_argument("--prefix", default="ref", help="output filename prefix")
    ap.add_argument("--no-flip", action="store_true",
                    help="skip mirrored variants (use for a strongly asymmetric face)")
    args = ap.parse_args()

    if not os.path.isfile(args.photo):
        sys.exit(f"not found: {args.photo}")

    img = Image.open(args.photo).convert("RGB")
    print(f"source: {img.width}x{img.height}")

    face = detect_face(img)
    if face:
        cx, cy, fsize = face
        print(f"face detected: {int(fsize)}px wide at ({int(cx)}, {int(cy)})")
    else:
        cx, cy = img.width / 2, img.height / 2
        fsize = min(img.width, img.height) / 2.2
        print("no face detected (mediapipe missing or no match) — using centre crop")
        print("  check the output files before using them")

    variants = [("tight", TIGHT), ("wide", WIDE)]
    outdir = args.out or comfy_input_dir()
    os.makedirs(outdir, exist_ok=True)

    written, n = [], 0
    for label, factor in variants:
        crop = square_crop(img, cx, cy, fsize * factor)
        native = crop.width
        crop = crop.resize((OUT_PX, OUT_PX), Image.LANCZOS)

        flips = [("", crop)] if args.no_flip else [
            ("", crop), ("_flip", crop.transpose(Image.FLIP_LEFT_RIGHT))
        ]
        for suffix, im in flips:
            n += 1
            path = os.path.join(outdir, f"{args.prefix}_{n}_{label}{suffix}.png")
            im.save(path)
            written.append(path)
            note = "" if native >= OUT_PX else f"  (upscaled from {native}px — source is soft)"
            print(f"  {os.path.basename(path)}{note}")

    print(f"\nwritten to {outdir}")
    print("Hit Refresh in the ComfyUI menu, then wire these into ImageConcatMulti")
    print("in the order listed above.")
    if not args.no_flip:
        print("\nIf your friend has a distinctive one-sided feature (mole, scar, parting),")
        print("re-run with --no-flip — a mirrored version teaches the model the wrong side.")


if __name__ == "__main__":
    main()
