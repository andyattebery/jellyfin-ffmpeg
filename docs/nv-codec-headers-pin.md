# The nv-codec-headers pin

Shared background for [`0001`](patches/0001-nv-codec-headers-linux.md) and
[`0002`](patches/0002-nv-codec-headers-windows.md). They are two patches with one rationale, which
is why it lives here rather than being written twice.

## Why the pin moves at all

jellyfin-ffmpeg pins nv-codec-headers at `n12.0.16.1`, which predates `NVENC_HAVE_UHQ_TUNING`. That
costs `-tune uhq`, `-tf_level`, `-lookahead_level` and `-split_encode_mode`, because
`libavcodec/nvenc.h` gates them behind `NVENCAPI_CHECK_VERSION(12, 2)` and `n12.0.16.1` reports API
12.0.

**Not sent upstream on purpose.** The low pin keeps the NVIDIA driver floor at 520.56.06 for older
cards. `n13.0.19.1` raises it to **570.0**, which would drop users. That is a reasonable call for
upstream and the wrong one for this fleet, so it lives here.

**Driver floor: 570.0.** Check `nvidia-smi` before installing. `n13.1.15.0` would raise it to
610.0, which is why the pin stops where it does.

## Three independent build systems, and only two are patched

jellyfin-ffmpeg contains three unrelated build systems, each pinning nv-codec-headers its own way.
Patching one does not touch the others, and **the failure is silent** — you get a binary with NVENC
but without the options. Check all of them on any future bump:

| build system | produces | pins the headers in | patched |
|---|---|---|---|
| `builder/` (BtbN-derived) | portable linux **amd64 + arm64**, mac | `scripts.d/50-ffnvcodec.sh` | **0001** — covers both linux targets, both built and verified here |
| `msys2/` | portable **win64 + winarm64** clang | `PKGBUILD/50-mingw-w64-ffnvcodec-headers/PKGBUILD` | **0002** — covers both; `build.sh:17` and `buildarm64.sh:17` share the dir |
| `Dockerfile.in` + `docker-build.sh` | 12 `.deb` packages | `docker-build.sh` — inline `git clone -b n12.0.16.1` | **no** — this repo builds no debs |

(`Dockerfile.win64.in` + `docker-build-win64.sh` is a fourth, for the gcc win64 build upstream has
disabled.) Those scripts are reached via `ENTRYPOINT`, not a call site, so grepping for
`./docker-build.sh` finds nothing and is misleading.

`configure` also gates on the version but needs no patch: its chain's first branch is
`ffnvcodec >= 12.1.14.0` with no upper bound, which accepts 13.x.

**If `.deb` builds are ever added here, they need a third pin patch** — otherwise they silently ship
the old headers.

## This is not hypothetical

A win64 asset shipped once with NVENC but none of the tuning options, because Windows pins the
headers in `msys2/PKGBUILD` and only `builder/scripts.d` had been patched. Every check in the
pipeline at the time was about plumbing; nothing looked inside the binary. That incident is why
[the verification gate](verification-gate.md) exists.

**The split is by build system, not by platform**, and that distinction is what makes the arm64
targets free: each of those two files feeds both an amd64 and an arm64 target, so two patches cover
all four portable targets.

## How the gate mirrors this

The verification declarations mirror the split exactly. `checks/0001.checks` says `linux` and
`checks/0002.checks` says `windows`, with **the same four options in each** — two independent pins,
two independent declarations.

That duplication is deliberate. Collapsing them into one `all` row would re-create precisely the
blind spot that shipped the broken win64 asset. A lint catches the inverse mistake — two files
declaring the identical `(kind, platform, args)` tuple, which is what copying `0001` to `0002` and
forgetting to change `linux` to `windows` produces.

`0003` and `0004` are unaffected by any of this: they live in the ffmpeg patch series that every
build system applies, so they declare once.
