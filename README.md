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
which declares itself `ungateable` and says why. See [The verification gate](#the-verification-gate).

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
build system, another pin patch, and roughly triple the matrix. (`0003` would need no such
duplicate — see below.)

## Driver floor

**570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to 610.0, which is
why the pin stops where it does.

## Patch 0003 — VAAPI import of the alpha 10-bit RGB DRM formats

**Carried, applying cleanly, and NOT verified end to end.** Read it as a change in flight, not a
feature of these binaries.

Vulkan exports a single-plane 10-bit RGB image as `DRM_FORMAT_ARGB2101010` or `ABGR2101010` —
`hwcontext_vulkan.c`'s `vkfmt_to_drmfmt()` returns the first table match and the alpha spellings
are listed first. `hwcontext_vaapi.c`'s `vaapi_drm_format_map` carries only the **X** spellings
(upstream has `X2R10G10B10`; jellyfin's own `0038` adds `X2B10G10R10`). So mapping such a frame to
VAAPI fails:

```
[AVHWFramesContext] DRM format not supported by VAAPI.
[Parsed_hwmap]      Failed to map frame: -22.
```

X and A differ only in whether the top two bits are meaningful — identical layout — and the driver
takes the surface either way, verified on Mesa 26.0.4 / RX 9070 XT before writing the patch
(`-vf format=x2rgb10,hwupload,scale_vaapi=format=p010` returns 0). The patch adds two lines, each
alpha fourcc mapped to the X fourcc of the **same** channel order, following the pairing `0038`
already established.

**Why:** on RDNA4 a *multiplane* Vulkan target (`nv12`, `p010`) costs about **2×** — measured 9.98 s
against 19.46 s at equal bit depth, with the penalty following the multiplane frame rather than the
filter writing it. So a fast Vulkan tonemap chain has to keep the Vulkan side single-plane, which
today means 8-bit `bgra` widened to `p010` by VAAPI's VPP: full speed, 8-bit precision. A
single-plane **10-bit** RGB target would keep both, and this is the only thing blocking it.

**What is not proven.** That the chain is faster with it, that the channel order is right in
practice, or that 10-bit precision is visibly better than the 8-bit path already in use. The first
two need a build from this repo; the third is a quality measurement and does not need a build at
all. **`verify-binary.sh` cannot cover this** — it reads `-h encoder=` and `-filters`, and a format
table entry appears in neither. Proving it needs a `hwmap` on AMD hardware, which a GPU-less runner
does not have, so `0003` is outside the gate by construction rather than by omission.

That is no longer only a claim in a README. `patches/jellyfin-ffmpeg/checks/0003.checks` declares
it, in the reason field of an `ungateable` directive, and the gate prints it as `n/a` on every run
of every target. The declaration is mandatory: delete the file and the gate fails.

## Patch 0004 — Dolby Vision RPU passthrough for hevc_vaapi

**Carried, applying cleanly, and NOT verified on hardware.** Like `0003`, read it as a change in
flight. Unlike `0003`, it *is* gateable, and it is gated.

`hevc_vaapi` drops Dolby Vision on transcode. FFmpeg has all the machinery — the HEVC decoder
parses the RPU and attaches `AV_FRAME_DATA_DOVI_METADATA` to every frame, and `dovi_rpuenc.c` can
synthesise it back out — but only `libx265`, `libsvtav1` and `libaomenc` are wired to it. No VAAPI,
Vulkan or AMF encoder calls `ff_dovi_configure()`, so on AMD Linux there is no single-pass way to
keep DV through a hardware encode: today's answer is to encode the base layer and re-inject the RPU
afterwards with `dovi_tool`. That matters more now that AMD has dropped AMF from the Linux driver
and pointed users at VA-API, which takes rigaya's VCEEncC — the one tool that did this in one pass
— off the table.

The patch wires `hevc_vaapi` to the existing DOVI code, following `libx265.c`, and adds three
AVOptions:

| option | type | default | what it does |
|---|---|---|---|
| `dolbyvision` | boolean tri-state | `auto` | emit the RPU and the DV configuration record |
| `dv_l5` | `keep` / `zero` / `scale` | `keep` | how to handle the level 5 (active area) metadata |
| `dv_l5_canvas` | image_size | unset | canvas size `dv_l5=scale` scales against |

It covers DV profiles 8 and 5 and rejects profile 7. It also fixes a silent failure in jellyfin's
own patch `0027`, whose `ff_isom_validate_dovi_config()` required `AV_PIX_FMT_YUV420P10` and so
rejected every hardware-encoded stream — they report `P010` — quietly dropping the Matroska
`BlockAdditionMapping`.

**What is not proven.** That a real DV transcode survives end to end on hardware. The gate proves
*registration*: the three options are in the encoder's static AVOption table, so the patch applied
and compiled in. It cannot prove the RPU is correct, because that needs a GPU, a driver and a
video file, and the runners have none.

**Linux only, and that is a property of this pipeline rather than of the patch.** VAAPI is
linux-only here: `builder/scripts.d/50-vaapi/50-libva.sh:7` returns `-1` for any non-linux target,
and `msys2/PKGBUILD/` has no libva package at all. So the two windows jobs print `skip` for these
three checks. An unconditional check would fail both, and `release` needs all four build jobs, so
it would block every publish — 2.5 hours to discover.

## Layout

```
patches/jellyfin-ffmpeg/          *.patch applied in filename order with `git apply`
  0001  linux   nv-codec-headers pin   builder/scripts.d/50-ffnvcodec.sh      (amd64 + arm64)
  0002  windows nv-codec-headers pin   msys2/PKGBUILD/50-mingw-w64-ffnvcodec-headers
                                                                              (win64 + winarm64)
  0003  all     ffmpeg source          debian/patches/0098-...  + series      (all targets)
                VAAPI import of the alpha 10-bit RGB DRM formats — see above
  0004  all     ffmpeg source          debian/patches/0099-...  + series      (all targets)
                Dolby Vision RPU passthrough for hevc_vaapi — see above
  checks/                        NOT applied — one .checks file per patch, declaring how that
                                 patch is verified. Pairing is enforced; see the gate below.
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

## The verification gate

Every published binary is checked by `verify-binary.sh` before the release job runs. If one does
not carry the features, its job fails and nothing is published — the release keeps its previous
assets.

It asks ffmpeg rather than grepping the binary: `-h encoder=` reads an encoder's static AVOption
table and `-filters` the compiled-in filter list, neither of which loads a driver, so it works on
a GPU-less runner.

**What it checks is not written in the script.** Each patch declares its own checks in
`patches/jellyfin-ffmpeg/checks/NNNN.checks`, and `verify-binary.sh` is a generic runner over
those files:

```
encoder-option  linux    hevc_vaapi  dolbyvision      # 0004.checks
encoder-option  windows  hevc_nvenc  uhq              # 0002.checks
filter          all      tonemap_cuda                 # baseline.checks
ungateable      all      <reason>                     # 0003.checks
```

**The rule that makes this a gate rather than a convention: every `NNNN-*.patch` must have a
`checks/NNNN.checks`, and every `checks/NNNN.checks` must have a patch.** Either side missing is
an error, and it is checked before the script looks at a binary — so a patch cannot ship without
saying how it is proven. A patch that *cannot* be proven from a binary is not exempt; it declares
`ungateable` with a reason, which is what `0003` does. `baseline.checks` is the single exempt
filename, for checks no patch here owns — `tonemap_cuda` comes from jellyfin's own series.

Three verbs, kept distinct on purpose:

| | meaning |
|---|---|
| `ok` | the assertion ran, on this binary, and passed |
| `skip` | declared for the other platform — a sibling job runs it |
| `n/a` | declared unprovable by any binary, with the reason printed |

`skip` and `n/a` are not merged because that would make "declared for the wrong platform by
mistake" indistinguishable from "nobody can ever check this". A run where *nothing* ran is a
failure, not a pass.

`hevc_vaapi`'s three checks are linux-only, because VAAPI is linux-only in this pipeline — see
[Patch 0004](#patch-0004--dolby-vision-rpu-passthrough-for-hevc_vaapi). They print `skip` on the
two windows jobs rather than failing them.

**It must run on the binary's own platform**, and that is what decides where it runs:

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

### Adding a patch

Trigger: a new `patches/jellyfin-ffmpeg/NNNN-*.patch`. Required artifact:
`patches/jellyfin-ffmpeg/checks/NNNN.checks` with at least one directive. No artifact, no green
gate — this is enforced, not advised.

1. Write `checks/NNNN.checks`. Pick the platform honestly: `linux`, `windows`, or `all`. A patch
   to `builder/scripts.d` is `linux`; one to `msys2/PKGBUILD` is `windows`; one that adds to
   `debian/patches/series` is `all` unless the *feature* is platform-bound, as `0004`'s is.
2. If it cannot be proven by asking ffmpeg to describe itself, say so:
   `ungateable  all  <why>`. An empty reason is rejected.
3. Run `.github/scripts/verify-binary.sh --self-test` and `--list`. One second, no build.

Three kinds exist — `encoder-option <encoder> <option>`, `filter <name>`, `ungateable <reason>` —
because those are what the current patches need. Adding a kind is five steps documented at the top
of `verify-binary.sh`; the important one is registering its token, without which a misspelled kind
would be a silent no-op rather than an error.

The declarations for `0001` and `0002` are deliberately identical except for the platform column.
That duplication mirrors the two independent header pins, and collapsing it to one `all` row would
re-create exactly the blind spot that shipped the broken win64 asset. A lint rejects two files
declaring the *same* tuple, which is the other half of that mistake — copying `0001` to `0002` and
forgetting to change `linux` to `windows`.

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

**If .deb builds are ever added here, they need a third pin patch** — otherwise they silently ship
the old headers. **`0003` and `0004` are not affected by any of this**: they live in the ffmpeg
patch series that every one of these build systems applies, so they need no per-build-system
duplicate.

The verification declarations mirror this split exactly. `0001.checks` says `linux` and
`0002.checks` says `windows`, with the same four options in each — two independent pins, two
independent declarations. `0003`/`0004` declare once.

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

Retiring a patch means deleting its `checks/NNNN.checks` too. The pairing gate fails on an orphan
declaration, so this is loud rather than silent — but it is one more file than people expect.

**`0004` is coupled to `0003`, and the coupling is not obvious.** `0004`'s series hunk uses
`0096`/`0097`/`0098` as context, and `0098` exists only because `0003` ran first. So retiring
`0003` breaks `0004`'s `git apply`. Loud, not silent, but worth knowing before you start.

`0003` and `0004` are also the more fragile to an upstream release: their series hunks' context is
the tail of `debian/patches/series`, so a new upstream patch appended there makes `git apply` fail
rather than misorder — the safe direction, and the same loud-failure signal.

## Checking a built binary by hand

CI already does this on every build (see above). To repeat it on a downloaded asset, run the
same script the pipeline runs, on a machine of that binary's platform:

```bash
.github/scripts/verify-binary.sh /path/to/ffmpeg       # exit 0 = has everything
.github/scripts/verify-binary.sh --list                # what it would check, no binary needed
```

**"That binary's platform" means one of the four targets — macOS is not one of them.** The script
infers linux from any path not ending in `.exe`, so running it against a Homebrew ffmpeg reports
the `hevc_vaapi` options as missing. That is correct behaviour, not a bug: as a negative control it
is useful, as a way to check a mac build it is meaningless. Use `--list` on macOS.

Or directly:

```bash
./ffmpeg -h encoder=hevc_nvenc | grep -E 'uhq|tf_level|lookahead_level|split_encode'
./ffmpeg -h encoder=hevc_vaapi | grep -E 'dolbyvision|dv_l5'   # linux builds only
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

It *does* now prove the patch declarations: `verify-binary.sh --self-test` runs in the `resolve`
job, before any mode branch, so smoke and `dry_run` both catch an undeclared patch. Only the four
per-target verify steps need a real binary, and only those are skipped.
