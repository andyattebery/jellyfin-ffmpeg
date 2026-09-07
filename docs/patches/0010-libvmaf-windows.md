# 0010 — `libvmaf` on the Windows builds

| | |
|---|---|
| **Status** | Written and gate-verified; **not yet built or released**. Update this row after the first release run, and fill the parity table below. |
| **Covers** | `win64` **and** `winarm64` — one PKGBUILD directory feeds both |
| **Retires when** | Upstream jellyfin-ffmpeg adds libvmaf to `msys2/` itself |
| **Gate** | `checks/0010.checks` — one `filter` check, declared `windows` |
| **Related** | [0008](0008-cuda-libvmaf.md) is the same feature for `linux64`; this is its Windows counterpart, the way `0002` is `0001`'s |

## What it does

Adds `msys2/PKGBUILD/40-mingw-w64-libvmaf/PKGBUILD` and one `--enable-libvmaf` line to each of
`msys2/build.sh` and `msys2/buildarm64.sh`. Both Windows assets gain the `libvmaf` filter.

**CPU only — no `libvmaf_cuda`.** nvcc requires MSVC, which the clang64/clangarm64 environments do
not have, and GitHub's Windows runners carry no CUDA toolkit. So `enable_cuda` stays at its meson
default of `false`. That is not a limitation this patch could remove with more effort; see
[0008](0008-cuda-libvmaf.md).

## Why

**eta had no VMAF at all.** The BtbN build that carried it was removed
(`tasks/uhq-1080p-segfault.md:161-165`), leaving the Windows box unable to score anything — and
unable to answer the "can eta score?" question the scorer-cost probe exists to settle.

The goal is **parity**, not merely availability: eta's scores have to be comparable with
media-01's. That is why the version is pinned to **vmaf 3.2.0**, the same version
[0008](0008-cuda-libvmaf.md) pins on Linux, and why the meson options deliberately match it
(`built_in_models=true`, `enable_float=true`, tests and docs off). Two hosts running different
libvmaf builds would produce numbers that cannot be pooled, which is the failure the campaign's
"scoring is centralised" rule exists to prevent.

## Why this was low-risk

**MSYS2 already ships `mingw-w64-vmaf` 3.2.0**, unpatched, for `clang64` *and* `clangarm64`. That
is direct evidence vmaf builds in both environments this repo targets, rather than an assumption,
and it supplied two details that were not guessable from our tree:

- `LDFLAGS+=" -lpthread"` is required.
- the v3.2.0 tarball sha256 is `a28f93f3b4fa65601be324587072e32a6a704a304ba7b1aec9b70b3f709bc1dc`.

Their package could not be used directly: it installs to `${MINGW_PREFIX}` with
`--default-library=both`, whereas this build needs `${MINGW_PREFIX}/ffbuild` and a static library,
under the `-jellyfin-` package naming every other dependency here uses.

Nine PKGBUILDs already build with meson, so `makepkg -s` installs it from `makedepends` and the
workflow's `setup-msys2` package list needed no change.

## Three things in the PKGBUILD that look arbitrary and are not

1. **Tier `40`, not `55`.** [0008](0008-cuda-libvmaf.md)'s doc predicted this follow-up and guessed
   `55-mingw-w64-libvmaf`; that guess was wrong. `msys2/build.sh` runs the PKGBUILD directories in
   plain glob order, so the numeric prefix *is* the dependency order, and tier 55 means "consumes
   tier 50 headers" — libplacebo needs shaderc, spirv-cross and vulkan. libvmaf needs nothing in
   the tree, so it belongs in tier 40 with the other codec-level libraries: dav1d, svt-av1, x264.

2. **The nasm makedepend is guarded on `${CARCH}`.** vmaf's asm is nasm-based and nasm is x86-only,
   so declaring it unconditionally would break `clangarm64`. Same guard shape as
   `40-mingw-w64-dav1d/PKGBUILD:17-19`.

   `enable_asm` itself is left at its default `true`, and that is safe rather than lucky:
   `libvmaf/src/meson.build:45-65` branches on `host_machine.cpu_family()` and calls
   `find_program('nasm')` **only inside the x86 branch**. aarch64 takes a separate branch that
   needs no nasm at all. So the default is correct on both architectures.

3. **`Libs.private` is checked before it is edited.** `src/svm.cpp` is C++, and
   `msys2/build.sh:46` passes `--pkg-config-flags=--static`, which is what makes `Libs.private`
   reach the link line at all. Without it, configure fails with the misleading
   `libvmaf >= 2.0.0 not found using pkg-config` while the real error is an undefined C++ symbol
   hundreds of lines down `config.log`.

   `-lstdc++` is this tree's convention — `55-mingw-w64-libplacebo/PKGBUILD:69`,
   `50-mingw-w64-libvpl:82`, `30-mingw-w64-chromaprint:64`, `50-mingw-w64-shaderc:78-79` and
   `50-mingw-w64-spirv-cross:81` all write it, and nothing writes `-lc++`, even though clang64 ships
   libc++. The generated `.pc` has no `Libs.private` line at all on Linux, so a bare `sed` would
   match nothing and silently ship a broken link; the PKGBUILD tests for the file and the line and
   fails loudly instead.

   No `-ldl` here. That was a glibc-2.28 artefact of the Linux crosstool-ng sysroot, not a libvmaf
   requirement.

## Gate

```
filter  windows  libvmaf
```

Coarse `windows`: both targets genuinely get it, so the fine tier would be a false precision.
One line, not 0008's two — `libvmaf_cuda` is deliberately absent here, and declaring it would
assert a feature this patch does not ship.

**What no check proves: that the scores match media-01's.** Presence is gateable; correctness is
not, and parity is the entire point of the patch. The standing check is the measurement below.

## Parity measurement

Score one identical pair on eta and on media-01 with the CPU `libvmaf` filter and compare. Both are
vmaf 3.2.0 with built-in models, so they should agree closely — but the achievable tolerance is
**recorded from measurement, not asserted in advance**, since cross-platform float and SIMD
ordering differ.

| host | build | VMAF | delta |
|---|---|---|---|
| media-01 | linux64, 0008 | _to be filled on first run_ | — |
| eta | win64, 0010 | _to be filled_ | _to be filled_ |

⚠ eta's paths contain spaces and parentheses — drive it with a `.bat`, never nested shell quoting.

Re-run after any vmaf version bump on either side.

## Using it

```bash
ffmpeg -i dis.mkv -i ref.mkv -lavfi "[0:v][1:v]libvmaf=log_fmt=json:log_path=out.json" -f null -
```

`n_threads` defaults to 0, which is single-threaded. Set it — measured on the Linux side, the same
work went from 46 s to 8 s at `n_threads=16`. Models are compiled in, so no `model_path` is needed.
