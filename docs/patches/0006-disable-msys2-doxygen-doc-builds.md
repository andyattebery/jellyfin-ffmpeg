# 0006 — stop the msys2 packages building doxygen documentation

| | |
|---|---|
| **Status** | Shipping. Written after two consecutive winarm64 builds were lost to the same crash. |
| **Covers** | `win64` + `winarm64` — it patches `msys2/PKGBUILD/`, which is the only build system that reads those files |
| **Retires when** | Upstream jellyfin-ffmpeg stops building these docs itself. **Not** when msys2 fixes doxygen — see below. |
| **Gate** | `checks/0006.checks` — declared `ungateable`, with the reason. The patch *removes* a build step, so there is no feature in the binary to look for. |

## What it does

Three PKGBUILDs, six hunks:

| PKGBUILD | change |
|---|---|
| `10-mingw-w64-xz` | `--enable-doxygen` → `--disable-doxygen`; drop `-doxygen` from `makedepends` |
| `30-mingw-w64-opus` | add `-Ddocs=disabled` to `meson setup`, plus one comment line; drop `-doxygen` from `makedepends` |
| `40-mingw-w64-libtheora` | drop `-doxygen` from `makedepends` — it already passes `--disable-{...,doc}` and never ran it |

The net effect is that **doxygen is never installed**, so nothing can invoke it. It is not in either
`setup-msys2` install list; it arrived solely as a makedepend of these three packages, first pulled
in by xz.

## Why it exists

`doxygen.exe` **segfaults on clangarm64**, intermittently. Two winarm64 builds of upstream v8.1.2-3
were lost to it in different packages:

| run | died in | at | error |
|---|---|---|---|
| [`32388609622`](https://github.com/andyattebery/jellyfin-ffmpeg/actions/runs/32388609622) | `30-mingw-w64-opus` | 1h18m | `FAILED: [code=3221225477] doc/html` — `0xC0000005` |
| [`32411735209`](https://github.com/andyattebery/jellyfin-ffmpeg/actions/runs/32411735209) | `10-mingw-w64-xz` | 19m | `Segmentation fault \| doxygen -q -`, `Error 139` |

Both on `doxygen 1.18.0-1`, the newest in the clangarm64 repo. It is not a plain version
regression: upstream jellyfin-ffmpeg's own release build
([`32242783166`](https://github.com/jellyfin/jellyfin-ffmpeg/actions/runs/32242783166)) built both
sets of docs on **the same doxygen, the same runner image and the same msys2-runtime** a day
earlier. Comparing installed package version strings, our two runs are identical to each other and
differ from that green run only in `autotools` and `libarchive`, neither a doxygen dependency.

So the crash is **per-invocation, not per-version**. With two invocations in every Windows build,
a winarm64 run was more likely to fail than to finish, and re-running is not a strategy — the
second failure above *was* the re-run.

**The rate is not worth quoting precisely.** Five invocations have been observed across three runs,
two of which crashed. That is too small a sample to put a number on; what it establishes is the
shape — two chances to lose each build — and that is what the fix removes.

## Why this does not retire when doxygen is fixed

Nothing here consumes opus, xz or libtheora API documentation. The portable artifact ships
binaries; these docs were built and then thrown away. Even with a fixed doxygen the patch is worth
keeping for build time alone.

The better end state is upstream not building them either, which is worth proposing — this patch is
a workaround in someone else's file, and that is the only real argument for retiring it.

## Gotchas

- **The comment cannot go inside the `meson setup` call.** That command is one logical line spliced
  with backslashes, so a `#` between the flags would comment out the remainder of the line —
  including the source directory argument. The comment therefore sits above
  `MSYS2_ARG_CONV_EXCL=...`, next to the existing `-Dasm` one. This is a silent build-breaker, not
  a style preference.
- **`-Ddocs=disabled` looks like it contradicts `--auto-features=enabled` two lines above it, and
  does not.** `--auto-features` only sets features still on `auto`; an explicit `-D` takes them out
  of that set. Removing the explicit flag as "redundant" re-enables the doc build.
- **`libopenmpt` uses doxygen without declaring it.** Its configure probes for the tool
  (`checking for doxygen... /clangarm64/bin/doxygen`) and finds whatever an earlier package
  installed, though upstream's logs show it never actually generating docs. It is the reason the
  `makedepends` entries are removed rather than only the two flags: with the tool absent, whether
  any such package *would* have run it stops mattering. If a package ever genuinely needs doxygen,
  the symptom is a skipped doc build, the same warning `libtheora` already prints.
- **This patch modifies existing files**, unlike `0003`/`0004`/`0005` which only create them. A
  drifted hunk is therefore a loud `git apply` failure, which is what stands in for a CI gate here.
