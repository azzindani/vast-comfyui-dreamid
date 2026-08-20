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
git clone https://github.com/YOURNAME/vast-comfyui-dreamid
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
| `env` | `tmux` + `ffmpeg`, sets `HF_HOME`, creates directories |
| `node` | Clones the DreamID-V wrapper, installs its deps **plus the ones it forgets** |
| `models` | Downloads the three model files (~18 GB) and applies the required rename |
| `restart` | `supervisorctl restart comfyui`, then greps the log to confirm the node loaded |

Run a single phase if you need to:

```bash
./setup.sh verify
./setup.sh models
./setup.sh restart
```

**Safe to re-run.** Clones and downloads are skipped when already present, with
file-size checks to catch truncated downloads.

---

## Health check

```bash
./scripts/health.sh
```

Reports torch and CUDA, GPU memory, disk, model presence, attention backend,
supervisor services, listening ports, and whether the node imported.

Worth running before any long render.

---

## Choosing an instance

| Setting | Value | Why |
|---|---|---|
| GPU | RTX 4090 24 GB | DreamID-V ~16 GB, LatentSync ~18 GB — they run sequentially |
| Disk | **100–200 GB** | **Not resizable after launch** |
| Reliability | > 99 % | Host-specific on vast, not platform-wide |
| Internet | > 500 Mbps down | You pay GPU rates while pulling 18 GB |
| Type | On-demand | Interruptible gets killed mid-render |
| Host | Verified | Unverified hosts advertise 1500 Mbps and deliver 100 |
| Template | Official **ComfyUI** | Ships CUDA, supervisor, Caddy, Jupyter, SSH |

Sort by **DLPerf**, not price — the same GPU model varies with cooling and power delivery.

### Three ways to lose money

1. **Disk is not resizable.** Running out mid-download means destroying and starting over.
2. **Stopped ≠ free.** Storage bills continuously while the instance *exists*. **Destroy** it when finished, don't just stop it.
3. **A slow host costs more than a pricier fast one.** 18 GB at 100 Mbps is ~25 minutes of paid GPU time.

---

## Gotchas this repo handles for you

These are the four things that actually cost time, none of which appear in any
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

---

## Attention backend — leave it alone

The wrapper wraps `flash_attn` / `sageattention` imports in
`try/except ModuleNotFoundError` and falls back to **SDPA**. Nothing breaks
from their absence.

**Do not install them.** No cu130 prebuilt wheels exist, and building
flash-attn from source costs 30–60 minutes of paid GPU time for maybe 10–20 %
on a job measured in minutes. SDPA in torch 2.10 is well optimised.

If a node exposes an attention dropdown, set it to `sdpa` explicitly rather
than `auto`.

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

## Running a swap

You need two files in `/workspace/ComfyUI/input/`:

1. **Source face** — one restored photo, frontal, ≥512 px
2. **Target clip** — the shot to swap into

Load the wrapper's example workflow:

```bash
find /workspace/ComfyUI/custom_nodes/Comfyui_DreamID-V_wrapper -name "*.json"
```

**Always test on a throwaway 2-second clip first.** You are validating that the
pipeline runs end to end — resolution, VRAM, output format. A failed
18-second render wastes far more than a failed 2-second one.

---

## Not yet verified

The following are planned but **have not been run**, so treat them as untested:

- **LatentSync 1.6** lip-sync pass (~18 GB VRAM)
- **VoxCPM2** voice cloning — runs on a local 8 GB laptop, not this box
- **CodeFormer + Real-ESRGAN** enhancement pass

Add them to `setup.sh` once confirmed working, rather than assuming.

---

## Reference

```bash
# health
./scripts/health.sh

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
