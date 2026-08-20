# Vast.ai + ComfyUI + DreamID-V — Setup Runbook

Working notes from the actual build. Every command here was run and verified on the instance; the gotchas are the ones we actually hit, not theoretical ones.

**Purpose:** temporally consistent face replacement on video clips, using DreamID-V under ComfyUI on rented GPU.

---

## 0. Reference build

What a known-good instance looked like at the end of setup. Use it to compare
against when something behaves differently.

| | |
|---|---|
| Instance | vast.ai, official ComfyUI template |
| Disk | 150 GB (26 GB used, 125 GB free) |
| Torch | `2.10.0+cu130` / CUDA 13.0 |
| ComfyUI | Running under supervisor, listening on `127.0.0.1:18188` |
| DreamID-V | ✅ Loaded — Model Loader, Pose Extractor, Sampler |
| Models | ✅ All three in place (~18 GB) |
| Next step | Upload a 2-second test clip + source face, load workflow, run |

---

## 1. Choosing the instance

### Target specs

| Setting | Value | Why |
|---|---|---|
| GPU | RTX 4090 24GB | DreamID-V ~16GB + LatentSync ~18GB, run sequentially |
| Disk | **100–200 GB** | **Not resizable after launch** |
| Reliability | > 99% | Host-specific on vast, not platform-wide |
| Internet | > 500 Mbps down | You pay GPU rates while pulling ~30GB of weights |
| Type | **On-demand**, not interruptible | Interruptible gets killed mid-render |
| Host | Verified | Unverified hosts advertise 1500 Mbps, deliver 100 |
| RAM | ≥ 32 GB | Video frames |
| Template | Official **ComfyUI** | Ships CUDA, Jupyter, SSH, supervisor, Caddy |

Sort by **DLPerf**, not price — same GPU model varies by cooling and power delivery.

### On the 5090 question

The old `sm_120` Blackwell compatibility problem (needing PyTorch nightly + cu128) is **obsolete on current images** — this template shipped torch 2.10 + cu130, which supports Blackwell fully.

The remaining argument for the 4090 is that this job is *tiny* (three clips, 46 s total). You are debugging-bound, not compute-bound. Take whichever has better bandwidth and reliability scores.

### Three ways to lose money

1. **Disk is not resizable.** Take 100 GB minimum, 150–200 GB if unsure.
2. **Stopped ≠ free.** Storage bills continuously while the instance *exists*. **Destroy**, don't stop, when finished.
3. **A slow host costs more than a pricier fast one.** 30 GB at 100 Mbps is ~40 min of paid GPU time.

---

## 2. Connecting from Windows

Windows has OpenSSH built in — no WSL needed.

### Generate a key

```powershell
ssh-keygen -t ed25519
Get-Content ~\.ssh\id_ed25519.pub | Set-Clipboard
```

Paste into **vast.ai → Account → Keys**.

### Connect — direct, not proxy

Direct is lower latency and much faster for `scp`. Only fall back to proxy if direct refuses.

```
ssh -p 12345 root@12.234.567.8 -L 8188:localhost:18188 -t "tmux attach -t work || tmux new -s work"
```

One command: connects, tunnels, reattaches tmux.

> ### ⚠️ The port gotcha
>
> Vast's default suggestion is `-L 8080:localhost:8080`. **That is wrong for ComfyUI.**
>
> The architecture is: **Caddy** listens on `*:8188` → reverse-proxies to **ComfyUI** on `127.0.0.1:18188`.
>
> Forward `8188:localhost:**18188**` to reach ComfyUI directly and skip Caddy's portal auth.

Save as a Windows Terminal profile: **Settings → Add a new profile → New empty profile**, paste the command as the command line.

The tunnel only exists while the SSH window is open. `http://localhost:8188` in the browser.

### File transfer

```powershell
# upload
scp -P 12345 C:\path\to\face.jpg root@12.234.567.8:/workspace/ComfyUI/input/

# download
scp -P 12345 root@12.234.567.8:/workspace/ComfyUI/output/result.mp4 C:\Users\you\Videos\
```

Capital `-P` for scp, lowercase `-p` for ssh.

---

## 3. Verify before downloading anything

```bash
python -c "import torch; print(torch.__version__, torch.version.cuda)"
nvidia-smi
df -h /workspace
```

Torch must be **≥ 2.4** (DreamID-V's hard requirement). GPU must be visible. Disk must be the size you paid for.

**Wrong on any of these → destroy and re-rent now**, not after 30 GB of downloads.

Observed on this build: `2.10.0+cu130 13.0` ✅

---

## 4. Environment setup

```bash
tmux new -s work
apt update && apt install -y tmux ffmpeg

export HF_HOME=/workspace/hf_cache
echo 'export HF_HOME=/workspace/hf_cache' >> ~/.bashrc

mkdir -p /workspace/input /workspace/output /workspace/tmp
```

`ffmpeg` is needed for frame extraction and re-encoding, and isn't always in the image.

**Why `HF_HOME`:** models download to `~/.cache/huggingface` then get *copied* into `ComfyUI/models/` — you pay for 30 GB twice. Pointing it at `/workspace` plus using `--local-dir` avoids the duplicate. (Verified: cache ended up at 408 K, so no duplication occurred.)

tmux detach: `Ctrl+B` then `D`. Reattach: `tmux attach -t work`.

---

## 5. Install the DreamID-V node

Three community wrappers exist. We used TTPlanet's — optimised for memory efficiency and native ComfyUI integration.

| Repo | Notes |
|---|---|
| `TTPlanetPig/Comfyui_DreamID-V_wrapper` | ✅ used here |
| `HM-RunningHub/ComfyUI_RH_DreamID-V` | Most established |
| `Goldlionren/ComfyUI_JR_DreamID-V` | 16GB-VRAM fork, fallback if OOM |

```bash
cd /workspace/ComfyUI/custom_nodes
git clone https://github.com/TTPlanetPig/Comfyui_DreamID-V_wrapper
cd Comfyui_DreamID-V_wrapper
pip install -r requirements.txt
python -c "import torch; print(torch.__version__, torch.version.cuda)"
```

**Always re-check torch after any `pip install`.** Custom node installs are the #1 cause of a silently downgraded torch.

> **Note:** `requirements.txt` pins `numpy<2` via mediapipe, so numpy drops to 1.26.4. Harmless, but it's the cause if you later see a `numpy.dtype size changed` ABI error.

---

## 6. Download the models

Repo listings first — never guess a filename before an 11 GB download:

```bash
python -c "from huggingface_hub import list_repo_files; print('\n'.join(list_repo_files('XuGuo699/DreamID-V')))"
python -c "from huggingface_hub import list_repo_files; print('\n'.join(list_repo_files('Wan-AI/Wan2.1-T2V-1.3B')))"
```

### The downloads

```bash
pip install -U "huggingface_hub[cli]"
cd /workspace/ComfyUI

hf download XuGuo699/DreamID-V dreamidv.pth --local-dir models/diffusion_models
hf download Wan-AI/Wan2.1-T2V-1.3B Wan2.1_VAE.pth --local-dir models/vae
hf download Wan-AI/Wan2.1-T2V-1.3B models_t5_umt5-xxl-enc-bf16.pth --local-dir models/text_encoders
```

> ### ⚠️ The rename gotcha
>
> The repo ships `models_t5_umt5-xxl-enc-bf16.pth` but the wrapper expects `umt5-xxl-enc-bf16.pth`:
>
> ```bash
> mv models/text_encoders/models_t5_umt5-xxl-enc-bf16.pth \
>    models/text_encoders/umt5-xxl-enc-bf16.pth
> ```

### What NOT to download

| File | Why skip |
|---|---|
| `diffusion_pytorch_model.safetensors` | Base Wan model — `dreamidv.pth` replaces it. Saves several GB |
| `dreamidv_faster.pth` | Lower-VRAM/faster variant. Only if you OOM |
| `dw-ll_ucoco_384.onnx`, `yolox_l.onnx` | DWPose files for ByteDance's *original* implementation. **TTPlanet's wrapper uses mediapipe instead** — verified by `grep -rn "onnx\|yolox" --include=*.py .` returning nothing |

### Verified result

```
models/diffusion_models/dreamidv.pth          6.4 G
models/text_encoders/umt5-xxl-enc-bf16.pth     11 G
models/vae/Wan2.1_VAE.pth                     485 M
```

Check for duplicates:

```bash
du -sh /workspace/hf_cache
df -h /workspace
```

---

## 7. Attention backend — leave it alone

`dreamidv_wan/modules/attention.py` wraps flash-attn / sageattention imports in `try/except ModuleNotFoundError` and falls back to **SDPA**. Nothing crashes from their absence.

```bash
python -c "import flash_attn" 2>&1 | tail -1        # expect ModuleNotFoundError
python -c "import sageattention" 2>&1 | tail -1     # expect ModuleNotFoundError
```

**Do not install them.** No cu130 prebuilt wheels exist; building flash-attn from source costs 30–60 min of paid GPU time for ~10–20% speedup on a job measured in minutes. SDPA in torch 2.10 is well optimised.

If a node exposes an attention dropdown, set it to **`sdpa`** explicitly rather than `auto`.

---

## 8. Restarting ComfyUI

> ### ⚠️ The supervisor gotcha
>
> ComfyUI runs under **supervisor** on this template. Do **not** launch `python main.py` manually — supervisor owns the process and will restart it underneath you, and you'll get `Port 8188 is already in use`.

```bash
supervisorctl status                    # see all managed services
supervisorctl restart comfyui
sleep 20
grep -i "dreamid\|traceback\|ModuleNotFoundError\|IMPORT FAILED" /var/log/portal/comfyui.log | tail -20
```

Log lives at `/var/log/portal/comfyui.log`.

**Custom nodes only load at startup** — every install requires a restart.

---

## 9. Missing dependencies — the loop

`requirements.txt` was incomplete. Each missing module surfaces one at a time.

**The loop:**
1. Read the `ModuleNotFoundError` module name
2. `pip install <module>`
3. `supervisorctl restart comfyui`
4. Re-grep the log
5. Repeat until the DreamID traceback disappears

**What we actually needed on this build:**

```bash
pip install easydict
pip install diffusers transformers accelerate sentencepiece ftfy
```

Other likely candidates in this repo family: `omegaconf`, `einops`, `imageio-ffmpeg`, `av`, `decord`.

All are small and none touch torch — but verify anyway after each round.

### Success looks like

```
[DreamID-V Wrapper] Loaded 3 nodes: Model Loader, Pose Extractor, Sampler
[INFO]    1.8 seconds: /workspace/ComfyUI/custom_nodes/Comfyui_DreamID-V_wrapper
```

No `IMPORT FAILED`. The `torch.cuda.amp.autocast is deprecated` FutureWarnings are harmless — old API, still functional in torch 2.10.

---

## 10. Next steps

### Find the example workflow

```bash
find /workspace/ComfyUI/custom_nodes/Comfyui_DreamID-V_wrapper -name "*.json"
```

There's an `example/` directory containing `TTP_DreamID-V_example_v1.json`.

### Upload test material

Two files into `/workspace/ComfyUI/input/`:

1. **Source face** — one restored photo, frontal, ≥512 px
2. **A 2-second test clip** — any reasonable shot from the film

> **Test with a throwaway clip, never your real footage.** You're validating that the pipeline runs end to end — resolution, VRAM, output format. A failed 18-second render wastes far more than a failed 2-second one.

### Then

1. Open `http://localhost:8188`
2. Drag the workflow JSON onto the canvas
3. Check for red / missing nodes
4. Point it at your input files
5. Run the 2-second test
6. Only then do the real shots

---

## Quick reference

```bash
# reconnect (Windows Terminal profile)
ssh -p 12345 root@HOST -L 8188:localhost:18188 -t "tmux attach -t work || tmux new -s work"

# service control
supervisorctl status
supervisorctl restart comfyui
tail -f /var/log/portal/comfyui.log

# health checks
python -c "import torch; print(torch.__version__, torch.version.cuda)"
nvidia-smi
df -h /workspace

# tmux
tmux attach -t work        # reattach
# Ctrl+B then D            # detach
```

### Ports

| Port | What |
|---|---|
| `18188` | ComfyUI (tunnel to **this**) |
| `8188` | Caddy reverse proxy (portal auth) |
| `18288` | comfyui-api-wrapper |

### Before you finish for good

```bash
df -h /workspace          # check space before big renders
```

**Destroy the instance when done** — a stopped instance still bills storage indefinitely.
