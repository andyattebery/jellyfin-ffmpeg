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
| jellyfin-ffmpeg (stock) | ✅ | ❌ — pins nv-codec-headers `n12.0.16.1` |
| BtbN / vanilla FFmpeg builds | ❌ — it's a jellyfin patch | ✅ |
| **this** | ✅ | ✅ |

`tonemap_cuda` comes from `0004-add-cuda-tonemap-impl.patch`, one of 97 patches in
jellyfin-ffmpeg's `debian/patches/series`, so no vanilla build has it. And jellyfin-ffmpeg pins
nv-codec-headers at `n12.0.16.1`, which predates `NVENC_HAVE_UHQ_TUNING`. One binary needs both,
and nobody publishes it.

**Not sent upstream on purpose.** The low pin keeps the NVIDIA driver floor at 520.56.06 for
older cards; `n13.0.19.1` raises it to **570.0**, which would drop users. That is a reasonable
call for upstream and the wrong one for this fleet, so it lives here.

## Driver floor

**570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to 610.0, which is
why the pin stops where it does.

## Layout

```
patches/jellyfin-ffmpeg/    applied in filename order with `git apply`
.github/workflows/          the build
.github/scripts/            upstream resolution + its self-test
```

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

## Testing a change without waiting 2.5 hours

```bash
.github/scripts/resolve-upstream.sh --self-test   # ~1s, no network
.github/scripts/resolve-upstream.sh --plan        # what it would build, changes nothing
git apply --check patches/jellyfin-ffmpeg/*.patch # against an upstream checkout
```

Then dispatch the workflow with `mode: dry_run` (~3 min — release path only) or `mode: smoke`
(~6 min — the whole pipeline except the compile). Only `mode: full` costs hours.
