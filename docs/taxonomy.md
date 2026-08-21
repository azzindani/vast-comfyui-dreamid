# What these tools actually do

A map of AI video, image, 3D and audio work: the distinction that organises
everything, the three stages every job passes through, and which tool belongs
to which task.

Written to be read once and referred to often. The tool tables go stale; the
task structure does not.

---

## 1. The distinction that organises everything

Every model in this space does one of two things:

| | **Creation** | **Editing** |
|---|---|---|
| Conditioned on | A prompt | Existing footage |
| Produces | Something that never existed | A modified version of something real |
| Fails as | Hallucination — wrong physics, drifting identity | Seams — visible boundaries between real and generated |
| Constrained by | Almost nothing | The plate |
| Scales with | GPU budget | Your footage library |

**Creation is prediction with no anchor.** The model invents lighting, motion,
physics and continuity, and gets all of them approximately right — which reads
as *wrong* to a human eye trained on reality.

**Editing is prediction with an anchor.** The real footage supplies lighting,
lens behaviour, motion blur and physics for free. The model only has to fill a
gap consistently.

This is the same reason retrieval beats a larger model on factual questions.
The retrieved content carries information the weights do not have.

> **The practical consequence:** in editing, the hard problem moves to the
> **boundary**. Mask edges, resolution mismatch, grain, colour, chunk joins.
> Almost nothing that goes wrong is the model's fault, and almost every fix
> lives in pre- or post-processing.

**Creation is not the weaker sibling.** It is the *element source* — for what
cannot be filmed. Impossible camera moves, historical reconstruction, fire,
crowds, destruction. The strongest pipeline is generated elements composited
into a real plate, not generation replacing the shot.

---

## 2. The three stages

Every job, regardless of medium, passes through the same three stages. Most
quality problems are solved in stages 1 and 3, not stage 2.

```
PRE-PROCESS          PROCESS              POST-PROCESS
ingest, detect,      the model            composite, grade,
mask, crop,          (creation or         degrade, encode
condition            editing)
```

**Beginners spend all their effort on stage 2** — tuning samplers, chasing
models. **Stage 1 determines the ceiling** (garbage in, garbage out — no model
recovers information that is not present). **Stage 3 determines whether it is
believable** (a perfect generation composited badly still looks fake).

### The non-enhancement principle

The giveaway of a manipulated shot is **mismatch**, not softness. A face
sharper than the plate around it reads as fake; a face matching the plate's
softness does not.

So the finishing move is often to **degrade back down**: add grain, soften,
re-compress. Post-processing is as often about removing quality as adding it.

---

## 3. Task groups

### 3.1 Video — creation

| Task | What it is | Notes |
|---|---|---|
| Text-to-video | Prompt → clip | Weakest grounding, hardest to control |
| Image-to-video | Still → motion | Far more controllable; the still anchors identity and composition |
| Start/end frame | Two stills → the motion between | Strongest control in pure creation |
| Extension | Continue a clip past its window | Conditions on the last frame; the correct fix for length limits |
| Camera control | Prescribed camera move | Orbit, dolly, pan as an explicit parameter |

### 3.2 Video — editing

| Task | What it is |
|---|---|
| Video-to-video | Restyle while preserving motion |
| Inpainting | Replace a masked region across frames — object removal, replacement |
| Outpainting | Extend the frame beyond its borders; aspect ratio change |
| Reference-to-video | Inject a subject or style from reference images |
| Face swap | Replace facial identity, preserve performance |
| Motion transfer | Drive a subject with another performance |
| Relight | Change lighting direction and quality after the fact |
| Object tracking + removal | Segment, track, fill — the classic VFX cleanup |

### 3.3 Video — restoration and finishing

| Task | What it is |
|---|---|
| Upscale | Raise resolution — temporal models beat per-frame ones |
| Restore | Remove blur, noise, compression artifacts |
| Deflicker | Suppress frame-to-frame luminance instability |
| Frame interpolation | Insert in-between frames — higher fps, or slow motion |
| Stabilise | Remove unwanted camera shake |
| Colour match | Make a generated shot sit with the shots either side |
| Grain / degrade | Deliberately lower quality to match a plate |

### 3.4 Image — creation

| Task | What it is |
|---|---|
| Text-to-image | Prompt → image |
| Controlled generation | Pose, depth, edge or segmentation conditioning |
| Identity conditioning | A specific person from one photo, no training |
| LoRA-conditioned | A specific person, style or object, trained |

### 3.5 Image — editing

| Task | What it is |
|---|---|
| Instruction editing | "Remove the car" — no mask required |
| Inpainting | Replace a masked region |
| Outpainting | Extend beyond the frame |
| Multi-image composition | Combine subjects from several references |
| Relight | Change lighting after the fact |
| Restore | Deblur, denoise, colourise, face restore |
| Upscale | Raise resolution |
| Background removal | Cut the subject out |

### 3.6 3D

| Task | What it is |
|---|---|
| Image-to-mesh | Single photo → 3D geometry |
| Image-to-splat | Single photo → Gaussian splat (view synthesis, not geometry) |
| Texture generation | Paint an untextured mesh |
| Multi-view generation | Consistent views of one subject from one image |
| Depth / normal estimation | 2.5D data from a flat image — feeds video control |

> 3D matters for video work even when you never deliver a model: depth maps
> and multi-view generation are **conditioning inputs** for controlled video.

### 3.7 Audio

| Task | What it is |
|---|---|
| Text-to-speech | Script → voice |
| Voice cloning | Script → a *specific* voice, from a short reference |
| Voice conversion | Recorded performance → different voice, timing preserved |
| Music generation | Prompt → music |
| Stem separation | Split a mix into vocals / bass / drums / other |
| Restoration | Denoise, dereverb, repair |
| Lip sync | Drive mouth movement from audio — a *video* task, audio-driven |

> **Lip sync is often unnecessary.** If a face swap preserves the original
> mouth movement and you keep the original audio, sync is free. You only need
> it when replacing the dialogue.

### 3.8 Pre-processing — cuts across everything

| Task | Why it matters |
|---|---|
| Ingest / normalise | Frame rate, colour space, container. Wrong fps ruins everything downstream |
| Frame extraction | Video → frames for per-frame work |
| Detection | Find faces, bodies, objects |
| Segmentation | Turn a detection into a mask |
| Tracking | Keep a mask locked across frames — the core of video masking |
| Matting | Soft-edged alpha, not a binary mask. Hair and motion blur need this |
| Control extraction | Depth, pose, edges, normals, optical flow |
| Crop / reframe | **Spend your pixels on the subject**, not the background |
| Dataset prep | Crop, caption, balance — for LoRA training |

> **The single highest-leverage pre-process is cropping.** Ask what fraction
> of your pixels is subject. A tight crop at low resolution beats a loose crop
> at high resolution — more subject detail, more mask resolution, less compute.

### 3.9 Post-processing — cuts across everything

| Task | Why it matters |
|---|---|
| Compositing | Put the generated element back into the real plate |
| Edge treatment | Feather, light wrap, edge blur — where fakeness lives |
| Colour match | Match the element to the plate |
| Grain match | Add grain matching the plate's structure |
| Deflicker / stabilise | Temporal cleanup after generation |
| Chunk joining | Dissolve or hard-cut between passes |
| Encode | CRF, pix_fmt, container. Use a high-quality intermediate, compress once at the end |

---

## 4. Constraints that shape everything

These are properties of the current generation of models, not bugs. Design
around them.

**The frame window.** Video models have a fixed trained length — 81 frames is
typical, about 3.4 seconds at 24fps. **This is a training limit, not a memory
limit.** More VRAM does not buy longer clips. Longer material needs chunking,
extension conditioning, or cutting to shot boundaries.

**4n+1 frame counts.** Video VAEs compress time roughly 4×, so valid counts are
41, 61, 81, 101. Other values get padded or rejected.

**Divisible-by-16 dimensions.** VAE downsamples 8×, transformer patches 2×.

**VRAM is a function of the card, not the workflow.** Give the runtime room and
it keeps everything resident; give it less and it offloads what is not in use.
A reported "this used 28 GB" means *that card allowed 28 GB*, not *this job
needs 28 GB*.

**Cuts are free seams.** If long material contains an edit, split there. No
dissolve, no overlap, and each piece may fit in a single pass.

---

## 5. Tool inventory

Verified reachable at the time of writing. Treat this section as perishable —
the task structure above is the durable part.

### Video — creation and editing

| Tool | Task | Where |
|---|---|---|
| **Wan** (2.1 / 2.2) | The general video foundation — t2v, i2v, extension | Core ComfyUI + `kijai/ComfyUI-WanVideoWrapper` |
| **VACE** | Unified editing: reference-to-video, v2v, inpaint, outpaint | Native nodes (`WanVaceToVideo`, `TrimVideoLatent`) |
| **Wan-VACE-Prep** | Transitions, extensions, outpainting made less fiddly | `stuttlepress/ComfyUI-Wan-VACE-Prep` |
| **Wan Animate** | Regenerates a whole person from a reference, matches scene light | `kijai/ComfyUI-WanVideoWrapper` |
| **DreamID-V** | Face swap — replaces the face region, keeps the performance | `TTPlanetPig/Comfyui_DreamID-V_wrapper` |
| **LTX-Video** | Fast generation — prototype here, finish on Wan | Core ComfyUI |

### Video — restoration and finishing

| Tool | Task | Where |
|---|---|---|
| **SeedVR2** | Diffusion video upscale/restore with temporal consistency | `numz/ComfyUI-SeedVR2_VideoUpscaler` |
| **RIFE** | Frame interpolation — fps and slow motion | `Fannovel16/ComfyUI-Frame-Interpolation` |
| **RealESRGAN / UltraSharp** | Per-frame upscale — fast, no temporal awareness | Core ComfyUI nodes + model files |
| **VideoHelperSuite** | Load, combine, preview, encode | `Kosinkadink/ComfyUI-VideoHelperSuite` |

> **Order matters:** restore the real frames *first*, then interpolate, then
> encode. Interpolating before restoring propagates artifacts into the new
> frames.

### Image

| Tool | Task | Where |
|---|---|---|
| **Qwen-Image-Edit** | Instruction editing, multi-image composition, text in images | Core ComfyUI |
| **Flux / Flux Kontext** | Generation and editing — faster than Qwen | Core ComfyUI |
| **SDXL** | Older, lighter, enormous LoRA ecosystem | Core ComfyUI |
| **PuLID** | Identity from one photo, no training | `cubiq/PuLID_ComfyUI` |
| **controlnet_aux** | Depth, pose, canny, normals, lineart preprocessors | `Fannovel16/comfyui_controlnet_aux` |
| **Inpaint-CropAndStitch** | Inpaint at full res on a crop, stitch back | `lquesada/ComfyUI-Inpaint-CropAndStitch` |
| **CodeFormer / GFPGAN** | Face restore | `mav-rik/facerestore_cf` |

### Segmentation, matting, tracking

| Tool | Task | Where |
|---|---|---|
| **RMBG** | Background removal + segmentation — RMBG-2.0, BiRefNet, BEN2, SAM, SDMatte | `1038lab/ComfyUI-RMBG` |
| **SAM2** | Promptable segmentation with video tracking | `kijai/ComfyUI-segment-anything-2` |

> **Matting ≠ segmentation.** Segmentation gives a binary mask. Matting gives
> soft alpha — necessary for hair, motion blur, and any believable composite.

### 3D

| Tool | Task | Where |
|---|---|---|
| **3D-Pack** | Mesh, texture, 3DGS, NeRF; Hunyuan3D, InstantMesh, TripoSR, CRM | `MrForExample/ComfyUI-3D-Pack` |
| **TripoSplat** | Single image → Gaussian splat | Native ComfyUI support |
| **Hunyuan3D-2** | Image → mesh, then mesh + reference → textured mesh | Via 3D-Pack |

### Audio

| Tool | Task | Where |
|---|---|---|
| **TTS-Audio-Suite** | Multi-engine TTS and voice conversion — RVC, F5-TTS, IndexTTS-2, VibeVoice, Chatterbox, Qwen3-TTS | `diodiogod/TTS-Audio-Suite` |
| **Step Audio EditX** | Zero-shot voice cloning with emotion and style control | `Saganaki22/ComfyUI-Step_Audio_EditX_TTS` |
| **audio-separation-nodes** | Stem separation, tempo match, slice | `christian-byrne/audio-separation-nodes-comfyui` |
| **ACE-Step** | Music generation | Core ComfyUI |

### Utility

| Tool | Task | Where |
|---|---|---|
| **KJNodes** | Resize, constants, masks, VRAM debug — the general toolbox | `kijai/ComfyUI-KJNodes` |
| **ComfyUI_essentials** | Image/mask utilities that fill core gaps | `cubiq/ComfyUI_essentials` |

---

## 6. Choosing a pipeline

Work backwards from the deliverable.

| Goal | Pipeline |
|---|---|
| Put someone's face in existing footage | crop → face restore refs → DreamID-V → composite → grade |
| Remove an object from a shot | SAM2 track → mask → VACE inpaint → grain match |
| Make a shot that was never filmed | image gen → i2v → extend → restore → grade |
| Fix bad archival footage | SeedVR2 restore → RIFE (only for slow-mo) → grade |
| Change what someone says | face swap or lip sync → voice clone → mix |
| Turn a photo into a moving asset | image → 3D or splat → render camera move |
| Match a generated shot to real footage | colour match → grain → **degrade**, not enhance |

---

## 7. Environment discipline

Every custom node installs into **one shared Python environment**. Node A pins
`numpy<2`, Node B needs `numpy>=2`, Node C quietly downgrades torch. pip is
last-writer-wins and will not warn you.

The rules that follow:

1. **One pipeline, one node set.** Five nodes, not fifty. Build a small install
   per job rather than a universal one.
2. **Use a constraints file.** Global pins that no `requirements.txt` can
   override — the damage is prevented, not detected.
3. **Rebuild rather than repair.** On rented hardware a broken environment
   costs minutes, not a weekend. This is why ephemeral boxes beat a permanent
   local install.
4. **Disable, don't uninstall.** A directory renamed `Foo.disabled` is skipped
   at startup.

See `profiles/` for the per-task node sets this repo installs.

---

## 8. Where this is going

The field is converging on **in-context editing** rather than pure text-to-video
— VACE, and the closed tools alike. That is the same conclusion this document
opens with, arrived at commercially.

Expect the interface to become **orchestration**: describe an intent, and a
system decomposes it into a chain of specialist models. Restore → swap →
upscale → grade.

The chain does not disappear. It gets hidden. Which is why understanding the
chain remains the durable skill — the button changes, the pipeline does not.
