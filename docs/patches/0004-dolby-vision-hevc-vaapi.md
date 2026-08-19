# 0004 — Dolby Vision RPU passthrough for hevc_vaapi

| | |
|---|---|
| **Status** | Shipping. Verified on hardware 2026-08-18 (RX 9070 XT, Mesa 26.0.4, radeonsi/gfx1201) by reading the output RPUs with `dovi_tool`, not by trusting the configuration record. |
| **Covers** | All targets — goes into `debian/patches/` as `0099`. The *feature* is linux-only, because VAAPI is linux-only in this pipeline. |
| **Retires when** | Upstream jellyfin-ffmpeg (or FFmpeg) accepts Dolby Vision for the VAAPI encoder |
| **Gate** | `checks/0004.checks` — three `encoder-option` checks on `hevc_vaapi`, declared `linux` so they `skip` on the Windows jobs |

> The patch file's own header is the fuller technical record — mechanism, NAL layout, the exact
> reasoning behind each decision. This doc is the repo-facing summary: what it does, how to use it,
> what is proven, and what will bite you.

## What it does

`hevc_vaapi` drops Dolby Vision on transcode. FFmpeg has all the machinery — the HEVC decoder
parses the RPU and attaches `AV_FRAME_DATA_DOVI_METADATA` to every frame, and `dovi_rpuenc.c` can
synthesise it back out — but only `libx265`, `libsvtav1` and `libaomenc` are wired to it. No VAAPI,
Vulkan or AMF encoder calls `ff_dovi_configure()`.

So on AMD Linux there was no single-pass way to keep DV through a hardware encode: encode the base
layer, then re-inject the RPU afterwards with `dovi_tool` and remux. That matters more now that AMD
has dropped AMF from the Linux driver (25.20 release notes) and pointed users at VA-API, which
takes rigaya's VCEEncC — the one tool that did this in one pass — off the table.

This wires `hevc_vaapi` to the existing DOVI code, following `libx265.c`.

## Options

| option | type | default | what it does |
|---|---|---|---|
| `dolbyvision` | boolean tri-state | `auto` | emit the RPU and the DV configuration record |
| `dv_l5` | `keep` / `zero` / `scale` | `keep` | how to handle the level 5 (active area) metadata |
| `dv_l5_canvas` | image_size | unset | the frame size the source L5 offsets refer to; required by `dv_l5=scale` |

### ⚠ `-dolbyvision 1` is required in practice

**The `auto` default never engages under the ffmpeg CLI.** `avctx->decoded_side_data` is not
populated with an `AVDOVIMetadata` there — measured, and libx265 behaves identically on the same
input, so this is FFmpeg's plumbing rather than anything specific to VAAPI.

The encoder says so: a frame carrying DV metadata while no profile is active warns once that Dolby
Vision is being dropped and that `-dolbyvision 1` enables it.

### `dv_l5` and letterboxing

L5 states the active picture area as four **absolute pixel** offsets from the frame edges, so a
display can exclude letterbox bars. A 2.39:1 film coded 3840x2160 carries top/bottom offsets of
**276** — measured, not derived. Those offsets are written through verbatim and know nothing about
resolution, so **rescaling the frame leaves them stale** — scale to 1920x1080 and the RPU still
claims 276 rows of bar where there are now 138.

The encoder cannot detect this: the filter chain runs first, so the frame arriving at the encoder
has already been scaled and its dimensions always equal `avctx->width/height`. The source size has
to be supplied.

```
-dv_l5 scale -dv_l5_canvas 3840x2160   # 2160p letterboxed source, encoding to 1080p
-dv_l5 zero                            # chain crops the bars off first
```

`keep` is the default, so same-resolution encodes are unaffected. `dv_l5=scale` without
`dv_l5_canvas` is rejected at init, not mid-encode. A source carrying non-zero L5 under `keep`
warns once — including on correct same-resolution encodes, because stale offsets remain perfectly
legal for the frame and there is no better test.

## Profiles, and a bug that hid well

Covers profiles **8** and **5** directly, and **7** and **4** by converting them to single-layer
profile 8. Profile 5 is untouched — `vdr_rpu_profile` 0, so the guess returns 5 and no conversion
fires.

**Profiles 4 and 7 were nominally rejected and that rejection was unreachable.** It keys on the RPU
header out of `decoded_side_data`, and with no metadata the profile is instead guessed from colour
tags — BT.2020 PQ gives profile 8. So a profile 7 source produced a stream *tagged* 8.1 whose RPUs
were still profile 7, describing an enhancement layer the VAAPI decoder had already discarded.

Nothing complained. The configuration record was correct and every frame carried an RPU; only
reading the RPU internals showed the mismatch. **This is why the hardware verification below reads
RPUs with `dovi_tool` rather than trusting the configuration record** — the record is a header
claim a stream can carry with nothing behind it.

The RPU is now brought to the single-layer profile 8 shape instead, and the generated RPU's profile
is compared against the configuration record before writing, so a mismatch is an error rather than
a mislabelled stream.

**That conversion discards the enhancement layer**, which is lossy in principle — though the VAAPI
decoder has already dropped it before the encoder sees a frame, so nothing recoverable is lost at
this point. It is logged once at INFO. The practical effect is that profile 7 sources encode
directly, instead of needing a `dovi_tool -m 2` pre-pass.

## Verified on hardware — 2026-08-18

RX 9070 XT, Mesa 26.0.4 (radeonsi, gfx1201), jellyfin-ffmpeg `v8.1.2-2` with the full series. Each
case checked by reading the output RPU with `dovi_tool`:

| case | result |
|---|---|
| P8.1, `-dolbyvision 1` | profile 8 tag, RPU profile 8, 20/20 frames carry an RPU |
| P5, `-dolbyvision 1` | profile 5 tag, compat 0, not converted |
| P7, `-dolbyvision 1` | converted; RPU profile 8, `disable_residual_flag` true, NLQ absent (before: RPU still profile 7) |
| `auto`, any source | no DV, now warns once |
| L5 `keep`, 4K→1080p | offsets stay 276, now warns once |
| L5 `scale` + canvas | offsets rescale 276 → 138 |
| mp4, `-strict unofficial` | `dvcC` written, `hvc1` tag |

The L5 functions were additionally unit-tested by extracting them verbatim and running them against
metadata built with `av_dovi_metadata_alloc()`.

## Not covered

- **Only `hevc_vaapi`.** `av1_vaapi` would need the T.35 wrapping path; `h264_vaapi` has no DV
  profile worth having.
- **B-frames are untested.** This encoder reports "supported references: 1 / 0" on RDNA4 / Mesa
  26.0.4 and produces I and P frames only, so encode order equals display order and nothing
  exercises the RPU reordering argument. If a later Mesa enables HEVC B-frames, that needs testing
  rather than assuming.
- **No Dolby Vision display.** Everything above is bitstream-level.
- `avctx->framerate` drives the DV level calculation, as in libx265 — an unset framerate gives a
  level derived from 0 fps. Pass `-r` if it matters.

## Gotchas

- **Linux only, and that is the pipeline, not the patch.** VAAPI is linux-only here:
  `builder/scripts.d/50-vaapi/50-libva.sh:7` returns `-1` off linux and `msys2/PKGBUILD/` has no
  libva at all. The three gate checks therefore `skip` on the two Windows jobs. An unconditional
  check would fail both, and `release` needs all four build jobs — so it would block every publish,
  and cost a 2.5 hour cycle to discover.
- **This patch depends on `0003`.** Its series hunk uses `0096`/`0097`/`0098` as context, and
  `0098` exists only because `0003` ran first. Retiring `0003` breaks this patch's `git apply`.
