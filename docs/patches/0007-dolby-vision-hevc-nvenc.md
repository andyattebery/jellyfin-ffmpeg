# 0007 — Dolby Vision RPU passthrough for hevc_nvenc

| | |
|---|---|
| **Status** | Shipping. Verified on hardware 2026-08-23 (RTX A4000, driver 595.71.05) by reading the output RPUs with `dovi_tool`, not by trusting the configuration record. |
| **Covers** | All targets — goes into `debian/patches/` as `0903`. Unlike `0004`, the *feature* is cross-platform: NVENC is built for all four build jobs. |
| **Depends on** | **`0004`.** This patch moves 0004's profile 8.1 conversion into a shared file and rewrites 0004's copy to call it, so the two must apply in order. |
| **Retires when** | Upstream jellyfin-ffmpeg (or FFmpeg) accepts Dolby Vision for the NVENC encoder |
| **Gate** | `checks/0007.checks` — three `encoder-option` checks on `hevc_nvenc`, declared `all` |

> The patch file's own header is the fuller technical record. This doc is the repo-facing summary.

## What it does

`hevc_nvenc` dropped Dolby Vision on transcode, exactly as `hevc_vaapi` did before `0004`: only
`libx265`, `libsvtav1` and `libaomenc` call `ff_dovi_configure()`. This wires `hevc_nvenc` to the
existing DOVI code.

The practical effect is that **profile 7 and profile 8 sources encode directly on NVIDIA**, instead of
needing a `dovi_tool` pre-pass to strip and re-inject the RPU around the encode.

## Options

Identical to `0004` — same three names, same semantics, same defaults.

| option | type | default | what it does |
|---|---|---|---|
| `dolbyvision` | boolean tri-state | `auto` | emit the RPU and the DV configuration record |
| `dv_l5` | `keep` / `zero` / `scale` | `keep` | how to handle the level 5 (active area) metadata |
| `dv_l5_canvas` | image_size | unset | the frame size the source L5 offsets refer to; required by `dv_l5=scale` |
| `-strict unofficial` | global | — | **not an encoder option, but required for MP4 output.** Without it `movenc` omits the `dvcC`/`dvvC` box and the file plays as plain HDR10. Matroska needs no flag. |

That the two encoders agree is **structural, not editorial**: the `dv_l5` pair is declared by a single
`FF_DOVI_P81_L5_OPTIONS()` macro in `libavcodec/dovi_p81.h` that both option tables expand. They
cannot drift without someone deleting the macro.

**`-dolbyvision 1` is required in practice**, for the same reason as `0004`: the `auto` default keys on
`avctx->decoded_side_data`, which the ffmpeg CLI never populates. A frame arriving with DV metadata
while no profile is active warns once.

## The shared conversion

`0004` grew a profile 4/7 → 8.1 conversion, FEL/MEL discrimination and L5 rescaling. None of it is
VAAPI-specific — a hardware decoder drops the enhancement layer before either encoder sees a frame —
so this patch moves it to **`libavcodec/dovi_p81.{c,h}`** and has both encoders call it.

Two pieces of that are deliberately structural rather than conventional:

- **`FF_DOVI_P81_L5_OPTIONS()`** — one declaration of the options, expanded by both encoders.
- **`ff_dovi_p81_check_options()`** — `dv_l5=scale` without `dv_l5_canvas` divides by zero at the
  first letterboxed frame rather than producing a diagnostic. `0004` guarded it inline; an encoder
  adopting these options could have forgotten to. Now it cannot: the guard travels with the feature.
  **This was a live bug in the first draft of this patch**, found by writing the nvenc path.

Behaviour is unchanged from `0004` — its options and their defaults were re-checked after the
refactor.

## How the RPU reaches the packet

**The RPU is a suffix NAL (type 62, UNSPEC62), so it cannot be an SEI.** NVENC's `seiPayloadArray`
writes SEI NAL types only, which is why the A53 and timecode payloads can go through it and this
cannot. The RPU is appended to the coded packet in `process_output_surface()` — the same thing
`dovi_tool inject-rpu` and rigaya's NVEncC do.

**With B-frames the RPU has to follow its picture, not the submission order — and existing plumbing
already does that.** `nvenc_store_frame_data()` writes a per-frame slot and passes the index out
through `pic_params->inputDuration`; NVENC returns it as `lock_params->outputDuration`. That is how
`duration` and `frame_opaque` already cross the encoder, so the RPU just becomes a third field in the
slot. No new correspondence is invented.

⚠ **The slot index is not the frame number.** It wraps modulo `frame_data_array_nb` (19 on the test
configuration). Anything reading it as a frame counter will be right for the first pass and wrong
afterwards.

`process_output_surface()` **peeks** at the slot rather than consuming it, because the packet must be
sized for `bitstreamSizeInBytes + rpu_size` before `ff_get_encode_buffer()` allocates it.
`nvenc_retrieve_frame_data()` still owns freeing it.

## Verified on hardware — 2026-08-23

RTX A4000, driver 595.71.05, shared build of this source at `v8.1.2-2` with the full series. Each
case read back with `dovi_tool`, not inferred from the configuration record.

| case | result |
|---|---|
| P8 bl1 (8.1), `-dolbyvision 1` | profile 8 / compat 1 tag, RPU profile 8, 20/20 frames carry an RPU |
| P7 **FEL**, `-dolbyvision 1` | converted; `header` and `rpu_data_mapping` **byte-identical to `dovi_tool -m 2`** on the same window. EL type logged as FEL |
| P7 **MEL**, `-dolbyvision 1` | converted; **byte-identical to `dovi_tool -m 2`** as well. Logged as MEL, and the log correctly omits the FEL-only "reshaping mapping is dropped" — the curves come through untouched, only the NLQ fields change |
| **P5**, `-dolbyvision 1` | **not converted** — profile 5 / compat 0 in, profile 5 / compat 0 out, no conversion logged |
| **P8 bl6**, `-dolbyvision 1` | passes through; compat id **derived to 1**, not copied (see Not covered) |
| **dual-track P7** | `-dolbyvision 1` **fails cleanly** — *"received frame without AV_FRAME_DATA_DOVI_METADATA"*, ffmpeg exits **183**. Under `auto` it produces a non-DV file with no warning, because the warning is gated on the frame carrying DV metadata |
| **B-frames** (`-bf 3`) | **71 B / 1 I / 24 P**, and across 96 frames **every packet fetched the slot its own frame was stored in — 0 exceptions**. The one distinctively sized RPU (165 bytes against 166) landed on the frame carrying the source's L1 scene change |
| pixels, DV on vs off | **framemd5-identical**, 48/48 frames; the file grows by exactly the RPU bytes |
| rate control | RPU **byte-identical** between `constqp` and VBR |
| L5 `keep` on a letterboxed source | offsets pass through, warns once (measured on a source carrying 0/0/277/277) |
| mp4 | `dvcC` written with `-strict unofficial`, **absent without it** |
| `auto` on a DV source | no DV, warns exactly once |

All five Dolby Vision shapes present in this library were covered — 8.1, P7 FEL, P7 MEL, P5 and the
one P8 bl6 title — plus the one dual-track P7 that no encoder can carry.

**The B-frame row is the point of this patch's verification.** `0004` could not obtain it: RDNA4 on
Mesa 26.0.4 reports "supported references: 1 / 0" and produces only I and P frames, so the RPU
reordering argument was untestable there. NVENC does real B-frames, and the pairing holds.

⚠ **The B-frame count was asserted before any DV result was read.** An earlier B-frame test on the
VAAPI side "passed" while producing `{I: 1, P: 29}` — it tested nothing. Any re-run should check
`pict_type` first.

## Not covered

- **Only `hevc_nvenc`.** `av1_nvenc` would need the T.35 metadata OBU path — cheap, because
  `av1PicParams.obuPayloadArray` already carries ITU-T T.35 for A53 captions — but AV1 Dolby Vision
  is **profile 10**, which no target player in this deployment implements.
- **The MEL branch is proven to *detect*, not to *preserve*.** Unchanged from `0004`, and the NVENC
  test did not close it: the MEL source used here also carries the identity mapping
  (packed `poly_coef [0, 1<<23]`), so "reset" and "leave alone" emit the same bytes on it. What is
  proven is that the branch is taken — the log names the EL type and the FEL-only mapping reset does
  not fire. Closing this needs a MEL source with a non-identity mapping, and none has been found.
- **Profile 4 untested** — no such content exists to test against.
- **No Windows encode was run — but there is no Windows-specific code to get wrong.** This is a
  formality, not a gap, and it is worth being precise about why:
  - The DV code contains **no reference to either hardware pixel format**. Both `AV_PIX_FMT_CUDA` and
    `AV_PIX_FMT_D3D11` collapse into `ctx->data_pix_fmt` on one shared line at the top of
    `ff_nvenc_encode_init()`, before anything here runs. There is no `d3d11va` branch — it is the
    same code reached through a different opaque handle.
  - The side data that drives all of it is attached by `ff_dovi_attach_side_data()` in the HEVC
    decoder's frame-output path, **not gated on hwaccel**: the RPU is parsed from the bitstream in
    software however slice decoding is offloaded.
  - The gate proves the three options register in the win64 and winarm64 artifacts.

  What is untested is only the end-to-end assertion "a Windows build encodes a DV file correctly".
  Closing it needs one encode on a Windows host running a CI release build.
- **Dual-*track* profile 7 files** cannot carry DV through any encoder — the RPU lives in a video
  track ffmpeg does not map. Unchanged from `0004`.
- **No Dolby Vision display.** Everything above is bitstream-level.

## Gotchas

- **Platform `all`, not `linux`.** NVENC is built for all four targets, so all four must carry these
  options. ⚠ `0001.checks` says *"Do NOT collapse the two files into one `all`"* — that is about
  `0001`/`0002` being two patches pinning two independent build systems, and does **not** transfer to
  a single patch in `libavcodec`. The precedent that fits is `filter  all  tonemap_cuda`.
- **This patch depends on `0004`** and must apply after it. `0004` no longer stands alone in the way
  its own doc describes — see the note there.
- **`git apply --check` is not a meaningful test** of this patch series. Only a real cumulative apply
  is; CI does one, and it was run here from a clean tree before the hardware testing.
