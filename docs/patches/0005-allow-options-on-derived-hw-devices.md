# 0005 — options on a derived hardware device

| | |
|---|---|
| **Status** | Shipping. Verified on hardware: reachable, and confirmed to reach the frames allocation. |
| **Covers** | All targets — goes into `debian/patches/` as `0902`, so every build system applies it |
| **Retires when** | Upstream FFmpeg lets the `@` form of `-init_hw_device` carry options |
| **Gate** | `checks/0005.checks` — declared `ungateable`, with the reason. CLI argument parsing appears in neither `-h encoder=` nor `-filters`. |

## What it does

Lets `-init_hw_device <type>=<name>@<source>` carry device options after a comma, and creates the
device with `av_hwdevice_ctx_create_derived_opts()` instead of `av_hwdevice_ctx_create_derived()`:

```
-init_hw_device vulkan=vk@dr,disable_multiplane=1
```

Without a comma nothing changes — `options` stays `NULL` and the call is equivalent to the one it
replaces.

## Why it exists

**No device option can reach a derived device at all.** The `'@'` branch of
`hw_device_init_from_string()` (`fftools/ffmpeg_hw.c`) passes the entire remainder of the string to
`hw_device_get_by_name()`, so a comma and everything after it become part of the source device name:

```
Invalid device specification "vulkan=vk@dr,disable_multiplane=1": invalid source device name
```

**That error reads like a typo and is not one.** It looked for a device literally called
`dr,disable_multiplane=1`. Hunting for a separator that works is wasted effort: the branch never
parses options, because `av_hwdevice_ctx_create_derived()` takes no `AVDictionary`. The `':'` branch a
few lines above already contains the parsing this needs, and
`av_hwdevice_ctx_create_derived_opts()` already exists.

Vulkan's `disable_multiplane` is the option that exposed this, and it is genuinely unreachable
otherwise: `vulkan_device_derive()` forwards `opts`, and its `AV_HWDEVICE_TYPE_DRM` case passes the
function argument as `0`, so `vulkan_device_create_internal()` falls through to the dictionary value —
which no command line can set. A standalone Vulkan device *can* take the option, but a standalone
device cannot derive back to VAAPI, so it is not a substitute.

## What is proven, and what is not

**Proven on RX 9070 XT / Mesa 26.2.0, ffmpeg 8.1.2:**

| | before | after |
|---|---|---|
| `vulkan=vk@dr` (control) | ok | ok |
| `vulkan=vk@dr,disable_multiplane=1` | `invalid source device name` | ok |
| `vulkan=vk@nosuchdev,disable_multiplane=1` | — | correctly rejected |

**And the option reaches the frames allocation**, confirmed with a temporary log in
`vulkan_frames_init()`: the effective `disable_multiplane` goes from `0` to `1` for a `p010le` frames
context, so the format is allocated as two separate single-plane images rather than one two-plane
image.

**NOT a throughput win, and this is measured rather than assumed.** The patch was written expecting
`disable_multiplane=1` to make a `p010le` libplacebo output export to VAAPI as cheaply as a
single-plane RGB one. **It does not.** Three runs each, one batch, GPU clocks pinned, 1451 frames of
4K HDR through libplacebo to `hevc_vaapi`:

| libplacebo output | time |
|---|---|
| `bgra` (RGB), VPP converts to `p010` | **9.6 s** |
| `p010le` (YUV), one 2-plane image | 19.9 s |
| `p010le` (YUV), **two single-plane images** — this patch | **19.9 s** |

So plane count is not what makes a YUV libplacebo output expensive on this hardware; something about
producing YUV rather than RGB is. **The patch is worth having because the CLI gap is real and affects
every device option, not because it made anything faster here.**

## Gotchas

- **The separator is a comma**, matching the `':'` form: `type=name@source,opt=val,opt2=val2`.
- **An empty source name is still an error.** `type=name@,opt=val` looks up `""` and fails with
  `invalid source device name`, which is the correct outcome.
- **No new cleanup.** The parsed name and options are freed at the function's existing `done:` label,
  which every path already reaches.
- **A standalone Vulkan device is not a workaround.** It accepts options but cannot
  `hwmap=derive_device=vaapi` back — that only works when the Vulkan device was itself derived from
  the DRM node.

## How it was diagnosed

By reading the branch, after the error message sent the search in the wrong direction. Several
separators were tried against `vulkan=vk@dr` on the assumption that the syntax was wrong; all failed
identically, because the remainder of the string is consumed as a device name no matter what is in it.

The fix became obvious only from the source: `av_hwdevice_ctx_create_derived_opts()` is declared right
beside the non-`_opts` variant in `libavutil/hwcontext.h`, and the option-parsing block needed is
twelve lines above the `'@'` branch in the same function.
