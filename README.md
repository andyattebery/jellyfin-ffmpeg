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

**Two kinds of patch live here, and they behave differently.** `0001`/`0002` patch *build systems*
— they move a dependency pin, and each covers only the targets its build system produces.
`0003`/`0004` patch the *ffmpeg source*, by adding to jellyfin-ffmpeg's own `debian/patches/`
series; every build system applies that series, so one patch covers everything. Anywhere below
that says "the patches attach to a build system", read it as being about `0001`/`0002`.

**Every patch declares how it is verified**, in `patches/jellyfin-ffmpeg/checks/NNNN.checks`. A
patch with no declaration fails the gate — including a patch that cannot be proven from a binary,
which declares itself `ungateable` and says why. See
[docs/verification-gate.md](docs/verification-gate.md).

## Why this exists

Two machines need to run the *same* ffmpeg so a transcode job can go to either:

| | `tonemap_cuda` | `-tune uhq` |
|---|---|---|
| jellyfin-ffmpeg (stock) | yes | no — pins nv-codec-headers `n12.0.16.1` |
| BtbN / vanilla FFmpeg builds | no — it's a jellyfin patch | yes |
| **this** | yes | yes |

`tonemap_cuda` comes from `0004-add-cuda-tonemap-impl.patch`, one of 97 patches in
jellyfin-ffmpeg's `debian/patches/series` (99 with `0003` and `0004` below), so no vanilla build
has it. And jellyfin-ffmpeg pins
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

`0001`/`0002` attach to a *build system*, not to a target, which is why the arm64 pair was nearly
free — the same two patches cover all four portable targets, and all four run in parallel, so
adding them changed nothing about wall clock. (`0003` and `0004` are not in this table's logic at
all: they go into the ffmpeg patch series, so they apply to every target every build system
produces, including the `.deb` and mac builds this repo does not make.)

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
(`Dockerfile.in` + `docker-build.sh`) with its **own** nv-codec-headers pin that neither pin patch
touches. Two consequences:

- this repo publishes **no `.deb`** — install jellyfin-ffmpeg from a package and you get stock,
  without `-tune uhq`
- if `.deb` builds are ever added here, **the patch series as it stands would silently produce
  packages with the old headers.** That is the same failure that already shipped a broken win64
  asset once: a build system whose pin nobody patched, failing quietly rather than loudly.

Adding `.deb` is therefore a different proposition from adding the arm64 targets was: a different
build system, another pin patch, and roughly triple the matrix. (`0003`/`0004` would need no such
duplicate — they go into the ffmpeg patch series, which every build system applies. See
[the nv-codec-headers pin](docs/nv-codec-headers-pin.md).)

## Driver floor

**570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to 610.0, which is
why the pin stops where it does.

## The patches

Four patches, each with its own doc. **The docs are canonical** — this table is an index, not a
summary, so that it cannot drift out of step with them the way an earlier version of this README
did.

| | what it does | covers | status |
|---|---|---|---|
| [0001](docs/patches/0001-nv-codec-headers-linux.md) | nv-codec-headers pin, `builder/` | `linux64` + `linuxarm64` | shipping, gated |
| [0002](docs/patches/0002-nv-codec-headers-windows.md) | the same pin, `msys2/` | `win64` + `winarm64` | shipping, gated |
| [0003](docs/patches/0003-vaapi-alpha-10bit-rgb.md) | VAAPI import of the alpha 10-bit RGB DRM formats | all targets | shipping, verified on hardware; not gateable |
| [0004](docs/patches/0004-dolby-vision-hevc-vaapi.md) | Dolby Vision RPU passthrough for `hevc_vaapi` | all targets, linux-only feature | shipping, verified on hardware |

`0001`/`0002` share one rationale — [the nv-codec-headers pin](docs/nv-codec-headers-pin.md) — and
are two patches only because the pin lives in two independent build systems.

Adding a patch requires a doc and a `checks/NNNN.checks` declaration, both enforced by
[the gate](docs/verification-gate.md).

## Layout

```
patches/jellyfin-ffmpeg/          *.patch applied in filename order with `git apply`
  0001  linux   nv-codec-headers pin   builder/scripts.d/50-ffnvcodec.sh      (amd64 + arm64)
  0002  windows nv-codec-headers pin   msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers
                                                                              (win64 + winarm64)
  0003  all     ffmpeg source          debian/patches/0098-...  + series      (all targets)
  0004  all     ffmpeg source          debian/patches/0099-...  + series      (all targets)
  checks/                        NOT applied — one .checks file per patch, declaring how that
                                 patch is verified. Pairing is enforced.
docs/                                  the detail this README is an index to
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
`proceed=false`, the four build jobs, the arm64 verify job and the release job all skip, and the
run finishes in about a minute. A new upstream 8.x tag is what triggers a real ~2.5h build.

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

If upstream ever bumps its own pin, `git apply` stops applying and the build fails loudly. That is
the signal — but it now retires **`0001`/`0002` only**. Each other patch retires on its own
condition, so check all three before deleting anything:

| patch | retires when |
|---|---|
| `0001`/`0002` | upstream bumps its own nv-codec-headers pin |
| `0003` | upstream jellyfin-ffmpeg (or ffmpeg) accepts the alpha 10-bit RGB DRM entries |
| `0004` | upstream jellyfin-ffmpeg (or ffmpeg) accepts Dolby Vision for the VAAPI encoder |

Retiring a patch means deleting its `checks/NNNN.checks` **and** its `docs/patches/NNNN-*.md`. The
pairing gate fails on either left behind, so this is loud rather than silent — but it is two more
files than people expect.

Each patch doc carries its own retire condition in its header table; the rows above are the index.

**`0004` is coupled to `0003`, and the coupling is not obvious.** `0004`'s series hunk uses
`0096`/`0097`/`0098` as context, and `0098` exists only because `0003` ran first. So retiring
`0003` breaks `0004`'s `git apply`. Loud, not silent, but worth knowing before you start.

`0003` and `0004` are also the more fragile to an upstream release: their series hunks' context is
the tail of `debian/patches/series`, so a new upstream patch appended there makes `git apply` fail
rather than misorder — the safe direction, and the same loud-failure signal.

## Testing a change without waiting 2.5 hours

```bash
.github/scripts/verify-binary.sh --self-test      # ~1s: the gate's own assertions, the
                                                  # patch/checks pairing, and an end-to-end run
                                                  # against stub binaries
.github/scripts/verify-binary.sh --list           # what each platform would check
.github/scripts/resolve-upstream.sh --self-test   # ~1s, no network
.github/scripts/resolve-upstream.sh --plan        # what it would build, changes nothing
git apply --check patches/jellyfin-ffmpeg/*.patch # against an upstream checkout
```

`checks.yaml` runs the first and third of these on every push and pull request, so a patch added
without a declaration, or a gate that stopped working, fails in about 20 seconds rather than at
the next upstream release.

`verify-binary.sh --self-test` is the one to reach for after touching anything about the gate. It
builds stub `ffmpeg` binaries in a temp directory and runs the real script against them, so it
proves the gate **passes a good binary** — not only that it rejects a bad one. It includes the
asymmetric case that costs the most to get wrong: a build with no `hevc_vaapi` must fail on linux
and pass on windows.

**For anything that needs a real binary, do not use CI at all.** A local build gives you a working
`ffmpeg` from the same source in about a minute, and a rebuild after editing one file in about five
seconds — see [docs/local-build-loop.md](docs/local-build-loop.md). Patch `0003`'s R/B swap was
diagnosed that way after the CI-only approach had stalled on the cost of a build. CI is for
producing artifacts, not for asking questions.

Then dispatch with `mode: dry_run` or `mode: smoke` — both about **3 minutes**, measured. Only
`mode: full` costs hours.

**What `smoke` still cannot tell you**, so you know what a green smoke run is worth:

- the compile, and therefore [the verification gate](docs/verification-gate.md) reading a real
  binary
- **the publish path a real release takes.** `full` updates an existing release in place
  (`gh release edit` + `gh release upload --clobber`) and marks it `--latest`; `smoke` and
  `dry_run` delete-and-recreate, set `--prerelease --latest=false`, and publish to a separate
  `-smoke` / `-dryrun` tag. A test run never touches the real release, which is the point — but
  it also means that code path is only ever exercised by a real one.

So a green smoke run proves plumbing: resolution, patching, artifact names and layout, the
four-asset assertion, and that every runner label allocates. It does not prove the binaries or
the release update.

It *does* now prove the patch declarations: `verify-binary.sh --self-test` runs in the `resolve`
job, before any mode branch, so smoke and `dry_run` both catch an undeclared patch. Only the four
per-target verify steps need a real binary, and only those are skipped.
