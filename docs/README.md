# Docs

Start at the [repo README](../README.md) for what this repo is and what it builds. These are the
details that would otherwise bury it.

## Patches

One doc per patch. **These are canonical** — the patch files carry a short mechanism summary and
point here, and the repo README carries only an index. If a patch's behaviour and its doc disagree,
the doc is the thing to fix.

| | covers | status |
|---|---|---|
| [0001 — nv-codec-headers pin, linux](patches/0001-nv-codec-headers-linux.md) | `linux64`, `linuxarm64` | shipping, gated |
| [0002 — nv-codec-headers pin, windows](patches/0002-nv-codec-headers-windows.md) | `win64`, `winarm64` | shipping, gated |
| [0003 — VAAPI import of alpha 10-bit RGB DRM formats](patches/0003-vaapi-alpha-10bit-rgb.md) | all targets | shipping, verified on hardware; not gateable |
| [0004 — Dolby Vision RPU passthrough for hevc_vaapi](patches/0004-dolby-vision-hevc-vaapi.md) | all targets, linux-only feature | shipping, verified on hardware |
| [0005 — options on a derived hardware device](patches/0005-allow-options-on-derived-hw-devices.md) | all targets | shipping, verified on hardware; not gateable |

Adding a patch means adding a doc here and a `checks/NNNN.checks` declaration. Both are enforced by
the gate — see below.

## Topics

- **[The verification gate](verification-gate.md)** — how a built binary is proven to carry what
  the patches add, how to declare a new patch for it, and how to check a downloaded asset by hand.
- **[The nv-codec-headers pin](nv-codec-headers-pin.md)** — the shared story behind `0001` and
  `0002`: three independent build systems, only two of them patched, and the silent failure that
  produced the gate.
- **[The local build loop](local-build-loop.md)** — build ffmpeg from this source in about a
  minute and rebuild in about five seconds, instead of spending 2.5 hours in CI to ask a question.

## Conventions

Everything in `docs/` is **published** — this repo is public. Hostnames, image tags, fleet paths
and machine names do not belong here; hardware and driver versions do, where they are evidence for
a measurement. Working notes that need real detail live in `tasks/`, `plans/` and `handoffs/`,
which are gitignored.
