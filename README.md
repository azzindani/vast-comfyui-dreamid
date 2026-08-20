# vast-comfyui-dreamid

One-command provisioning for **DreamID-V** video face-swap on a **vast.ai ComfyUI** instance.

Rent a box, clone this, run one script. Everything that cost time the first
time round — the wrong tunnel port, the supervisor conflict, the renamed model
file, the missing dependencies — is handled here.

Built for AI video editing work: temporally consistent face replacement on
video clips, with the lip-sync and enhancement passes as planned extensions.

---

## Quick start

**1. Rent the instance** — see [Choosing an instance](#choosing-an-instance) below.

**2. Connect** (from Windows, edit the defaults in `connect.ps1` first):

```powershell
.\connect.ps1
```

**3. On the instance:**

```bash
cd /workspace
git clone https://github.com/azzindani/vast-comfyui-dreamid
cd vast-comfyui-dreamid
chmod +x setup.sh scripts/*.sh
./setup.sh
```

Roughly 15–25 minutes, mostly the 11 GB text encoder download.

**4. Open** `http://localhost:8188`

---

## What `setup.sh` does

| Phase | Action |
|---|---|
| `verify` | Aborts unless torch ≥ 2.4, a GPU is visible, and ≥60 GB is free |
| `env` | `tmux` + `ffmpeg` + `curl`, sets `HF_HOME`, creates directories |
| `nodes` | Clones all four custom nodes, installs deps **plus the ones they forget** |
| `models` | DreamID-V weights (~18 GB), with the required rename applied |
| `enhance` | Face restore, upscalers, RIFE interpolation (~1 GB) |
| `restart` | `supervisorctl restart comfyui`, then greps the log to confirm nodes loaded |
| `paths` | Resolves the real input/output dirs, links them to `/workspace`, lists recent renders |
| `doctor` | **Finds and fixes** missing models and failed imports |
| `wan` | **Optional, not in `all`** — Wan 2.2 Animate (~20 GB more) |

Run a single phase if you need to:

```bash
./setup.sh verify
./setup.sh models
./setup.sh enhance
./setup.sh restart
```

## Refreshing an existing install

After a `git pull`, or when a node turns out to be missing. Which one you want
depends on whether you can afford a restart — ComfyUI caches the ~18 GB of
model weights in the running process, and a restart costs ~90 seconds to
reload them.

**Without restarting** — clones new nodes, installs missing packages, leaves
the running process alone:

```bash
cd /workspace/vast-comfyui-dreamid && git pull && ./setup.sh nodes
```

Use this mid-session. Anything imported at *render* time (`decord`) takes
effect on your next queued prompt with no restart at all.

**With a restart** — adds model verification and the auto-heal loop:

```bash
cd /workspace/vast-comfyui-dreamid && git pull && ./setup.sh doctor
```

Required for newly cloned nodes to appear in the UI, since custom nodes only
register at startup.

> If a render is queued or your models are still hot, run `nodes` and keep
> working. Save `doctor` for a moment when a restart is cheap.

## What gets installed

| | Purpose |
|---|---|
| **DreamID-V** | Video face swap — diffusion-based, so no frame-to-frame flicker |
| **VideoHelperSuite** | Video load/combine, plus the inline player on the output node |
| **KJNodes** | Not a DreamID-V dependency, but its example workflow is built from these |
| **facerestore_cf** | CodeFormer / GFPGAN for cleaning up low-res source photos |
| **Frame-Interpolation** | RIFE — smooth slow-motion without retiming judder |
| **Upscalers** | RealESRGAN x2/x4 and 4x-UltraSharp (ComfyUI's nodes are native) |

**Safe to re-run.** Clones and downloads are skipped when already present, with
file-size checks to catch truncated downloads.

---

## When something breaks

```bash
./setup.sh doctor
```

Does the diagnosing *and* the fixing:

1. Verifies every expected model is present and not truncated; re-downloads any that aren't (skipping the ones already there)
2. Restarts ComfyUI, reads only the **new** log lines, `pip install`s whatever failed to import, and repeats — up to 5 rounds
3. Aborts if any install downgrades torch
4. Prints the real input/output paths

This automates the loop where node `requirements.txt` files are incomplete and
each missing module only surfaces one restart at a time.

Import names are mapped to pip names where they differ (`cv2` →
`opencv-python`, `skimage` → `scikit-image`, and so on).

## Health check

```bash
./scripts/health.sh
```

Read-only. Reports torch and CUDA, GPU memory, disk, model presence, attention
backend, supervisor services, listening ports, the real I/O paths, and anything
written in the last hour.

Worth running before any long render. Use `doctor` when you want it fixed
rather than just reported.

For a quick "is it still going?" — ten lines, sized for a phone screen:

```bash
./scripts/queue-status.sh
```

Queue depth, GPU utilisation, the last five renders, disk free.

---

## Choosing an instance

| Setting | Value | Why |
|---|---|---|
| GPU | RTX 4090 24 GB (480p) · 5090 32 GB (720p) | More VRAM buys **resolution, not longer clips** — 81 frames is Wan's training window, not a memory limit. See [Resolution and VRAM](#resolution-and-vram) |
| Disk | **100–200 GB** | **Not resizable after launch** |
| Reliability | > 99 % | Host-specific on vast, not platform-wide |
| Internet | > 500 Mbps down | You pay GPU rates while pulling 18 GB |
| Type | On-demand | Interruptible gets killed mid-render |
| Host | Verified | Unverified hosts advertise 1500 Mbps and deliver 100 |
| Template | Official **ComfyUI** | Ships CUDA, supervisor, Caddy, Jupyter, SSH |

Sort by **DLPerf**, not price — the same GPU model varies with cooling and power delivery.

### Three ways to lose money

1. **Disk is not resizable.** Running out mid-download means destroying and starting over.
2. **Stopped ≠ free.** Storage bills continuously while the instance *exists*. When the project is **finished**, destroy it — a stopped instance you forget about bills indefinitely. Mid-project, see [Leaving it overnight](#leaving-it-overnight) below; stopping is usually right there.
3. **A slow host costs more than a pricier fast one.** 18 GB at 100 Mbps is ~25 minutes of paid GPU time.

### Leaving it overnight

Rough figures for a 24 GB box at ~$0.31/hr GPU + ~$0.06/hr storage, over ~14 hours:

| | Cost | Next morning |
|---|---|---|
| Keep running | ~$5.20 | Instant, models still in VRAM |
| **Stop** | ~$0.90 | Restart in ~2 min — **if the GPU is still free** |
| Destroy | $0 | Re-download ~18 GB, ~30 min plus bandwidth charges |

**Stopping is usually right** — you keep the disk and every model for under a
dollar.

The catch: a stopped instance releases the GPU back to the host, and if someone
else rents it you wait. On a deadline, paying the extra ~$4 to keep it running
is cheap insurance. **Destroying is the one to avoid** — it costs bandwidth
charges *and* half an hour you may not have.

---

## Gotchas this repo handles for you

These are the things that actually cost time, none of which appear in any
published guide.

### 1. Tunnel to 18188, not 8188

The template runs **Caddy** on `*:8188`, reverse-proxying to **ComfyUI** on
`127.0.0.1:18188`. Vast's suggested `-L 8080:localhost:8080` is wrong, and
tunnelling to 8188 lands you on Caddy's auth prompt.

```
ssh -p PORT root@HOST -L 8188:localhost:18188
```

`connect.ps1` does this for you.

### 2. Never run `python main.py`

ComfyUI is supervisor-managed. Launching it by hand gives
`Port 8188 is already in use`, and supervisor will restart its own copy
underneath you anyway.

```bash
supervisorctl restart comfyui
```

Custom nodes only load at startup, so every install needs a restart.

### 3. The model needs renaming

The Wan repo ships `models_t5_umt5-xxl-enc-bf16.pth`; the wrapper expects
`umt5-xxl-enc-bf16.pth`. `setup.sh` renames it.

### 4. `requirements.txt` is incomplete

Missing at minimum `easydict` and `diffusers`, and they surface one at a time
across separate restarts. `setup.sh` installs the full set up front:

```
easydict diffusers transformers accelerate sentencepiece ftfy
omegaconf einops imageio-ffmpeg av
```

### 5. `decord` fails *mid-render*, not at startup

The sampler does `from decord import VideoReader` inside `generate()`, not at
module load. So a missing `decord` passes every startup check, loads all 18 GB
of weights, and *then* throws — about 90 seconds into a render.

`setup.sh` installs it during `nodes` and verifies it in `doctor`. Because the
import is lazy, installing it needs **no restart** — just re-queue.

### 6. A half-finished clone reads as "installed"

An interrupted `git clone` leaves a `.git` directory with no `__init__.py`.
Every "is it already installed?" check that looks for the directory says yes,
and the node stays permanently broken. `setup.sh` checks for `__init__.py` and
re-clones when it's missing.

---

## Where your files go

ComfyUI reads and writes under its own directory — `/workspace/ComfyUI/input`
and `/workspace/ComfyUI/output`, not the workspace root. `./setup.sh paths`
symlinks `/workspace/input` and `/workspace/output` to the real locations so
either path works, and lists everything written in the last two hours.

A render that seems to have vanished is almost always in `temp/`:

| Node | Writes to |
|---|---|
| `SaveImage` | `output/` |
| `PreviewImage` | `temp/` — it's a preview, not a save |
| `VHS_VideoCombine` | `output/` **only if `save_output` is ticked**, else `temp/` |

`temp/` is wiped on every ComfyUI restart, so a render left there disappears
the next time `doctor` runs.

Also: after `scp`-ing into the input dir, hit **Refresh** in the ComfyUI menu
or the `LoadImage` dropdown won't list the file. The list is cached.

---

## Attention backend

The wrapper wraps `flash_attn` / `sageattention` imports in
`try/except ModuleNotFoundError` and falls back to **SDPA**, so nothing breaks
if they're absent.

**Don't build them from source.** No cu130 prebuilt wheels exist for
flash-attn, and compiling costs 30–60 minutes of paid GPU time for maybe
10–20 % on a job measured in minutes. SDPA in torch 2.10 is well optimised.

Some vast templates *do* ship `sageattention`, in which case the wrapper picks
it automatically and the log reads:

```
Setting attention mode: sageattn
Available backends - Flash Attn: False, SageAttn: True
```

That's fine — sage is meaningfully faster. But if a render fails **inside the
sampling loop** with a shape or kernel error, set the sampler's attention
dropdown to `sdpa` and re-queue. Don't pre-emptively switch.

---

## Files not to download

| File | Why |
|---|---|
| `diffusion_pytorch_model.safetensors` | Base Wan model — `dreamidv.pth` replaces it |
| `dreamidv_faster.pth` | Lower-VRAM variant. Only if you hit OOM |
| `dw-ll_ucoco_384.onnx`, `yolox_l.onnx` | DWPose files for ByteDance's *original* implementation. TTPlanet's wrapper uses mediapipe instead |

---

## Moving files

```powershell
.\scripts\upload.ps1 -Push C:\video\face.jpg
.\scripts\upload.ps1 -Push C:\video\test2s.mp4
.\scripts\upload.ps1 -Pull result.mp4 -To C:\Users\me\Videos
```

Or plain `scp` — note the **capital** `-P` for port:

```powershell
scp -P 12345 file.mp4 root@HOST:/workspace/ComfyUI/input/
```

---

## Restoring source photos first

DreamID-V builds identity from the source image, so a soft photo yields a soft
identity no matter how good the video is. The `enhance` phase installs
CodeFormer and GFPGAN so this happens **on your own box** — no faces sent to a
third-party web tool.

Three nodes:

```
Load Image → FaceRestoreCFWithModel → Save Image
                    ↑
         FaceRestoreModelLoader (codeformer.pth)
```

- **facedetection:** `retinaface_resnet50`
- **codeformer_fidelity:** run at `0.5` and `0.7`, compare both

**Keep whichever still unmistakably looks like the person.** Lower fidelity is
sharper but drifts toward a generic face — sharp and wrong is worse than soft
and right.

> Worth trying the raw photo on a test clip first. DreamID-V has its own
> identity encoder and may handle a soft source better than expected.

### When you only have one photo

The model conditions on a *set* of reference views. One image is the weakest
possible conditioning, and the usual symptom is an output that reads as a
plausible face but not as **that** person.

```bash
python scripts/make-refs.py /workspace/ComfyUI/input/friend.jpg
```

Detects the face with mediapipe and writes four references — tight and wide
crops, each mirrored — straight into ComfyUI's input dir. Wire them into
`ImageConcatMulti` in the order printed.

Two scales plus mirroring is what identity encoders see as training
augmentation, so it beats feeding the same crop four times. It is not as good
as genuine 3/4 angles, but it is what one photo can give you.

Use `--no-flip` if the person has a distinctive one-sided feature — a mole,
scar or hair parting — since a mirrored copy teaches the model the wrong side.

## Upscaling the output

DreamID-V renders at 480p or 720p. If your plate is 1080p, the swapped clip
comes back smaller than the footage around it.

`RealESRGAN_x2plus.pth` and `RealESRGAN_x4plus.pth` are downloaded to
`models/upscale_models/`. **No custom node needed** — ComfyUI ships the nodes:

```
VHS_VideoCombine ← Upscale Image (using Model) ← [sampler output]
                              ↑
                   Load Upscale Model (RealESRGAN_x2plus)
```

720p × 2 gives 1440p; let your editor scale down to 1080p. Upscaling past the
target and then reducing beats going straight to it.

> ### Match the plate, don't beat it
>
> A swapped face sharper than the footage around it is the classic tell. If
> your surrounding shots are soft, **the swap should be soft too**. Upscaling
> here is about matching resolution, not adding detail.
>
> If you're grading to grain, you may not need this at all — let the editor
> scale it and let grain cover the difference.

## Running a swap

You need two files in `/workspace/ComfyUI/input/`:

1. **Source face** — restored photo, frontal, ≥512 px
2. **Target clip** — the shot to swap into

Load the wrapper's example workflow:

```bash
find /workspace/ComfyUI/custom_nodes/Comfyui_DreamID-V_wrapper -name "*.json"
```

**Always test on a throwaway 2-second clip first.** You are validating that the
pipeline runs end to end — resolution, VRAM, output format. A failed
18-second render wastes far more than a failed 2-second one.

### Resolution and VRAM

Dimensions must be **divisible by 16** — the VAE downsamples 8× and the
transformer patches 2×. Stay near a trained resolution too; Wan 2.1 was trained
at 480p and 720p, and drifting far from those degrades quality regardless of
available memory.

| Resolution | Pixels | Cost vs. 848×480 | Use for |
|---|---|---|---|
| 848×480 | 407k | 1× | 16:9 default |
| 480×848 | 407k | 1× | vertical crop |
| **640×640** | 410k | 1× | **square face crops** |
| 480×640 | 307k | 0.75× | portrait head-and-shoulders |
| 1280×720 | 922k | ~2.3× | 720p |

**Measured: 720p at 81 frames peaks at ~28 GB** on a card large enough to keep
everything resident.

That figure is an upper bound, not a floor. On a smaller card ComfyUI offloads
the ~11 GB text encoder once prompt encoding is done, so peak during sampling
comes out **well below** 28 GB. A 32 GB card is comfortable at 720p; 24 GB is
plausible but worth testing rather than assuming.

> **Ask what fraction of the pixels is face, not what resolution is best.**
> A tight 640×640 crop beats a loose 1280×720 frame — more face detail, more
> mask resolution to feather across, and 45 % of the compute. Crop the plate
> to the face, swap, composite back over the untouched original.

### Clips longer than the frame window

Wan-family models have a fixed window — **81 frames**, about 3.4 seconds at
24fps. Anything longer renders in passes.

Keep frame counts to **4n+1** (41, 61, 81). The VAE compresses time 4×, so
other counts get padded or rejected, and padded tail frames come back mangled.

Rather than editing `skip_first_frames` by hand for each pass:

```bash
# Workflow > Export (API) in ComfyUI first — the normal save is UI format

python scripts/queue-chunks.py workflow_api.json --total 216 --dry-run
python scripts/queue-chunks.py workflow_api.json --total 216
```

Plans overlapping chunks, sets the frame cap (following a link to an
`INTConstant` if one drives it), and queues them all with per-chunk output
prefixes. Omit `--total` to probe the clip with ffprobe.

Chunks are spaced **evenly** rather than stepped-and-clamped, so you never pay
for a final pass that overlaps its predecessor almost entirely. The default
13-frame overlap gives you something to cross-dissolve across — without it,
every join is a hard cut that pops.

> **Cuts are free seams.** If a long shot contains an edit, split there instead
> of chunking through it. Each piece may then fit in a single pass.

> **Audio: use one unbroken track.** Let the chunks render silent and lay the
> original clip's audio under the joined result in your editor. DreamID-V
> preserves the actor's mouth movement, so it stays in sync — and you avoid
> accumulating offsets across three separate sync points.

---

## Wan 2.2 Animate — optional

```bash
./setup.sh wan
```

A different tool for the same job. DreamID-V replaces the **face region**;
Wan Animate **regenerates the whole person** from a reference image and matches
scene lighting, using a relight LoRA. Better identity from a single photo, but
slower, pricier, and it can drift on costume detail.

Deliberately excluded from `all` — it's ~20 GB on top of DreamID-V's 18 GB, and
**vast bills bandwidth separately from the $/hr**. Only run it if you actually
want the comparison.

Uses the int8 build rather than bf16 — roughly half the size, fits 24 GB
comfortably.

---

## Working from a phone

Perfectly workable — renders run server-side, so the phone is only a remote
control. But two things are genuinely painful on a touchscreen, so do them
before you leave a desktop.

### Prepare while you still have a keyboard

**1. Settle the workflow settings.** Resampling method, frame count, CRF,
resolution — anything you'd have to hunt for in a node graph.

**2. Export as API format** (`Workflow > Export (API)`) and park it somewhere
stable:

```bash
mv ~/Downloads/*.json /workspace/workflow_api.json
```

This is the step that *must* happen in advance — `queue-chunks.py` needs API
format, and exporting it from a phone is miserable.

**3. Upload every clip and source image**, while the connection is good.

### The whole loop, from a phone

```bash
cd /workspace/vast-comfyui-dreamid && git pull

python scripts/queue-chunks.py /workspace/workflow_api.json --total 216 --dry-run
python scripts/queue-chunks.py /workspace/workflow_api.json --total 216

./scripts/queue-status.sh
```

Three commands, no graph editing.

> **Renders survive a dropped connection.** ComfyUI is supervisor-managed and
> the queue lives server-side — close the browser, lose signal, pocket the
> phone. Only your *shell* dies, which is why long shell commands belong in
> `tmux`.

### Terminal

**Termux** (free, F-Droid) beats Jupyter's terminal — it has a real Ctrl / Esc /
arrow row, which Android's keyboard does not:

```bash
pkg install openssh
ssh -p PORT root@HOST
```

**Termius** or **JuiceSSH** are easier to set up if you'd rather tap than type.

Jupyter still wins for one thing: **downloading files**. Its file browser lets
you tap a render in `output/` and save it straight to the phone.

### Viewing ComfyUI

Open the vast portal link in the browser — that's Caddy on 8188 with the token,
so no SSH tunnel is needed. Good for watching the queue and previewing output.
Don't try to rewire nodes on a touchscreen.

---

## Not yet verified

Planned but **not run**, so treat as untested:

- **LatentSync 1.6** lip-sync pass (~18 GB VRAM)
- **VoxCPM2** voice cloning — belongs on a local machine, not this box

> **You may not need lip-sync at all.** DreamID-V preserves the original
> actor's mouth movements, so keeping the source clip's audio gives you perfect
> sync for free. Lip-sync is only required if you replace the dialogue.

---

## Reference

```bash
# health
./scripts/health.sh          # full diagnostic
./scripts/queue-status.sh    # ten lines, phone-sized

# services
supervisorctl status
supervisorctl restart comfyui
tail -f /var/log/portal/comfyui.log

# tmux
tmux attach -t work        # reattach
# Ctrl+B then D            # detach

# space — check before big renders
df -h /workspace
```

| Port | What |
|---|---|
| `18188` | ComfyUI — **tunnel to this** |
| `8188` | Caddy reverse proxy (portal auth) |
| `18288` | comfyui-api-wrapper |

**Destroy the instance when you're done.** A stopped instance bills storage indefinitely.

---

See `notes/setup-runbook.md` for the full chronological walkthrough with the
original session's output.
