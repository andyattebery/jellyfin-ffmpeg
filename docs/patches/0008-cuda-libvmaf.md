# 0008 — CUDA-accelerated VMAF (`libvmaf_cuda`), linux64

| | |
|---|---|
| **Status** | Shipping. Gated on the linux64 build. |
| **Covers** | `linux64` **only** — not `linuxarm64`, not the two windows targets |
| **Retires when** | Upstream jellyfin-ffmpeg adds libvmaf to `builder/scripts.d` itself |
| **Gate** | `checks/0008.checks` — two `filter` checks, declared `linux64` |
| **Also carries** | the [Netflix/vmaf#1566](https://github.com/Netflix/vmaf/issues/1566) motion-stride fix, without which 10-bit scores are ~1.06 VMAF low — see [0009](0009-libvmaf-cuda-10bit.md) |

## What it does

Adds `builder/scripts.d/55-libvmaf.sh`: builds Netflix libvmaf **v3.2.0** with
`-Denable_cuda=true` and emits `--enable-libvmaf`.

One flag yields two filters. `configure:7391` requires libvmaf; `configure:7392` then does a
*non-fatal* `check_pkg_config` for `libvmaf_cuda.h` + `vmaf_cuda_state_init`, so `libvmaf_cuda`
appears only when the linked libvmaf was itself built with CUDA. No licence flags change —
libvmaf is in the plain `EXTERNAL_LIBRARY_LIST` (`configure:2101`), not the nonfree or version3
list. The `--enable-nonfree` in FFmpeg's own `libvmaf_cuda` documentation is wrong.

## Why it needs a CUDA toolkit when the build already does CUDA

The CUDA already in the build is header-only. `50-ffnvcodec.sh` installs nv-codec-headers and
emits `--enable-cuda-llvm`; ffmpeg then compiles its own `.cu` kernels with **clang**, using
`-nocudainc -nocudalib -include compat/cuda/cuda_runtime.h` (`configure:7120`), and converts the
PTX with its own `tools/bin2c.c` (`ffbuild/common.mak:164-168`). No nvcc, no CUDA headers.

libvmaf is a separate meson project and does neither. Its meson calls `find_program('bin2c')` —
CUDA's `bin2c`, a different program from ffmpeg's — and its device compile does **not** pass
`-nocudainc -nocudalib`. Those two flags sit in `libvmaf/src/meson.build` commented out, with the
note *"many complaints about device intrinsics when compiling without CTK and the ffmpeg cuda
runtime header."* The gap is not closable by flags: vmaf's kernels `#include <vector>`,
`<algorithm>` and `<iostream>` in device translation units, and ffmpeg's shim header is a few
hundred lines of intrinsic declarations. The VMAF CUDA author tried exactly this
(`gedoensmax/vmaf:clang_cuda_compat`, [BtbN/FFmpeg-Builds#328]) and reported it *"not correct and
non performant"*. Treat that route as closed.

The toolkit is **build-time only** and lives in one discarded layer: `ffbuild_dockerlayer` copies
only `$FFBUILD_PREFIX` forward, so nvcc reaches neither the ffmpeg build stage nor the shipped
image. At runtime libvmaf `dlopen`s `libcuda.so.1` through `ffnvcodec/dynlink_loader.h`, exactly
as ffmpeg does — `ldd ffmpeg` shows no CUDA or vmaf dependency, and the tarball still runs on a
machine with no NVIDIA driver.

## Why BtbN refuses this and we do not

BtbN declines `libvmaf_cuda` ([#328], [#353]) because they **publish their build images to ghcr**
and cannot redistribute the CUDA SDK. This repo publishes only the tarball: `build-release.yaml:174`
runs `./build-linux-amd64`, which has `builder/makeimage.sh` push to a throwaway `registry:2`
container on `127.0.0.1` and `--load` locally on an ephemeral runner.

Their second reason — *"cannot be statically linked … requires an installed NVIDIA driver"* — is
stale. In that same thread the VMAF CUDA author states he moved libvmaf to dynamic driver loading,
and the `ldd` result above confirms it on a real binary.

## Why CUDA 13.2, exactly

Not a free choice. **Everything from 12.8 through 13.1 fails to compile at all** against the base
image's glibc 2.43: CUDA's `crt/math_functions.h` collides with `bits/mathcalls.h` over
`cospi`/`sinpi`/`cospif`/`sinpif`/`rsqrt`/`rsqrtf` — *"exception specification is incompatible with
that of previous function"* — and nvcc's host pass includes `math.h` even for a device-only
`--fatbin`. The colliding glibc declarations sit behind `__GLIBC_USE (IEC_60559_FUNCS_EXT_C23)`,
which `features.h` defines unconditionally under `_GNU_SOURCE`, so there is no macro knob. Measured
on `ubuntu:resolute`:

| CUDA | 12.8 | 12.9 | 13.0 | 13.1 | **13.2** | 13.3 |
|---|---|---|---|---|---|---|
| bare `nvcc --fatbin` | fail | fail | fail | fail | **ok** | ok |

13.2 also clears the gcc-15 host check, so no `-ccbin` and no `-allow-unsupported-compiler` are
needed. 13.3 is not used: it is a newer toolkit than the fork's target drivers report.

### The cost, stated plainly

13.x fails libvmaf's own `version_compare('<13')` guard, so **no `compute_50` PTX fallback is
emitted**. The gencode set actually produced, read out of `build.ninja`:

```
compute_75/sm_75   compute_80/sm_80   compute_90/sm_90
compute_100/sm_100 compute_120/sm_120 compute_120 (PTX)
```

So `libvmaf_cuda` covers **Turing and newer**, and needs a **580+** driver (CUDA minor-version
compatibility: 13.x-built code runs on the 13.0 minimum). Maxwell and Pascal get nothing.

This does **not** move the fork's driver floor. Only this one filter is affected — the CPU
`libvmaf` filter, NVENC, and [patch 0001](0001-nv-codec-headers-linux.md)'s 570.0 floor are all
untouched, because libvmaf `dlopen`s the driver and only that filter fails if the module will not
load.

Keeping CUDA 12.8 was possible two ways and both were rejected: pointing nvcc at the crosstool-ng
sysroot's glibc 2.28 (`-ccbin x86_64-ffbuild-linux-gnu-g++`) welds the patch to the ct-ng triplet
and still needs a gcc-15 override; seding the six declarations out of CUDA's vendor header rots the
moment CUDA or glibc moves.

## Three things only the cross build needs

Neither reproduces in a native build, which is why both were found by running the stage inside
`base-linux64` rather than by any amount of testing on a plain distro image.

1. **A second `--cross-file`.** `libvmaf/src/meson.build:366` calls
   `add_languages('cuda', required: true)`. Natively, meson is satisfied by `nvcc` on `PATH`; in a
   cross build it refuses outright —
   `ERROR: 'cuda' compiler binary not defined in cross file [binaries] section` — because
   `builder/images/base-linux64/cross.meson` lists only `c`, `cpp`, `ld`, `ar`, `ranlib`, `strip`.
   The script writes a two-line overlay naming nvcc and passes it as a second `--cross-file`;
   meson merges them in order. Nothing upstream is patched.

   This is also the hard reason for linux64-only. linux64 is x86_64 → x86_64, so nvcc really is a
   valid compiler for the host machine. On arm64, meson would sanity-check nvcc as an *aarch64*
   host compiler, which it is not.

2. **`NVCC_PREPEND_FLAGS="-I$FFBUILD_PREFIX/include"`.** The `.fatbin` `custom_target`s build their
   own `-I` list and inherit nothing — not `CFLAGS`, not meson's include dirs — but
   `cuda_helper.cuh:32` includes `<ffnvcodec/dynlink_loader.h>`. Distro builds never notice,
   because ffnvcodec lands in `/usr/local/include` which nvcc already searches; here it is under
   `$FFBUILD_PREFIX`. nvcc reads `NVCC_PREPEND_FLAGS` itself, so it reaches commands meson passes
   nothing to.

3. **`-ldl` in `Libs.private`, not just `-lstdc++`.** `cuda/common.c` `dlopen`s the driver.
   glibc folded `dlopen` into libc at 2.34, but `ct-ng-config` pins `CT_GLIBC_VERSION="2.28"`, so
   this toolchain still needs libdl. Without it, configure's link test fails with
   `undefined reference to dlopen` from `cuda_common.c.o` — reported, as ever, as
   `libvmaf >= 2.0.0 not found using pkg-config`.

## Three things in the script that look arbitrary and are not

1. **The prefix is `55`, not `50` or BtbN's `45`.** `builder/generate.sh` starts every stage in a
   prefix group `FROM $PREVLAYER` — the *previous* group's layer — and merges them only afterwards.
   A `50-libvmaf.sh` would branch from `layer-47` and never see `50-ffnvcodec.sh`'s headers, so
   `cc.has_header('ffnvcodec/dynlink_cuda.h')` fails and the CUDA block `error()`s out. BtbN's
   script sits at `45` precisely because it is CPU-only.

2. **The meson build dir is `libvmaf/build`, inside the checkout.** The `.fatbin` `custom_target`s
   use relative includes (`-I ../src`, `-I ../include`, `-I ../src/feature`) that resolve only one
   level under the source root. BtbN's `mkdir build && cd build; meson ../libvmaf` breaks every
   `.cu` with `fatal error: feature_collector.h: No such file or directory` — it works for them
   only because their build has no CUDA and those targets never run. **Do not copy their layout.**

3. **`--libdir=lib`.** meson otherwise installs to a multiarch libdir, while the image sets
   `PKG_CONFIG_LIBDIR=$FFBUILD_PREFIX/lib/pkgconfig` — the `.pc` would land where configure never
   looks. The `Libs.private` additions above are only honoured because `FFBUILD_TARGET_FLAGS`
   carries `--pkg-config-flags=--static`; if that ever goes away, every one of these failures
   reports itself as `ERROR: libvmaf >= 2.0.0 not found using pkg-config` while the real error is a
   link error several hundred lines down `config.log`.

## Why linux64 only

- **linuxarm64** is excluded by mechanism, not preference. `add_languages('cuda', required: true)`
  makes meson sanity-check nvcc *as a compiler for the host machine*. On linux64 that is
  x86_64 → x86_64, so nvcc genuinely is one and the overlay cross file above is enough. On arm64 it
  would have to be an aarch64 host compiler, which nvcc is not. The audience is thin anyway: arm64
  jellyfin hosts are overwhelmingly Rockchip and Raspberry Pi with no NVIDIA GPU at all.
- **win64 / winarm64** come from `msys2/build.sh`, which loops `makepkg-mingw` over
  `msys2/PKGBUILD/*` on a Windows runner under clang64. nvcc on Windows requires MSVC, which is not
  in that environment, and GitHub Windows runners carry no CUDA. A **CPU-only**
  `55-mingw-w64-libvmaf` PKGBUILD would be straightforward and is the obvious follow-up if the
  plain `libvmaf` filter is wanted on Windows; a CUDA one is a research project.

## Gate

```
filter  linux64  libvmaf
filter  linux64  libvmaf_cuda
```

**This patch is why the check grammar grew an arch tier.** `verify-binary.sh` previously inferred
platform only from whether the path ends in `.exe`, and both linux jobs pass a path named `ffmpeg`
— so a `filter linux` declaration would have been asserted against the linuxarm64 asset, where
this patch deliberately builds nothing. The script now takes the target as an optional second
argument, `VALID_PLATFORMS` gained `linux64`/`linuxarm64`/`win64`/`winarm64`, and all four call
sites in `build-release.yaml` pass theirs. A fine-grained declaration encountered with **no**
target is a hard error rather than a skip — a silent skip is the exact failure this gate exists to
prevent. See `verify-binary.sh`'s header and the `--self-test` fixtures, which include the arm64
negative control.

Both lines are load-bearing. `--enable-libvmaf` always produces the CPU `libvmaf` filter, so a
`libvmaf`-only declaration would pass a build whose CUDA half quietly no-op'd — `configure:7392`
is `check_pkg_config`, not `require_pkg_config`. The `no-vmafcuda` self-test stub is the negative
control for that claim.

These prove the filter is *present*, not that it is *correct* — and this patch now also carries a
libvmaf kernel fix, which no `-filters` check can see. Run
`verify-binary.sh --score <binary>` on a GPU host for that; see
[the gate doc](../verification-gate.md).

## Using it

`libvmaf_cuda` takes CUDA frames only (`vf_libvmaf.c:825`,
`FILTER_SINGLE_PIXFMT(AV_PIX_FMT_CUDA)`). Which *software* formats it accepts depends on whether
[0009](0009-libvmaf-cuda-10bit.md) is applied:

- **with 0009** — 4:4:4 / 4:2:2 / 4:2:0 at 8, 10, 12 and 16 bit, so 10-bit HDR and Dolby Vision
  sources go in natively with no conversion at all.
- **without it** — 8-bit `yuv420p` and `yuv444p16` only, and everything else fails config with
  `Unsupported input format: <name>` and `-22`.

Native 10-bit, no `scale_cuda`:

```bash
ffmpeg -init_hw_device cuda=cu -filter_hw_device cu -i dis.mkv -i ref.mkv \
       -lavfi "[0:v]format=yuv420p10le,hwupload_cuda[d]; \
               [1:v]format=yuv420p10le,hwupload_cuda[r]; \
               [d][r]libvmaf_cuda=log_fmt=json:log_path=out.json" \
       -f null -
```

From a CUDA decode, whose `sw_format` is `p010le`, convert first — **never feed `p010` directly**,
its luma is MSB-aligned so it would be read 64x too bright:

```bash
[0:v]scale_cuda=format=yuv420p10[d]
```

⚠ **Do not use `scale_cuda=format=yuv420p` on 10-bit input.** It does not error; it downconverts to
8-bit and returns a correct *8-bit* measurement, which differed from the true 10-bit answer by
0.031 in testing. That is a different question answered cheaply, not the answer you asked for.

Models are compiled in (`-Dbuilt_in_models=true`), so `vmaf_v0.6.1` works with no `model_path`.

Measured against the CPU filter on the same pair: **97.960604** CUDA versus **97.960520** CPU at
10-bit, and **97.929946** versus **97.929863** at 8-bit.

[BtbN/FFmpeg-Builds#328]: https://github.com/BtbN/FFmpeg-Builds/issues/328
[#328]: https://github.com/BtbN/FFmpeg-Builds/issues/328
[#353]: https://github.com/BtbN/FFmpeg-Builds/issues/353
