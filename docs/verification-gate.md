# The verification gate

Every published binary is checked by `.github/scripts/verify-binary.sh` before the release job
runs. If one does not carry the features, its job fails and nothing is published — the release
keeps its previous assets.

It asks ffmpeg rather than grepping the binary: `-h encoder=` reads an encoder's static AVOption
table and `-filters` the compiled-in filter list, neither of which loads a driver, so it works on a
GPU-less runner.

**This exists because a win64 asset was once published with NVENC but none of the tuning options.**
Every check in the pipeline at the time was about plumbing; nothing looked inside the binary.

## What it checks is not written in the script

Each patch declares its own checks in `patches/jellyfin-ffmpeg/checks/NNNN.checks`, and
`verify-binary.sh` is a generic runner over those files:

```
encoder-option  linux    hevc_vaapi    dolbyvision    # 0004.checks
encoder-option  windows  hevc_nvenc    uhq            # 0002.checks
filter          all      tonemap_cuda                 # baseline.checks
filter          linux64  libvmaf_cuda                 # 0008.checks
ungateable      all      <reason>                     # 0003.checks
```

The platform column has two tiers. **Coarse** — `all`, `linux`, `windows` — is inferred from
whether the binary path ends in `.exe`, and is what almost every declaration should use. **Fine** —
`linux64`, `linuxarm64`, `win64`, `winarm64` — cannot be inferred, because both linux jobs hand the
script a path named `ffmpeg`; the workflow passes the target as a second argument instead. A fine
declaration reached with no target is a **hard error**, never a skip: a declaration silently
covering nothing is the failure this whole gate exists to prevent.

**The rule that makes this a gate rather than a convention:** every `NNNN-*.patch` must have a
`checks/NNNN.checks` **and** a `docs/patches/NNNN-*.md`, and each of those must have a patch. Any
side missing is an error, checked before the script looks at a binary — so a patch cannot ship
without saying how it is proven and what it is.

A patch that *cannot* be proven from a binary is not exempt: it declares `ungateable` with a
reason, which is what [`0003`](patches/0003-vaapi-alpha-10bit-rgb.md) does. `baseline.checks` is
the single exempt filename, for checks no patch here owns — `tonemap_cuda` comes from jellyfin's
own series and is the control that proves the series applied at all.

## Three verbs, kept distinct on purpose

| | meaning |
|---|---|
| `ok` | the assertion ran, on this binary, and passed |
| `skip` | declared for a different platform *or target* — a sibling job runs it |
| `n/a` | declared unprovable by any binary, with the reason printed |

`skip` and `n/a` are not merged, because that would make "declared for the wrong platform by
mistake" indistinguishable from "nobody can ever check this". **A run where *nothing* ran is a
failure, not a pass.**

`hevc_vaapi`'s three checks are linux-only, because VAAPI is linux-only in this pipeline — see
[`0004`](patches/0004-dolby-vision-hevc-vaapi.md). They print `skip` on the two windows jobs rather
than failing them. `hevc_nvenc`'s equivalent three from
[`0007`](patches/0007-dolby-vision-hevc-nvenc.md) are declared `all` and run everywhere, which is why
a linux run reports more `ok` lines than a windows one.

[`0008`](patches/0008-cuda-libvmaf.md)'s two are the same idea one level down: declared `linux64`,
so they `skip` on `linuxarm64` as well as on both windows jobs. The runnable counts are
`linux64` 13, `linuxarm64` 11, `win64` 8, `winarm64` 8 — `--self-test` asserts each is non-zero,
per target rather than per platform, so a target that ends up with nothing to check is caught here
rather than by a build.

## Where it runs

**It must run on the binary's own platform**, and that is what decides where:

| target | where it is verified | why |
|---|---|---|
| `linux64` | in the build job | job runs on x86-64, binary is x86-64 |
| `win64` | in the build job | `windows-latest` is x86-64 |
| `winarm64` | in the build job | `windows-11-arm` is native arm64, so `msys2/buildarm64.sh` and the check both run in place |
| `linuxarm64` | **separate `verify_linux_arm64` job on `ubuntu-24.04-arm`** | `builder/images/base-linuxarm64/` is a crosstool-NG **cross** toolchain that runs on an x86-64 host, so the build job cannot execute what it just produced |

The arm64 linux exception is not a weaker gate: `release` requires `verify_linux_arm64` to succeed,
so an unverified binary exists as a CI artifact and never reaches a release. The one difference is
ordering — it is checked after upload rather than before.

## Adding a patch

Trigger: a new `patches/jellyfin-ffmpeg/NNNN-*.patch`. Required artifacts, both enforced:

1. **`patches/jellyfin-ffmpeg/checks/NNNN.checks`** with at least one directive.
2. **`docs/patches/NNNN-slug.md`** — what the patch does, its status, when it retires.

No artifact, no green gate. This is enforced, not advised.

Writing the checks file:

- Pick the platform honestly: `linux`, `windows`, or `all`. A patch to `builder/scripts.d` is
  `linux`; one to `msys2/PKGBUILD` is `windows`; one that adds to `debian/patches/series` is `all`
  unless the *feature* is platform-bound, as `0004`'s is. `0007` is the counterexample worth reading
  next to it: also a source patch, but NVENC is built for all four targets, so it declares `all`.
  The file a patch touches does not decide this — the feature does.

  ⚠ `0001.checks` argues against `all` in strong terms, and that argument is about `0001`/`0002`
  being two patches pinning two independent *build systems*, where one declaration each keeps them
  attributable. It does not transfer to a single source patch that every build system compiles.
- **Reach for the fine tier only when the patch really does build for one target and not its
  sibling.** `0008` is the only current case: `55-libvmaf.sh` gates on `[[ $TARGET == linux64 ]]`,
  so `linuxarm64` has no libvmaf at all and a `linux` declaration would fail there. Do not use it
  as a way to dodge a check that is merely inconvenient — `linux` remains correct for anything
  `builder/` builds for both linux targets, which is most things.
- If it cannot be proven by asking ffmpeg to describe itself, say so: `ungateable  all  <why>`. An
  empty reason is rejected.
- Run `.github/scripts/verify-binary.sh --self-test` and `--list`. One second, no build.

Three kinds exist — `encoder-option <encoder> <option>`, `filter <name>`, `ungateable <reason>` —
because those are what the current patches need. Adding a kind is five steps documented at the top
of `verify-binary.sh`; the important one is registering its token, without which a misspelled kind
would be a silent no-op rather than an error. Adding a *target* is documented next to it, and has
the same shape: register the token, teach it its coarse platform, add a self-test fixture with a
negative control, and pass it from that job's call site.

The doc filename is keyed on the **four-digit prefix**, and the gate globs `NNNN-*.md`. Retitling a
patch therefore cannot orphan its doc — the same reason `checks/` keys on the number alone.

## Retiring a patch

The mirror of adding one: delete the patch **and both its artifacts** —
`patches/jellyfin-ffmpeg/checks/NNNN.checks` and `docs/patches/NNNN-*.md`.

The pairing gate fails on either one left behind, reporting it as an `orphan`. That is loud rather
than silent, which is the point — but it is two more files than people expect, and the gate is the
only thing that will remind you.

Each patch doc carries its own retire condition in its header table.

## Checking a built binary by hand

CI already does this on every build. To repeat it on a downloaded asset, run the same script the
pipeline runs, on a machine of that binary's platform:

```bash
.github/scripts/verify-binary.sh /path/to/ffmpeg linux64   # exit 0 = has everything
.github/scripts/verify-binary.sh --list linux64            # what it would check, no binary needed
.github/scripts/verify-binary.sh --self-test               # the gate's own assertions, ~1s
```

The target argument is optional, so a quick hand-run still works without it — but any patch with a
fine-grained declaration will then refuse to run rather than skip it, and say so. Passing a target
that contradicts the binary (`win64` against a path called `ffmpeg`) is refused outright, so a
confident pass cannot be reported against the wrong thing.

**"That binary's platform" means one of the four targets — macOS is not one of them.** The script
infers linux from any path not ending in `.exe`, so running it against a Homebrew ffmpeg reports
the `hevc_vaapi` options as missing. That is correct behaviour, not a bug: useful as a negative
control, meaningless as a way to check a mac build. Use `--list` on macOS.

Or directly:

```bash
./ffmpeg -h encoder=hevc_nvenc | grep -E 'uhq|tf_level|lookahead_level|split_encode'
./ffmpeg -h encoder=hevc_vaapi | grep -E 'dolbyvision|dv_l5'   # linux builds only
./ffmpeg -filters | grep tonemap_cuda
```

This matters for the arm64 assets in particular: an x86-64 machine cannot execute either of them,
the same constraint that puts the `linuxarm64` gate in its own CI job.

If you cannot execute the binary — checking a win64 build from Linux, or either arm64 build from an
x86-64 host — `strings` is the fallback, but **an absence found with `grep` means nothing without a
positive control**. Check that something you *know* is present also shows up, or you have only
proven your search was wrong:

```bash
strings ffmpeg.exe | grep -cF "Specifies the strength of the temporal filtering"  # expect >=1
strings ffmpeg.exe | grep -cF "NVIDIA NVENC hevc encoder"                         # control, expect 1
```

## Related

- To *iterate* on a change rather than prove a finished binary, don't use CI at all — see
  [the local build loop](local-build-loop.md), which rebuilds in about five seconds.
- The `0001`/`0002` declarations are deliberately duplicated; see
  [the nv-codec-headers pin](nv-codec-headers-pin.md#how-the-gate-mirrors-this).
