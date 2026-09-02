# jellyfin-ffmpeg + nv-codec-headers n13.0.19.1

A **build recipe**, not a fork of the ffmpeg source. Nothing here is a copy of upstream: each build
checks out [`jellyfin/jellyfin-ffmpeg`](https://github.com/jellyfin/jellyfin-ffmpeg) at a release
tag, applies `patches/`, builds, and publishes the binaries as a release.

**Scope: the four portable targets — `linux64`, `linuxarm64`, `win64` and `winarm64`.** Upstream
builds 18 artifacts; this builds 4, and no `.deb` packages. See
[What this does not build](#what-this-does-not-build).

Same shape as [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), which jellyfin-ffmpeg's
own `builder/` directory is derived from.

## What the patches buy

Four things. Any one is reason enough to keep the recipe. They retire separately, with one
exception: `0007` builds on `0004`, so retiring `0004` means dealing with `0007` too.

| | |
|---|---|
| [0001](docs/patches/0001-nv-codec-headers-linux.md) / [0002](docs/patches/0002-nv-codec-headers-windows.md) | `-tune uhq`, `-tf_level`, `-lookahead_level` and `-split_encode_mode` on NVENC, across all four targets |
| [0003](docs/patches/0003-vaapi-alpha-10bit-rgb.md) | 10-bit VAAPI↔Vulkan tonemapping at the speed of the 8-bit path |
| [0004](docs/patches/0004-dolby-vision-hevc-vaapi.md) / [0007](docs/patches/0007-dolby-vision-hevc-nvenc.md) | Dolby Vision surviving a hardware HEVC encode, in one pass — `hevc_vaapi` and `hevc_nvenc` |
| [0005](docs/patches/0005-allow-options-on-derived-hw-devices.md) | device options reaching a *derived* hardware device from the command line at all |

The NVENC options are what make this binary different from every published one — nothing else ships
both `tonemap_cuda` and `-tune uhq`:

| | `tonemap_cuda` | `-tune uhq` |
|---|---|---|
| jellyfin-ffmpeg (stock) | yes | no — pins nv-codec-headers `n12.0.16.1` |
| BtbN / vanilla FFmpeg builds | no — it's a jellyfin patch | yes |
| **this** | yes | yes |

`tonemap_cuda` is one of jellyfin's own patches (98 of them at `v8.1.2-3`), so no vanilla build has it. `-tune uhq` needs
nv-codec-headers newer than the one jellyfin pins. See
[the nv-codec-headers pin](docs/nv-codec-headers-pin.md) for why upstream pins low and this repo
does not.

**Driver floor: 570.0.** Check `nvidia-smi` before installing.

## The patches

| | what it does | covers | status |
|---|---|---|---|
| [0001](docs/patches/0001-nv-codec-headers-linux.md) | nv-codec-headers pin, `builder/` | `linux64` + `linuxarm64` | shipping, gated |
| [0002](docs/patches/0002-nv-codec-headers-windows.md) | the same pin, `msys2/` | `win64` + `winarm64` | shipping, gated |
| [0003](docs/patches/0003-vaapi-alpha-10bit-rgb.md) | VAAPI import of the alpha 10-bit RGB DRM formats | all targets | shipping, verified on hardware; not gateable |
| [0004](docs/patches/0004-dolby-vision-hevc-vaapi.md) | Dolby Vision RPU passthrough for `hevc_vaapi` | all targets, linux-only feature | shipping, verified on hardware |
| [0005](docs/patches/0005-allow-options-on-derived-hw-devices.md) | options on a derived hardware device (`-init_hw_device …@src,opt=val`) | all targets | shipping, verified on hardware; not gateable |
| [0006](docs/patches/0006-disable-msys2-doxygen-doc-builds.md) | stop the msys2 packages building doxygen docs | `win64` + `winarm64` | shipping, works around a toolchain crash; not gateable |
| [0007](docs/patches/0007-dolby-vision-hevc-nvenc.md) | Dolby Vision RPU passthrough for `hevc_nvenc`; moves `0004`'s profile 8.1 conversion into a shared file | all targets | shipping, verified on hardware; **needs `0004`** |
| [0008](docs/patches/0008-cuda-libvmaf.md) | CUDA-accelerated VMAF — adds `builder/scripts.d/55-libvmaf.sh`, yielding the `libvmaf` and `libvmaf_cuda` filters | `linux64` only | shipping, gated; scored to 5 significant figures against the CPU filter |
| [0009](docs/patches/0009-libvmaf-cuda-10bit.md) | `libvmaf_cuda` accepts 10-, 12- and 16-bit, so HDR and Dolby Vision can be scored at all | `linux64` only | shipping, ungateable; **needs `0008`** |

**The docs are canonical**; this table is an index.

The two kinds behave differently. `0001`/`0002`/`0006`/`0008` patch *build systems*, so each covers
only the targets its build system produces — which is why one nv-codec-headers pin takes two
patches, `0001` for `builder/` and `0002` for `msys2/`. `0003`/`0004`/`0005`/`0007` patch the
*ffmpeg source*, by adding to jellyfin-ffmpeg's own `debian/patches/` series that every build system
applies, so one patch covers every target.

Covering every target is not the same as *working* on every target. `0004`'s feature is VAAPI, which
is linux-only here, so its checks declare `linux` and skip on windows. `0007`'s is NVENC, which is
built for all four, so its checks declare `all` — same kind of patch, opposite platform answer,
decided by the feature rather than by the file it patches.

`0008` is narrower still, and is the reason the check grammar has an arch tier. It lives in
`builder/`, which feeds both linux targets, but its script gates on `[[ $TARGET == linux64 ]]`
because CUDA VMAF needs an nvcc toolchain and arm64 jellyfin hosts are overwhelmingly Rockchip and
Raspberry Pi. `linux` would be a false declaration, so it declares `linux64` and the workflow passes
each job its target — a fine-grained declaration reached with no target is a hard error, never a
skip.

Not every build-system patch adds a feature: `0006` removes a documentation build that was crashing
the winarm64 job, and changes nothing about the binary.

**Every patch carries two required artifacts**: a `checks/NNNN.checks` declaring how it is verified,
and a `docs/patches/NNNN-*.md` saying what it is. Either one missing fails the gate — including a
patch that cannot be proven from a binary, which declares itself `ungateable` and says why. See
[the verification gate](docs/verification-gate.md).

## What this does not build

Upstream produces **18 artifacts**. This repo builds **4**.

| artifact | built here | covered by |
|---|---|---|
| `linux-amd64-portable` | **yes** | [0001](docs/patches/0001-nv-codec-headers-linux.md) |
| `linux-arm64-portable` | **yes** | [0001](docs/patches/0001-nv-codec-headers-linux.md) — same file covers both linux targets |
| `win-clang-win64-portable` | **yes** | [0002](docs/patches/0002-nv-codec-headers-windows.md) |
| `win-clang-winarm64-portable` | **yes** | [0002](docs/patches/0002-nv-codec-headers-windows.md) — same dir covers both windows targets |
| `mac-x86_64-portable`, `mac-arm64-portable` | no | `50-ffnvcodec.sh:7` returns -1 for `mac*`, so ffnvcodec is off there entirely — `0001`/`0002` buy nothing there, and `0007` compiles to nothing because `hevc_nvenc` is not built. `0003`/`0004` reach mac via the patch series but are VAAPI-only, so they change nothing on it; `0005` is `fftools` argument parsing and *would* apply. Not enough to be worth a target nobody here runs. |
| `debian-{bullseye,bookworm,trixie}-{amd64,arm64}` | no | **nothing** |
| `ubuntu-{jammy,noble,resolute}-{amd64,arm64}` | no | **nothing** |

Only `0001`/`0002` appear in that table, because they are the ones that give an artifact its value.
`0003`/`0004`/`0005`/`0007` go into the ffmpeg patch series, so they reach every target every build
system produces, including the `.deb` and mac builds this repo does not make. `0006` is absent for the
opposite reason: it is msys2-only and adds no capability, having removed a documentation build that
was crashing the winarm64 job. `0008` is absent because it is linux64-only by construction.

**The 12 `.deb` packages are the one real gap.** They come from a third build system
(`Dockerfile.in` + `docker-build.sh`) with its own nv-codec-headers pin that neither pin patch
touches. So this repo publishes no `.deb`, and installing jellyfin-ffmpeg from a package gets you
stock, without `-tune uhq`.

Adding `.deb` here needs a third pin patch. Without one the packages ship the old headers and
nothing says so. `0003`/`0004`/`0005`/`0007` need no such duplicate — they patch the ffmpeg source,
which every build system applies. `0008` would need its own duplicate for the same reason `0001`
does, and does not have one: the `.deb` packages get no libvmaf.

## Layout

```
patches/jellyfin-ffmpeg/          *.patch applied in filename order with `git apply`
  checks/                        NOT applied — how each patch is verified. One file per patch,
                                 plus baseline.checks for checks no patch owns. Pairing enforced.
docs/                                  the detail this README is an index to
  README.md                            index of the docs
  patches/NNNN-*.md                    one per patch, canonical. Required: the gate pairs them
                                       against patches/ the same way it pairs checks/.
  verification-gate.md                 how a binary is proven, and how to check one by hand
  nv-codec-headers-pin.md              the shared story behind 0001 and 0002
  local-build-loop.md                  build locally in ~1 min, rebuild in ~5 s (not a release build)
.github/workflows/build-release.yaml   resolve -> build all four -> verify -> publish (~2.5h)
.github/workflows/checks.yaml          the cheap gate: script self-tests on push/PR (~20s)
.github/scripts/resolve-upstream.sh    which upstream release to build; --self-test, --plan
.github/scripts/verify-binary.sh       the gate runner; --self-test, --list
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
`proceed=false`, the four build jobs, the arm64 verify job and the release job all skip, and the run
finishes in about a minute. A new upstream 8.x tag is what triggers a real ~2.5h build.

## Build time

All four build jobs run in parallel and the release waits on all of them, so wall clock is the
slowest single job — about **145 min**. Measured on one upstream run (`31869623375`, so the numbers
are comparable): linux amd64 143 min, linuxarm64 135, winarm64 136, win64 107.

Most of that is the dependency toolchain rather than ffmpeg: linux spends roughly 122 of its 143 min
building the docker toolchain image, and windows roughly 88 of its ~105 in `makepkg`. Both are
cacheable if that ever becomes worth the added moving parts; it is deliberately not done here.

## Reproducing a build by hand

```bash
git clone -b v8.1.2-3 https://github.com/jellyfin/jellyfin-ffmpeg.git
cd jellyfin-ffmpeg
git apply /path/to/patches/jellyfin-ffmpeg/*.patch

# The source patches only create debian/patches/09xx-*.patch -- they deliberately do not
# patch debian/patches/series, because a diff that appends is anchored to a tail upstream
# keeps moving. Add the lines yourself:
for f in debian/patches/09*.patch; do
  b=$(basename "$f")
  grep -qxF "$b" debian/patches/series || echo "$b" >> debian/patches/series
done

./build-linux-amd64 ./dist     # linux64    — needs docker; ~2.5h
./build-linux-arm64 ./dist     # linuxarm64 — needs docker; cross-compiled on an x86-64 host
./msys2/build.sh               # win64      — needs msys2 CLANG64
./msys2/buildarm64.sh          # winarm64   — needs msys2 CLANGARM64 on arm64 windows
```

To iterate on a change rather than produce an artifact, use
[the local build loop](docs/local-build-loop.md) — about a minute for a full build, five seconds for
a rebuild.

## Releases

Tagged `<upstream-tag>+nvenc-<pin>`, e.g. `v8.1.2-2+nvenc-n13.0.19.1`. Assets carry `-nvenc-<pin>`
in the filename, because upstream names its assets from `debian/changelog` alone — without it a
build from here is byte-identically named to a stock one, which matters when the file is downloaded
by hand. Four assets per release:

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

## Retiring a patch

Each patch retires on its own condition — the header pin going away does not retire the repo. The
conditions live in each patch's doc; [the table above](#the-patches) links them.

**Two dependencies exist.** `0009` widens the pixel formats `libvmaf_cuda` accepts, which is only
safe because `0008`'s `55-libvmaf.sh` carries the libvmaf motion-stride fix; without it 10-bit is
accepted and scores ~1.06 VMAF low — a silently wrong number in place of a loud error. `0009` also
has nothing to act on without the filter `0008` builds.

`0007` moves `0004`'s Dolby Vision profile 8.1 conversion into a shared
`libavcodec/dovi_p81.{c,h}` and rewrites `0004`'s copy into calls to it, so the two must apply in
order and `0007` cannot be applied without `0004`. The reverse is not true: `0004` is unchanged by
`0007` and still applies alone. Retiring `0004` therefore means retiring or reworking `0007` first.

Retiring one means deleting its `checks/NNNN.checks` and its `docs/patches/NNNN-*.md` too — see
[Retiring a patch](docs/verification-gate.md#retiring-a-patch).

**What a new upstream release can still break.** The source patches no longer touch
`debian/patches/series` — they only create `debian/patches/09xx-*.patch`, and the build step appends
the lines — so upstream growing the series no longer breaks anything, and no patch depends on
another's series line. What remains is ordinary context drift: if upstream edits one of the
files a patch's *code* hunks touch, `git apply` fails loudly, the same signal a bumped upstream pin
gives `0001`/`0002`.

## Testing a change without waiting 2.5 hours

```bash
.github/scripts/verify-binary.sh --self-test      # ~1s: the gate's own assertions, the
                                                  # patch/checks and patch/docs pairing, and
                                                  # an end-to-end run against stub binaries
.github/scripts/verify-binary.sh --list           # what each platform would check
.github/scripts/resolve-upstream.sh --self-test   # ~1s, no network
.github/scripts/resolve-upstream.sh --plan        # what it would build, changes nothing
git apply patches/jellyfin-ffmpeg/*.patch         # in a throwaway upstream checkout
```

`checks.yaml` runs the first three on every push and pull request, so a patch added without its
declaration or its doc, or a gate that stopped working, fails in about 20 seconds rather than at the
next upstream release.

`verify-binary.sh --self-test` is the one to reach for after touching anything about the gate. It
builds stub `ffmpeg` binaries in a temp directory and runs the real script against them, so it
proves the gate **passes a good binary** — not only that it rejects a bad one. It includes the
asymmetric case that costs the most to get wrong: a build with no `hevc_vaapi` must fail on linux
and pass on windows.

**For anything that needs a real binary, do not use CI.**
[The local build loop](docs/local-build-loop.md) gives you a working `ffmpeg` from the same source in
about a minute, and a rebuild after editing one file in about five seconds. CI is for producing
artifacts, not for asking questions.

To exercise the pipeline itself, dispatch with `mode: dry_run` or `mode: smoke` — both about
**3 minutes**, measured. Only `mode: full` costs hours.

**What `smoke` cannot tell you**, so you know what a green smoke run is worth:

- the compile, and therefore [the verification gate](docs/verification-gate.md) reading a real binary
- **the publish path a real release takes.** `full` updates an existing release in place
  (`gh release edit` + `gh release upload --clobber`) and marks it `--latest`; `smoke` and `dry_run`
  delete-and-recreate, set `--prerelease --latest=false`, and publish to a separate `-smoke` /
  `-dryrun` tag. A test run never touches the real release, which is the point — but it also means
  that code path is only ever exercised by a real one.

A green smoke run proves plumbing: resolution, patching, artifact names and layout, the four-asset
assertion, and that every runner label allocates. It also proves the patch declarations, because
`verify-binary.sh --self-test` runs in the `resolve` job before any mode branch. It does not prove
the binaries or the release update — only the four per-target verify steps do that, and those are
what a non-`full` run skips.
