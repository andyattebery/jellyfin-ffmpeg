# jellyfin-ffmpeg + nv-codec-headers n13.0.19.1

A **build recipe**, not a fork of the ffmpeg source. Nothing here is a copy of upstream: each
build checks out [`jellyfin/jellyfin-ffmpeg`](https://github.com/jellyfin/jellyfin-ffmpeg) at a
release tag, applies `patches/`, builds, and publishes the binaries as a release.

Same shape as [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), which
jellyfin-ffmpeg's own `builder/` directory is derived from.

## Why this exists

Two machines need to run the *same* ffmpeg so a transcode job can go to either:

| | `tonemap_cuda` | `-tune uhq` |
|---|---|---|
| jellyfin-ffmpeg (stock) | yes | no — pins nv-codec-headers `n12.0.16.1` |
| BtbN / vanilla FFmpeg builds | no — it's a jellyfin patch | yes |
| **this** | yes | yes |

`tonemap_cuda` comes from `0004-add-cuda-tonemap-impl.patch`, one of 97 patches in
jellyfin-ffmpeg's `debian/patches/series`, so no vanilla build has it. And jellyfin-ffmpeg pins
nv-codec-headers at `n12.0.16.1`, which predates `NVENC_HAVE_UHQ_TUNING`. One binary needs both,
and nobody publishes it.

**Not sent upstream on purpose.** The low pin keeps the NVIDIA driver floor at 520.56.06 for
older cards; `n13.0.19.1` raises it to **570.0**, which would drop users. That is a reasonable
call for upstream and the wrong one for this fleet, so it lives here.

**Linux and Windows pin the headers in two different places**, and both need bumping — this is
easy to get wrong. Linux uses `builder/scripts.d/50-ffnvcodec.sh`; Windows uses
`msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD`. Patching only the first produces a
win64 binary with NVENC but *without* `-tune uhq`, `-tf_level`, `-lookahead_level` or
`-split_encode_mode`, because `libavcodec/nvenc.h` gates them behind
`NVENCAPI_CHECK_VERSION(12, 2)` and n12.0.16.1 reports API 12.0.

## Driver floor

**570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to 610.0, which is
why the pin stops where it does.

## Layout

```
patches/jellyfin-ffmpeg/    applied in filename order with `git apply`
  0001  linux   nv-codec-headers pin   builder/scripts.d/50-ffnvcodec.sh
  0002  windows nv-codec-headers pin   msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers
.github/workflows/          the build
.github/scripts/            upstream resolution + its self-test
```

### The pin lives in three independent build systems

jellyfin-ffmpeg contains three unrelated build systems, each pinning nv-codec-headers its own
way. Patching one does not touch the others, and the failure is silent — you get a binary with
NVENC but without the options. Check all of them on any future bump:

| build system | produces | pins the headers in | patched |
|---|---|---|---|
| `builder/` (BtbN-derived) | portable linux, mac | `scripts.d/50-ffnvcodec.sh` | **0001** |
| `msys2/` | portable win64 clang | `PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD` | **0002** |
| `Dockerfile.in` + `docker-build.sh` | `.deb` packages | `docker-build.sh` — inline `git clone -b n12.0.16.1` | no — this repo builds no debs |

(`Dockerfile.win64.in` + `docker-build-win64.sh` is a fourth, for the gcc win64 build upstream
has disabled.) Those scripts are reached via `ENTRYPOINT`, not a call site, so grepping for
`./docker-build.sh` finds nothing and is misleading.

`configure` also gates on the version, but needs no patch: its chain's first branch is
`ffnvcodec >= 12.1.14.0` with no upper bound, which accepts 13.x.

**If .deb builds are ever added here, they need a third patch** — otherwise they silently ship
the old headers.

## Build time

Both build jobs run in parallel and the release waits on both, so wall clock is the slower of
the two — about 145 min. Most of it is dependency toolchain rather than ffmpeg: linux spends
~122 of 143 min building the docker toolchain image, windows ~88 of 104 in `makepkg`. Both are
cacheable if that ever becomes worth the added moving parts; it is deliberately not done here.

## Reproducing a build by hand

```bash
git clone -b v8.1.2-2 https://github.com/jellyfin/jellyfin-ffmpeg.git
cd jellyfin-ffmpeg
git apply /path/to/patches/jellyfin-ffmpeg/*.patch
./build-linux-amd64 ./dist      # needs docker; ~2.5h
```

## Releases

Tagged `<upstream-tag>+nvenc-<pin>`, e.g. `v8.1.2-2+nvenc-n13.0.19.1`. Assets carry
`-nvenc-<pin>` in the filename, because upstream names its assets from `debian/changelog` alone —
without it a build from here is byte-identically named to a stock one, which matters when the
file is downloaded by hand.

## Retiring this

If upstream ever bumps its own pin, `git apply` stops applying and the build fails loudly. That
is the signal: delete this repo and use stock jellyfin-ffmpeg.

## Checking a built binary actually has the features

An absence found with `grep` means nothing without a positive control — check that a string you
*know* is there also shows up, or you are only proving your search was wrong.

```bash
strings ffmpeg | grep -cF "Specifies the strength of the temporal filtering"  # expect 1
strings ffmpeg | grep -cF "hevc_nvenc"                                        # control, expect 1
```

Or definitively, on a machine that can run it:

```bash
./ffmpeg -h encoder=hevc_nvenc | grep -E 'uhq|tf_level|lookahead_level|split_encode'
./ffmpeg -filters | grep tonemap_cuda
```

## Testing a change without waiting 2.5 hours

```bash
.github/scripts/resolve-upstream.sh --self-test   # ~1s, no network
.github/scripts/resolve-upstream.sh --plan        # what it would build, changes nothing
git apply --check patches/jellyfin-ffmpeg/*.patch # against an upstream checkout
```

Then dispatch the workflow with `mode: dry_run` (~3 min — release path only) or `mode: smoke`
(~6 min — the whole pipeline except the compile). Only `mode: full` costs hours.
