# The local build loop

A release build takes about **2.5 hours**. This gets you a working `ffmpeg` from the same source
in about **a minute**, and a rebuild after editing one file in about **five seconds**.

It exists because the release pipeline is a bad debugger. Patch `0003` was diagnosed and fixed with
this loop after the CI-only approach had reduced the problem to "one instrumented build beats two
guesses, so choose which question to ask" — a false choice created entirely by the cost of a build.

**This does not replace the release build.** It produces a *shared* binary with no external codecs,
for answering questions. Release artifacts are static, portable, and carry the full codec set. Do
not compare timings between the two without saying so.

## What you need

| | |
|---|---|
| a Linux host with the target GPU | the code paths worth debugging here are driver paths; a GPU-less runner cannot exercise them |
| podman or docker | the host does not need a toolchain, and on an atomic distro it cannot have one |
| a base container image carrying **the driver under test** | VAAPI only — see the track table |

## Pick your track

The skeleton below is the same either way. Four things differ, and picking the wrong set wastes a
build:

| | **VAAPI / AMD** | **NVENC / NVIDIA** |
|---|---|---|
| base image | must carry **the Mesa/libva under test** — that is the point of the loop | any sane distro base; the driver is **not** in the image |
| how the GPU gets in | `--device /dev/dri` | CDI: `--device nvidia.com/gpu=all` (docker) |
| extra build deps | Vulkan headers + libplacebo from source (the two expensive steps below) | **nv-codec-headers only** — skip both |
| configure | `--enable-vaapi --enable-vulkan --enable-libplacebo --enable-libdrm` | `--enable-ffnvcodec --enable-cuda --enable-nvenc --enable-nvdec --enable-cuvid` |

⚠ **"Build and run in the same image" means something different on each.** On VAAPI the driver under
test *is* the base image, which is the whole reason for the rule. On NVIDIA the driver libraries are
injected from the host at run time by CDI, so the base image does not determine which driver the
binary sees — **the host does**. Same conclusion (one host, one image), different mechanism: if you
need a specific NVIDIA driver, change the host, not the `FROM` line.

Both tracks can be enabled at once, and sometimes must be. If you are touching code shared between
the two encoders, build **both** even on a host that can only run one — otherwise half the change
compiles and the other half is discovered by CI.

Set these once:

```bash
BASE_IMAGE=...            # image whose Mesa/libva is the one your measurements use
SCRATCH=/path/with/space  # ~10 GB; source tree, build output
UPSTREAM_TAG=v8.1.2-2     # the tag CI builds; see .github/scripts/resolve-upstream.sh --plan
```

Pick `BASE_IMAGE` deliberately. A stock distro image is the wrong choice if your GPU needs a newer
driver than the distro ships, and it also changes libva and libdrm at the same time — three moving
parts against whatever you are trying to isolate.

## 1. Source tree

```bash
mkdir -p "$SCRATCH"/{src,out}
git clone --depth 1 --branch "$UPSTREAM_TAG" \
    https://github.com/jellyfin/jellyfin-ffmpeg.git "$SCRATCH/src"
cd "$SCRATCH/src"
git apply /path/to/this/repo/patches/jellyfin-ffmpeg/*.patch

# The source patches only create debian/patches/09xx-*.patch. They do not touch
# debian/patches/series -- a diff that appends is anchored to a tail upstream keeps moving,
# so the line is generated instead. Do the same by hand:
for f in debian/patches/09*.patch; do
  b=$(basename "$f")
  grep -qxF "$b" debian/patches/series || echo "$b" >> debian/patches/series
done

ln -s debian/patches patches      # quilt looks for patches/ at the tree root, as builder/build.sh:64 does
```

Then push the ffmpeg patch series itself (inside the container, step 3):

```bash
quilt push -a          # 101 at v8.1.2-3: upstream's 98 plus this repo's 3
```

The series is not optional. Several things this fork relies on live there — `vf_libplacebo`
accepting DRM PRIME, and patch `0038`'s format-map entry that `0003` sits beside.

## 2. Build image

```dockerfile
FROM ${BASE_IMAGE}

# VAAPI track. Toolchain and headers only -- the runtime .so's are the thing under test
# and must not move. For the NVENC track see the smaller image further down.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential git quilt yasm pkg-config cmake python3 \
      libva-dev libdrm-dev libvulkan-dev libshaderc-dev glslang-tools \
      libunwind-dev liblcms2-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# ffmpeg 8.x requires vulkan >= 1.3.277 (configure:7815). Distros lag. Use the SAME tag the
# release build pins, from builder/scripts.d/47-vulkan/45-vulkan-headers.sh.
RUN git clone --depth 1 -b v1.4.355 https://github.com/KhronosGroup/Vulkan-Headers.git /opt/vkh \
 && cp -r /opt/vkh/include/vulkan /opt/vkh/include/vk_video /usr/local/include/ \
 && mkdir -p /usr/local/share/vulkan/registry \
 && cp /opt/vkh/registry/vk.xml /usr/local/share/vulkan/registry/vk.xml

# jellyfin's vf_libplacebo needs libplacebo 7.x (PL_ALPHA_NONE). Distro packages are 6.x. The
# release build does not use a distro package either -- builder/scripts.d/50-libplacebo.sh pins
# this commit.
RUN mkdir -p /opt/placebo && cd /opt/placebo \
 && git init -q && git remote add origin https://code.videolan.org/videolan/libplacebo.git \
 && git fetch -q --depth 1 origin cee9b076f2c63104ccfd497fa79c39a867293ec4 \
 && git checkout -q FETCH_HEAD \
 && git submodule update --init --recursive --depth 1 \
 && meson setup build --prefix=/usr/local --buildtype=release \
      -Dvulkan=enabled -Dvk-proc-addr=enabled \
      -Dvulkan-registry=/usr/local/share/vulkan/registry/vk.xml \
      -Dshaderc=enabled -Dglslang=disabled \
      -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
 && ninja -C build && ninja -C build install && ldconfig

ENTRYPOINT ["/bin/bash"]
```

### The NVENC track image

Much smaller: no Vulkan headers, no libplacebo, because `vf_libplacebo` is not on the path being
debugged. What it does need is **nv-codec-headers at the tag CI pins** — read the commit out of
`builder/scripts.d/50-ffnvcodec.sh` rather than hardcoding it a second time, exactly as with the
Vulkan headers below. That file's header also records the **minimum driver version** the pin
requires; check the host against it before building, because the failure otherwise arrives as a
runtime encoder error rather than a version complaint.

```dockerfile
FROM ${BASE_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential git quilt yasm nasm pkg-config cmake python3 ca-certificates \
      libva-dev libdrm-dev \
 && rm -rf /var/lib/apt/lists/*
RUN git clone -q https://github.com/FFmpeg/nv-codec-headers.git /opt/nvh \
 && cd /opt/nvh && git checkout -q <SCRIPT_COMMIT from 50-ffnvcodec.sh> \
 && make install PREFIX=/usr/local
ENTRYPOINT ["/bin/bash"]
```

`libva-dev` is in there deliberately even though NVENC does not use it: it is what lets
`hevc_vaapi` compile on a host with no AMD GPU, which is the only way to check that a change to
shared code has not broken the other encoder. Compiling it costs seconds; not compiling it means
finding out from CI.

Confirm the headers are the ones you meant before building ffmpeg:

```bash
pkg-config --modversion ffnvcodec      # must match the pinned tag
```

Three things in the VAAPI image are not obvious and each costs an hour to rediscover:

- **`ENTRYPOINT ["/bin/bash"]`.** If the base image has an init system (s6, linuxserver.io style),
  it swallows whatever command you pass and you get a banner instead of output.
- **The Vulkan headers.** Pin the same tag `builder/scripts.d/47-vulkan/45-vulkan-headers.sh` uses.
  Only headers are installed; the loader stays the image's. That is safe — the release binaries are
  built against these headers and run against older loaders in exactly this way.
- **libplacebo from source, at the pinned commit.** Not a distro package. Check whether the tag you
  build ships `patches/libplacebo/`; if it does, apply them (`git ls-tree -r --name-only HEAD |
  grep ^patches/`).

**Verify the install changed nothing you depend on**, before trusting any measurement:

```bash
apt-get -s install --no-install-recommends build-essential libva-dev libdrm-dev \
  | grep -E '^(Inst|Remv)'          # require zero Remv lines
dpkg-query -W -f='${Version}\n' mesa-va-drivers    # unchanged from the base image
```

## 3. Configure and build

```bash
podman run --rm -v "$SCRATCH:/work:z" build-image -c '
  cd /work/src && quilt push -a
  ./configure --prefix=/work/out \
    --disable-autodetect \
    --enable-gpl --enable-version3 \
    --enable-vaapi --enable-vulkan --enable-libplacebo --enable-libdrm \
    --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  make -j"$(nproc)" && make install
'
```

For the **NVENC track**, swap the four hardware flags:

```
  --enable-ffnvcodec --enable-cuda --enable-nvenc --enable-nvdec --enable-cuvid \
  --enable-vaapi --enable-libdrm          # keep, so hevc_vaapi still compiles
```

`quilt push -a` is still not optional on either track: patches apply to the source regardless of
which codecs get configured in, and the series is what the fork *is*.

`--disable-autodetect` is where the time goes. Every *internal* codec still builds — hevc, `hwmap`,
`scale_vaapi`, `psnr`, `framemd5`, matroska — but no external codec library is linked. x265, SVT-AV1
and friends are most of a release build's wall clock and none of them are on the path you are
debugging. Add back only what your question needs.

Because `--disable-autodetect` turns a missing dependency into a hard error rather than a silent
drop, a configure failure here is informative. `vulkan requested but not found` means the headers
are too old, not that Vulkan is absent.

## 4. The loop

```bash
# edit $SCRATCH/src/libavutil/hwcontext_vaapi.c
podman run --rm -v "$SCRATCH:/work:z" build-image -c \
  'cd /work/src && make -j"$(nproc)" && make install'
```

One object recompiles and the binary relinks. Measured: **5.5 seconds**.

This is what makes instrumentation cheap. Rather than reasoning about which fourcc a Vulkan export
produces, add a log line and read it:

```c
#include "avutil.h"    /* av_fourcc2str lives here; hwcontext_vaapi.c does not include it */

for (j = 0; j < desc->nb_layers; j++)
    av_log(dst_fc, AV_LOG_INFO, "layer %d fourcc %s\n",
           j, av_fourcc2str(desc->layers[j].format));
```

Keep instrumentation in the build tree. It does not belong in `patches/`, where it would ship in
release binaries and need a `checks/` declaration.

## 5. Running against the GPU

```bash
# VAAPI track
podman run --rm --device /dev/dri -v "$SCRATCH:/work:z" build-image -c '
  vainfo | head -3
  /work/out/bin/ffmpeg -filters | grep -E "libplacebo|hwmap"
'

# NVENC track -- CDI, and no :z (see the SELinux note, which is podman-only)
docker run --rm --device nvidia.com/gpu=all -v "$SCRATCH:/work" build-image -c '
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  /work/out/bin/ffmpeg -hide_banner -h encoder=hevc_nvenc | head -3
'
```

⚠ **Testing a hardware code path requires a hardware decode, not just a hardware encoder.**
`avctx->pix_fmt` is `AV_PIX_FMT_CUDA` (or `AV_PIX_FMT_D3D11`) **only** when there is a hardware
frames context. Feed a software-decoded frame and any bug in that branch simply does not occur, and
the test passes having exercised nothing. Use `-hwaccel cuda -hwaccel_output_format cuda`, or
`-hwaccel vaapi -hwaccel_output_format vaapi`, deliberately.

Reproduce the known-bad case before trusting any result. If a chain that is supposed to fail does
not fail, the environment is wrong and every later number is meaningless — and if your *control*
fails too, your filter graph is wrong rather than the code. That signal caught three bad
reconstructions in a row while diagnosing `0003`.

Use the real filter graph, not a plausible one. Device topology matters: a chain rooted at a DRM
device with vaapi and vulkan both derived from it behaves differently from one where vulkan is
derived from vaapi, and the wrong topology fails several stages before the code you want to reach.

## SELinux — podman on the Fedora family only

**None of this applies to docker on a Debian/Ubuntu host**: there is no `:z`, no `podman unshare`,
and adding a `:z` there is at best a no-op. If you are on the NVENC track with docker, skip the
section.

Three separate failures, all reported as permission errors that do not mention SELinux:

| symptom | cause | fix |
|---|---|---|
| `cannot apply additional memory protection after relocation` | container image store on a volume labelled `unlabeled_t` | keep the store in podman's default location, or `semanage fcontext -a -e /var/lib/containers <path> && restorecon -R <path>` |
| `Permission denied` reading bind-mounted files inside the container | mount not relabelled | add `:z` to that `-v` |
| `rm -rf` on a rootless image store fails | layers are owned by mapped UIDs | `podman unshare rm -rf <path>` |

**Never put `:z` on a directory of your own media or data.** It relabels recursively and
persistently. For read-only input from such a directory use `--security-opt label=disable` on that
container instead, which changes nothing on disk.

## What this binary is not

- **shared, not static** — it links libplacebo from `/usr/local`; release artifacts bake it in
- **no external codecs** — by design
- **not a release artifact** — **never install it over any packaged ffmpeg path.** It reports the
  same version string as the release build, so anything that hashes that string cannot tell the two
  apart, and a measurement campaign keyed on it will silently attribute this binary's numbers to the
  released one. Install alongside, always.
- **it will not pass the full gate** — `verify-binary.sh` also checks baseline features such as
  `tonemap_cuda` that `--disable-autodetect` leaves out by design. Expect the per-patch checks to
  pass and the baseline ones to fail; that is the dev build being a dev build. Hand anyone else a CI
  release artifact, not this.

Use it to answer questions. Ship the answer as a patch, and let CI build the binary.
