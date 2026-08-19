# 0003 — VAAPI import of the alpha 10-bit RGB DRM formats

| | |
|---|---|
| **Status** | Shipping. Verified end to end on hardware, after a first version that was wrong. |
| **Covers** | All targets — goes into `debian/patches/` as `0098`, so every build system applies it |
| **Retires when** | Upstream jellyfin-ffmpeg (or FFmpeg) accepts the alpha 10-bit RGB DRM entries |
| **Gate** | `checks/0003.checks` — declared `ungateable`, with the reason. A format-table entry appears in neither `-h encoder=` nor `-filters`. |

## What it does

Adds two entries to `vaapi_drm_format_map` in `libavutil/hwcontext_vaapi.c`, so VAAPI will import
the **alpha** spellings of the 10-bit RGB DRM formats.

Vulkan exports a single-plane 10-bit RGB image as `DRM_FORMAT_ARGB2101010` or `ABGR2101010`, never
the X variants: `hwcontext_vulkan.c`'s `vkfmt_to_drmfmt()` returns the first table match and the
alpha spellings are listed first. `vaapi_drm_format_map` carried only the **X** spellings —
upstream has `X2R10G10B10`, jellyfin's own `0038` adds `X2B10G10R10` — so mapping such a frame to
VAAPI failed:

```
[AVHWFramesContext] DRM format not supported by VAAPI.
[Parsed_hwmap]      Failed to map frame: -22.
```

X and A differ only in whether the top two bits are meaningful. The layout is identical and the
driver takes the surface either way.

## The pairing is crossed, and that is the entire difficulty

The patch adds two lines. **Which alpha fourcc pairs with which VA fourcc is the whole problem, and
the intuitive answer is wrong.**

The DRM/Vulkan tables are channel-inverted by convention — DRM fourccs are little-endian packed
while Vulkan `PACK32` names read MSB-first — so `DRM_FORMAT_ARGB2101010` carries the Vulkan
`A2B10G10R10` layout, not `A2R10G10B10`. Measured on Mesa 26.2.0 / RX 9070 XT (gfx1201) by logging
`desc->layers[0].format` in `vaapi_map_from_drm()`:

```
libplacebo format=x2rgb10  ->  DRM fourcc AB30 (ABGR2101010)
libplacebo format=x2bgr10  ->  DRM fourcc AR30 (ARGB2101010)
```

So each alpha fourcc maps to the VA fourcc of the **opposite** channel order:

```c
DRM_MAP(X2R10G10B10, 1, DRM_FORMAT_ABGR2101010),
DRM_MAP(X2B10G10R10, 1, DRM_FORMAT_ARGB2101010),
```

The first version used the same-order pairing, following `0038`'s precedent — which does not apply
here. That was **worse than not having the patch at all**: it turned a loud `-22` into a valid file
at full speed with the chroma destroyed, which no return code reports.

| pairing | y | u | v | |
|---|---|---|---|---|
| same-order (first version) | 29.12 | **16.08** | **17.22** | R and B transposed |
| crossed (shipping) | 51.53 | 48.12 | 48.23 | correct |

Per-channel PSNR against the 8-bit `bgra` chain, same libplacebo curve, 48 frames, same session.

## Why it exists

On RDNA4 a *multiplane* Vulkan target (`nv12`, `p010`) costs about **2×** — measured 9.98 s against
19.46 s at equal bit depth, with the penalty following the multiplane frame rather than the filter
writing it. So a fast Vulkan tonemap chain has to keep the Vulkan side single-plane, which without
this patch means 8-bit `bgra` widened to `p010` by VAAPI's VPP: full speed, 8-bit precision.

A single-plane **10-bit** RGB target keeps both. This was the only thing blocking it.

## What is proven, and what is not

**Proven.** The channel order, by reading the exported fourcc directly and by the PSNR table above.
The speed, measured at **9.53 s against the 8-bit chain's 9.54 s** — 10-bit precision at no cost.

**Not proven.** Whether 10-bit tonemap precision is *visibly* better than the 8-bit path in
practice. That is a quality judgement, not a correctness one.

**Why CI cannot gate it.** `verify-binary.sh` reads `-h encoder=` and `-filters`, and a format-table
entry appears in neither. Proving it needs a `hwmap` on AMD hardware, which a GPU-less runner does
not have. So `0003` is outside the gate by construction rather than by omission, and
`checks/0003.checks` declares exactly that — delete the declaration and the gate fails.

## Gotchas

- **Do not reorder the table entries.** The X entries sit ahead of these, and `vaapi_map_to_drm()`
  takes the first `va_fourcc` match, so VAAPI → DRM still emits the X spellings. Putting the alpha
  entries first would silently change the export direction.
- **`0004` depends on this patch existing.** Its series hunk uses `0096`/`0097`/`0098` as context
  and `0098` is this patch, so retiring `0003` breaks `0004`'s `git apply`. Loud, not silent, but
  worth knowing before you delete anything.
- **A wrong pairing does not error.** It produces a valid file at full speed. The only thing that
  catches it is per-channel PSNR — a high *average* with wrecked chroma looks fine at a glance.

## How it was diagnosed

The fix came from a local build loop, not from CI — see [local-build-loop.md](../local-build-loop.md).
A container derived from the runtime image, ffmpeg configured with only vaapi/vulkan/libplacebo,
gives a full build in about a minute and an incremental rebuild in **about five seconds**, against
2h24m for a release build. That turned "one instrumented build beats two guesses, so choose which
question to ask" into simply adding a log line and reading the answer.

The trap worth remembering: three reconstructed filter graphs failed before anyone noticed the
**8-bit control was failing identically**. `bgra` is the format the shipping chain uses and cannot
be broken, so its failure proved the test was wrong rather than the code. Get the real command from
the harness instead of reconstructing it.
