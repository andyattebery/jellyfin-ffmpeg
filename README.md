# jellyfin-ffmpeg + nv-codec-headers n13.0.19.1

A **build recipe**, not a fork of the ffmpeg source. Nothing here is a copy of upstream: each
build checks out [`jellyfin/jellyfin-ffmpeg`](https://github.com/jellyfin/jellyfin-ffmpeg) at a
release tag, applies `patches/`, builds, and publishes the binaries as a release.

**Scope: the four portable targets — `linux64`, `linuxarm64`, `win64` and `winarm64`.** Upstream
builds 18 artifacts; this builds 4. There are **no `.deb` packages here** — those come from a
separate upstream build system with its own unpatched header pin. See
[What this does NOT build](#what-this-does-not-build).

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
`msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD`. Patching only the first produces
windows binaries with NVENC but *without* `-tune uhq`, `-tf_level`, `-lookahead_level` or
`-split_encode_mode`, because `libavcodec/nvenc.h` gates them behind
`NVENCAPI_CHECK_VERSION(12, 2)` and n12.0.16.1 reports API 12.0. That is not hypothetical — a
win64 asset shipped that way once. It is also why the split is by *build system* and not by
platform: each of those two files feeds both an amd64 and an arm64 target.

## What this does NOT build

Upstream produces **18 artifacts**. This repo builds **4**.

The patches attach to a *build system*, not to a target, which is why the arm64 pair was nearly
free — the same two patches cover all four portable targets, and all four run in parallel, so
adding them changed nothing about wall clock:

| artifact | built here | covered by |
|---|---|---|
| `linux-amd64-portable` | **yes** | 0001 — `builder/scripts.d` |
| `linux-arm64-portable` | **yes** | 0001 — same `builder/scripts.d`; `builder/build.sh:27` sources them regardless of target |
| `win-clang-win64-portable` | **yes** | 0002 — `msys2/PKGBUILD` |
| `win-clang-winarm64-portable` | **yes** | 0002 — same dir; `msys2/buildarm64.sh:17` loops over it exactly as `build.sh:17` does |
| `mac-x86_64-portable`, `mac-arm64-portable` | no | **n/a** — `50-ffnvcodec.sh:7` returns -1 for `mac*`, so ffnvcodec is off there entirely. A mac build from this repo would be identical to upstream's; there is no reason to produce one. |
| `debian-{bullseye,bookworm,trixie}-{amd64,arm64}` | no | **nothing** |
| `ubuntu-{jammy,noble,resolute}-{amd64,arm64}` | no | **nothing** |

**The 12 `.deb` packages are the one real gap.** They come from a third, separate build system
(`Dockerfile.in` + `docker-build.sh`) with its **own** nv-codec-headers pin that neither patch
touches. Two consequences:

- this repo publishes **no `.deb`** — install jellyfin-ffmpeg from a package and you get stock,
  without `-tune uhq`
- if `.deb` builds are ever added here, **the patch series as it stands would silently produce
  packages with the old headers.** That is the same failure that already shipped a broken win64
  asset once: a build system whose pin nobody patched, failing quietly rather than loudly.

Adding `.deb` is therefore a different proposition from adding the arm64 targets was: a different
build system, a third patch, and roughly triple the matrix.

## Driver floor

**570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to 610.0, which is
why the pin stops where it does.

## Layout

```
patches/jellyfin-ffmpeg/          applied in filename order with `git apply`
  0001  linux   nv-codec-headers pin   builder/scripts.d/50-ffnvcodec.sh      (amd64 + arm64)
  0002  windows nv-codec-headers pin   msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers
                                                                              (win64 + winarm64)
.github/workflows/build-release.yaml   resolve -> build all four -> verify -> publish
.github/scripts/resolve-upstream.sh    which upstream release to build; --self-test, --plan
.github/scripts/verify-binary.sh       the gate: asks ffmpeg whether the build has the features
```

## How it runs

Daily at **06:17 UTC** (GitHub often delays scheduled runs by 30-40 min), or on demand:

```bash
gh workflow run build-release.yaml --ref main                       # same as the cron
gh workflow run build-release.yaml --ref main -f mode=smoke         # ~3 min, no compile
gh workflow run build-release.yaml --ref main -f force=true         # rebuild an existing tag
gh workflow run build-release.yaml --ref main -f tag=v8.1.3-1       # pin a specific upstream tag
```

| input | default | what it does |
|---|---|---|
| `mode` | `full` | `full` builds for real; `dry_run` exercises only the release path (~3 min); `smoke` runs everything except the compile (~3 min) |
| `force` | `false` | rebuild even when this upstream tag is already released here |
| `tag` | newest `v8.*` | build a specific upstream tag instead of resolving the newest |

**On a normal day it does nothing**: upstream has no new release, so `resolve` reports
`proceed=false`, the four build jobs, the arm64 verify job and the release job all skip, and the
run finishes in about a minute. A new upstream 8.x tag is what triggers a real ~2.5h build.

## The verification gate

Every published binary is checked by `verify-binary.sh` before the release job runs. If one does
not carry the features, its job fails and nothing is published — the release keeps its previous
assets.

It asks ffmpeg rather than grepping the binary: `-h encoder=hevc_nvenc` reads the encoder's
static AVOption table and `-filters` the compiled-in filter list, neither of which loads the
NVIDIA driver, so it works on a GPU-less runner. **It must run on the binary's own platform**,
and that is what decides where it runs:

| target | where it is verified | why |
|---|---|---|
| `linux64` | in the build job | job runs on x86-64, binary is x86-64 |
| `win64` | in the build job | `windows-latest` is x86-64 |
| `winarm64` | in the build job | `windows-11-arm` is native arm64, so `msys2/buildarm64.sh` and the check both run in place |
| `linuxarm64` | **separate `verify_linux_arm64` job on `ubuntu-24.04-arm`** | `builder/images/base-linuxarm64/` is a crosstool-NG **cross** toolchain that runs on an x86-64 host, so the build job cannot execute what it just produced |

The arm64 linux exception is not a weaker gate: `release` requires `verify_linux_arm64` to
succeed, so an unverified binary exists as a CI artifact and never reaches a release. The one
difference is ordering — it is checked after upload rather than before.

This whole section exists because a win64 asset was once published with NVENC but none of the
tuning options. Every check in the pipeline at the time was about plumbing; nothing looked inside
the binary.

## The pin lives in three independent build systems

jellyfin-ffmpeg contains three unrelated build systems, each pinning nv-codec-headers its own
way. Patching one does not touch the others, and the failure is silent — you get a binary with
NVENC but without the options. Check all of them on any future bump:

| build system | produces | pins the headers in | patched |
|---|---|---|---|
| `builder/` (BtbN-derived) | portable linux **amd64 + arm64**, mac | `scripts.d/50-ffnvcodec.sh` | **0001** — covers both linux targets, and both are built and verified here |
| `msys2/` | portable **win64 + winarm64** clang | `PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD` | **0002** — covers both, `build.sh:17` and `buildarm64.sh:17` share the dir; both built and verified here |
| `Dockerfile.in` + `docker-build.sh` | 12 `.deb` packages | `docker-build.sh` — inline `git clone -b n12.0.16.1` | **no** — this repo builds no debs |

(`Dockerfile.win64.in` + `docker-build-win64.sh` is a fourth, for the gcc win64 build upstream
has disabled.) Those scripts are reached via `ENTRYPOINT`, not a call site, so grepping for
`./docker-build.sh` finds nothing and is misleading.

`configure` also gates on the version, but needs no patch: its chain's first branch is
`ffnvcodec >= 12.1.14.0` with no upper bound, which accepts 13.x.

**If .deb builds are ever added here, they need a third patch** — otherwise they silently ship
the old headers.

## Build time

All four build jobs run in parallel and the release waits on all of them, so wall clock is the
slowest single job — about **145 min**, the same as it was with two jobs. Measured on one
upstream run (`31869623375`, so the numbers are comparable): linux amd64 143 min, linuxarm64 135,
winarm64 136, win64 107.

Most of that is dependency toolchain rather than ffmpeg, not the compile: linux spends roughly
122 of its 143 min building the docker toolchain image, and windows roughly 88 of its ~105 in
`makepkg`. Both are cacheable if that ever becomes worth the added moving parts; it is
deliberately not done here.

## Reproducing a build by hand

```bash
git clone -b v8.1.2-2 https://github.com/jellyfin/jellyfin-ffmpeg.git
cd jellyfin-ffmpeg
git apply /path/to/patches/jellyfin-ffmpeg/*.patch

./build-linux-amd64 ./dist     # linux64    — needs docker; ~2.5h
./build-linux-arm64 ./dist     # linuxarm64 — needs docker; cross-compiled on an x86-64 host
./msys2/build.sh               # win64      — needs msys2 CLANG64
./msys2/buildarm64.sh          # winarm64   — needs msys2 CLANGARM64 on arm64 windows
```

## Releases

Tagged `<upstream-tag>+nvenc-<pin>`, e.g. `v8.1.2-2+nvenc-n13.0.19.1`. Assets carry
`-nvenc-<pin>` in the filename, because upstream names its assets from `debian/changelog` alone —
without it a build from here is byte-identically named to a stock one, which matters when the
file is downloaded by hand. Four assets per release:

```
jellyfin-ffmpeg_<ver>-nvenc-<pin>_portable_linux64-gpl.tar.xz
jellyfin-ffmpeg_<ver>-nvenc-<pin>_portable_linuxarm64-gpl.tar.xz
jellyfin-ffmpeg_<ver>-nvenc-<pin>_portable_win64-clang-gpl.zip
jellyfin-ffmpeg_<ver>-nvenc-<pin>_portable_winarm64-clang-gpl.zip
```

The release job asserts those four names exactly, then asserts the count — identity before
cardinality, because a count of 4 passes just as happily for four *wrong* files.

Deployment globs are unambiguous between architectures and `--self-test` pins that down:
`*portable_linux64-gpl*` does not match a `linuxarm64` asset (`linux64` is not a substring of
`linuxarm64`), and `*portable_win64-clang-gpl*` does not match a `winarm64` one.

## Retiring this

If upstream ever bumps its own pin, `git apply` stops applying and the build fails loudly. That
is the signal: delete this repo and use stock jellyfin-ffmpeg.

## Checking a built binary by hand

CI already does this on every build (see above). To repeat it on a downloaded asset, run the
same script the pipeline runs, on a machine of that binary's platform:

```bash
.github/scripts/verify-binary.sh /path/to/ffmpeg       # exit 0 = has everything
```

Or directly:

```bash
./ffmpeg -h encoder=hevc_nvenc | grep -E 'uhq|tf_level|lookahead_level|split_encode'
./ffmpeg -filters | grep tonemap_cuda
```

This is worth knowing for the arm64 assets in particular: an x86-64 machine cannot execute either
of them, which is the same constraint that puts the `linuxarm64` gate in its own job in CI.

If you cannot execute the binary — checking a win64 build from Linux, or either arm64 build from
an x86-64 host — `strings` is the fallback, but **an absence found with `grep` means nothing
without a positive control**. Check that something you *know* is present also shows up, or you
have only proven your search was wrong:

```bash
strings ffmpeg.exe | grep -cF "Specifies the strength of the temporal filtering"  # expect >=1
strings ffmpeg.exe | grep -cF "NVIDIA NVENC hevc encoder"                         # control, expect 1
```

## Testing a change without waiting 2.5 hours

```bash
.github/scripts/resolve-upstream.sh --self-test   # ~1s, no network
.github/scripts/resolve-upstream.sh --plan        # what it would build, changes nothing
git apply --check patches/jellyfin-ffmpeg/*.patch # against an upstream checkout
```

Then dispatch with `mode: dry_run` or `mode: smoke` — both about **3 minutes**, measured. Only
`mode: full` costs hours.

**What `smoke` still cannot tell you**, so you know what a green smoke run is worth:

- the compile, and therefore the verification gate reading a real binary
- **the publish path a real release takes.** `full` updates an existing release in place
  (`gh release edit` + `gh release upload --clobber`) and marks it `--latest`; `smoke` and
  `dry_run` delete-and-recreate, set `--prerelease --latest=false`, and publish to a separate
  `-smoke` / `-dryrun` tag. A test run never touches the real release, which is the point — but
  it also means that code path is only ever exercised by a real one.

So a green smoke run proves plumbing: resolution, patching, artifact names and layout, the
four-asset assertion, and that every runner label allocates. It does not prove the binaries or
the release update.
