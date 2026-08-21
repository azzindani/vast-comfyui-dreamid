# Recipes

Copy one block, run it, work. Each section is self-contained — nothing here
depends on you having read the section above it.

For *what each task is* and which tool does it, see
[`taxonomy.md`](taxonomy.md). This file is the doing.

---

## Once per box

```bash
cd /workspace
git clone https://github.com/azzindani/vast-comfyui-dreamid
cd vast-comfyui-dreamid
chmod +x setup.sh scripts/*.sh
./setup.sh verify && ./setup.sh env && ./setup.sh pin
```

`verify` aborts before anything expensive if torch, GPU or disk are wrong.
`pin` records the current torch/numpy so no node install can move them.

Then pick a pipeline below.

---

## Face swap — put someone's face in existing footage

```bash
./setup.sh profile faceswap
./setup.sh models
./setup.sh enhance
./setup.sh paths
```

Upload a source photo and a clip, then:

```bash
python scripts/make-refs.py /workspace/ComfyUI/input/face.jpg
```

Writes four references — tight and wide crops, each mirrored — into the input
dir. Wire them into `ImageConcatMulti`. **Hit Refresh in the browser** or the
dropdown won't list them.

**Settings that matter**

| | Value | Why |
|---|---|---|
| Resampling | `lanczos` | `nearest-exact` aliases the plate and wrecks the mask |
| Frames | `81` | The trained window. Not a memory limit |
| Resolution | `640x640` on a face crop | More face pixels than 848×480 at the same cost |
| CFG | `7.0` | Identity adherence. Above ~8 goes contrasty |
| Steps | `30` | 20 is fine under a grain grade |
| `save_output` | **ticked** | Otherwise it lands in `temp/` and is wiped on restart |
| CRF | `12` | This is an intermediate, not a delivery |

**Clips longer than 81 frames**

```bash
# Workflow > Export (API) first — the normal save is UI format
python scripts/queue-chunks.py /workspace/workflow_api.json --dry-run
python scripts/queue-chunks.py /workspace/workflow_api.json
```

Plans overlapping chunks and queues them all. Omit `--total` and it probes the
clip, accounting for `force_rate`.

> **Cut at shot boundaries instead where you can.** A cut is a free seam — no
> dissolve, no overlap, and each piece may fit in one pass.

---

## Only have one photo of someone

```bash
./setup.sh profile identity
```

PuLID conditions identity from a single image with **no training**, so you can
generate the varied angles a swap model wants:

1. Load the photo → PuLID → generate frontal, 3/4 left, 3/4 right, varied light
2. Check every generated view against the real photo, discard drifters
3. Feed the survivors **plus the real photo** into the swap's reference stack

> **Keep the real photo in the stack.** Synthetic error is *systematic* — if
> the model's jaw is slightly wrong, every generated view is wrong the same
> way, and a stack of consistently-wrong views reads as truth.

With 15–30 real photos, train a LoRA instead — better identity, and it can
also restore a soft photo toward *that person* rather than a generic face.

---

## Video editing — remove an object, inpaint, outpaint, restyle

```bash
./setup.sh profile videoedit
```

Object removal, end to end:

1. `VHS_LoadVideo` → load the plate
2. **SAM2** → click the object, propagate the mask across frames
3. Grow and feather the mask — a tight mask leaves halos
4. **VACE inpaint** → fill the region
5. Composite back, match grain

The mask is the whole job. Budget your time there, not on sampler settings.

> **Outpainting changes aspect ratio** — 4:3 archival to 16:9 delivery without
> cropping the subject. Often more useful than removal.

---

## Video creation — make a shot that was never filmed

```bash
./setup.sh profile videogen
```

**Prefer image-to-video over text-to-video.** Generate a still first, get the
composition and identity right where iteration is cheap, then animate it. The
still anchors everything text-to-video has to guess.

For length, use **extension** — condition the next window on the previous
window's last frame — rather than one long pass. Continuity gets generated
instead of dissolved.

> Generation is at its best as an **element source**: fire, smoke, crowds,
> impossible camera moves. Composite those into a real plate rather than
> generating the whole shot.

---

## Restore and upscale footage

```bash
./setup.sh profile restore
```

**Order is not negotiable:**

```
downscale (if needed) → SeedVR2 restore → RIFE interpolate → encode
```

Interpolating first propagates artifacts into every frame you invent.

- **SeedVR2** — diffusion restore with temporal consistency. Use for real footage.
- **RealESRGAN** — per-frame, fast, no temporal awareness. Fine under grain.
- **RIFE** — use for **slow motion**, not 60fps. 24fps reads as cinema; 60 reads as video.

> Generate 81 frames, interpolate 4×, retime to 25% speed. Smooth slow-mo out
> of a short generation — the best trick available given the frame window.

---

## Image editing

```bash
./setup.sh profile imageedit
```

- **Instruction editing** — "remove the car", no mask needed
- **Inpaint-CropAndStitch** — inpaints at full resolution on a crop, then stitches back. Same "spend your pixels on the subject" principle as video
- **controlnet_aux** — depth, pose, canny, normals for controlled generation
- **RMBG** — background removal and segmentation

> **Matting ≠ segmentation.** Segmentation gives a binary mask. Matting gives
> soft alpha, which is what hair and motion blur need to composite believably.

---

## 3D from an image

```bash
./setup.sh profile threed
```

**Install this on its own box.** 3D-Pack has the heaviest dependencies here and
is the most likely to fight another profile's pins.

- **Image → mesh** when you need geometry to light, rig or print
- **Image → gaussian splat** when you only need new camera angles
- **Depth / multi-view** feeds controlled video — useful even if you never ship a model

---

## Audio

```bash
./setup.sh profile audio
```

- **Voice cloning** — 3–30 seconds of reference is enough
- **Stem separation** — pull dialogue out of a mixed track before cloning
- **ACE-Step** — music generation, native nodes

> **Lip sync is usually unnecessary.** If your swap preserves the original
> mouth movement and you keep the source audio, sync is free. You need lip sync
> only when replacing the dialogue.

---

## What a profile downloads

`profile` installs nodes **and** the weights that profile needs, with a disk
check and a warning first — vast bills bandwidth per GB.

| Profile | Pre-downloaded | Size |
|---|---|---|
| `videoedit` | Wan 2.1 VACE 1.3B + encoder + VAE | ~11 GB |
| `videogen` | Text encoder + VAEs only — pick your own checkpoint | ~8 GB |
| `restore` | SeedVR2 3B fp8 + VAE | ~4 GB |
| `faceswap` | via `./setup.sh models` + `enhance` | ~19 GB |
| `identity` `imageedit` `threed` `audio` | nothing — those nodes fetch weights on first use | — |

**VACE starts at 1.3B on purpose.** The 14B is 34.7 GB and Wan 2.2's fun-vace
needs *both* noise halves at ~17 GB each. The pipeline is identical either way —
learn on the small one, then swap the checkpoint.

---

## Changing things mid-session

You do not have to rebuild to add a tool.

```bash
./setup.sh add https://github.com/user/SomeNode   # clone, install, restart, verify
./setup.sh add videoedit                          # add a whole profile, additively
./setup.sh disable ComfyUI-3D-Pack                # skip it without uninstalling
./setup.sh enable  ComfyUI-3D-Pack
```

`add` restarts and then **reads the log to tell you whether it actually
imported** — a clone that succeeds tells you nothing.

Node requirements install under `constraints.txt`, so a node that would
downgrade torch is refused and says so. Its dependencies get skipped rather
than breaking the environment.

**Refresh the browser tab after any add** — the node list is cached at page load.

---

## When something breaks

```bash
./setup.sh doctor
```

Verifies every model is present and not truncated, re-downloads what is
missing, restarts, reads only the **new** log lines, installs whatever failed
to import, and repeats up to five rounds. Aborts if any install moves torch.

```bash
./scripts/health.sh          # full diagnostic
./scripts/queue-status.sh    # ten lines, phone-sized
```

**Where did my render go?**

```bash
./setup.sh paths
```

Lists everything written in the last two hours. If it's in `temp/`, the node is
the cause: `PreviewImage` always writes there, and `VHS_VideoCombine` does
unless `save_output` is ticked.

---

## Working from a phone

Prepare while you still have a keyboard: settle the workflow settings and
**Workflow → Export (API)**, then park it somewhere stable. Exporting API
format on a touchscreen is miserable.

```bash
cd /workspace/vast-comfyui-dreamid && git pull
python scripts/queue-chunks.py /workspace/workflow_api.json
./scripts/queue-status.sh
```

Renders run server-side, so a dropped connection kills only your shell.

---

## Cost discipline

| | |
|---|---|
| **Destroy between sessions** | Storage bills while the instance exists — ~$1.44/day for nothing |
| **Pick a $0.00/GB bandwidth host** | The 18 GB pull is otherwise a real charge, twice |
| **One profile per box** | Small installs, no conflicts, minutes to rebuild |
| **Rebuild, don't repair** | `setup.sh` is 5 minutes. A broken env is a weekend |
