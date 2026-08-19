# 0002 — nv-codec-headers pin, msys2 (windows) build system

| | |
|---|---|
| **Status** | Shipping. Gated on every windows build. |
| **Covers** | `win64` **and** `winarm64` — one directory feeds both |
| **Retires when** | Upstream bumps its own nv-codec-headers pin, at which point `git apply` fails loudly |
| **Gate** | `checks/0002.checks` — four `encoder-option` checks on `hevc_nvenc`, declared `windows` |

## What it does

Moves `pkgver` and `_tag` in `msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD` from
`12.0.16.1` / `n12.0.16.1` to **`13.0.19.1`** / **`n13.0.19.1`**.

Identical in intent to [`0001`](0001-nv-codec-headers-linux.md), in a completely unrelated file.
The shared rationale is in [the nv-codec-headers pin](../nv-codec-headers-pin.md).

## Why this patch exists separately at all

**This is the file that was missed.** A win64 asset shipped with NVENC and none of the tuning
options because only `builder/scripts.d` had been patched, and nothing in the pipeline looked
inside the binary. That incident produced both this patch and
[the verification gate](../verification-gate.md).

`msys2/build.sh:17` and `msys2/buildarm64.sh:17` loop over the same `PKGBUILD/` directory, so one
patch covers both windows targets — the same build-system-not-target property `0001` has.

## Gate

The same four AVOptions as `0001`, declared `windows`:

```
uhq   tf_level   lookahead_level   split_encode_mode
```

**If you got here by copying `0001.checks`, the platform column is the field you must change.** A
lint rejects two files declaring the identical `(kind, platform, args)` tuple, precisely because
that copy-and-forget is the mistake this patch exists to prevent.

## Gotchas

- Do not collapse this declaration and `0001`'s into a single `all` row. Two independent pins need
  two independent declarations, or the blind spot comes back.
- The pin stops at `n13.0.19.1` because `n13.1.15.0` would raise the NVIDIA driver floor from 570.0
  to 610.0.
