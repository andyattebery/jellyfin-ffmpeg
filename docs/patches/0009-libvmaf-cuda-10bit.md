# 0009 — `libvmaf_cuda` accepts 10-, 12- and 16-bit input

| | |
|---|---|
| **Status** | Shipping. Ungateable; correctness held by a by-hand measurement, recorded below. |
| **Covers** | `linux64` only — the target [0008](0008-cuda-libvmaf.md) builds `libvmaf_cuda` for |
| **Retires when** | Upstream FFmpeg widens `supported_formats[]` itself, at which point `git apply` fails loudly |
| **Gate** | `checks/0009.checks` — `ungateable linux64`, with the reason |
| **Requires** | **[0008](0008-cuda-libvmaf.md)**, and specifically the libvmaf motion fix its `55-libvmaf.sh` applies |

## The problem

[0008](0008-cuda-libvmaf.md) shipped CUDA VMAF and it worked — on 8-bit. Every 10-bit source, which
is every HDR and Dolby Vision source this fork exists to encode, died at config time:

```
[graph 0 input from stream 0:0] w:1920 h:1080 pixfmt:yuv420p10le
[Parsed_libvmaf_cuda_4] Unsupported input format: yuv420p10le
[fc#0] Task finished with error code: -22 (Invalid argument)
```

`libvmaf_cuda`'s entire accepted set was two entries — 8-bit `yuv420p` and `yuv444p16` — against
the CPU filter's twelve. FFmpeg **master** still has the same two, so this is upstream's state, not
a jellyfin-ffmpeg defect.

## What it does

Makes `supported_formats[]` match the CPU filter's `pix_fmts[]`: 4:4:4 / 4:2:2 / 4:2:0 at 8, 10, 12
and 16 bit. That is also exactly the set `pix_fmt_map()` already understood.

Nothing behind the check needed changing, which is what made it a list problem rather than a code
problem: `pix_fmt_map()` already mapped `AV_PIX_FMT_YUV420P10LE`, `bpc` is read straight off the
format via `desc->comp[0].depth`, the device copy sizes itself as `w * ((bpc + 7) / 8)`, and
libvmaf's CUDA backend accepts bpc 8–16 with every feature extractor parameterised on the actual
value.

**Semi-planar formats are deliberately excluded.** `p010` stores luma MSB-aligned (`value << 6`)
while `desc->comp[0].depth` still reports 10, so libvmaf would read it 64× too bright and return a
plausible, wrong score instead of an error. Feed it through `scale_cuda=format=yuv420p10` instead.

## Why this patch is useless without 0008's libvmaf fix

Widening the list alone produces a **silently wrong score** — strictly worse than the error it
replaces. libvmaf's CUDA 16bpc motion kernel does `uint16_t*` pointer arithmetic with
`src.stride[0]`, which is a *byte* stride, so it advances two image rows per row and reads past the
luma plane. That is [Netflix/vmaf#1566](https://github.com/Netflix/vmaf/issues/1566), open and
unmerged; `builder/scripts.d/55-libvmaf.sh` carries the one-line fix, guarded by an assert that
fails the build if it ever stops applying.

Measured here, 5 s of 1080p 10-bit, CUDA against the CPU `libvmaf` filter on the same pair:

| | VMAF | vs CPU |
|---|---|---|
| CPU 10-bit — the reference | 97.960520 | — |
| CUDA 10-bit, **without** the libvmaf fix | 96.902962 | **−1.058** |
| CUDA 10-bit, **with** it | **97.960604** | **+0.000084** |
| CUDA 8-bit (unaffected either way) | 97.929946 | +0.000083 |

So 10-bit now lands at the same accuracy the 8-bit path always had. Per-feature, only motion was
ever wrong — every `integer_adm_scale*` and `integer_vif_scale*` matched the CPU to six decimal
places before and after.

Speed on that clip: **11 s versus the CPU filter's 31 s.**

## What was measured, and what was not

Honest scope: **8-bit and 10-bit were measured. 12- and 16-bit were not.** The mechanism is uniform
— one `bpc` value threaded through parameterised kernels, so they are the same code path with a
different constant — but that is an argument, not a measurement. If a 12-bit sample turns up,
measure it.

Also not taken: [Netflix/vmaf#1562](https://github.com/Netflix/vmaf/issues/1562), an edge-mirror
off-by-one affecting *both* motion kernels, worth ~2e-3 VMAF at 854×480 and shrinking as 1/width.
That is the same order as the +0.00008 already tolerated at 8-bit, and its suggested fix is a
rewrite of both kernels. Out of scope, recorded so it is not rediscovered.

## Gate

```
ungateable  linux64  <reason>
```

A filter's accepted pixel-format list is exposed by neither `-h filter=` nor `-filters`, and the
only alternative — running the filter — needs a CUDA device the runners do not have.
`config_props_cuda` dereferences `hw_frames_ctx` before reaching the format check, so there is not
even a way to fail informatively without a GPU.

**Nothing in CI will notice if 10-bit correctness regresses.** 0008's two `filter` checks prove
`libvmaf_cuda` is *present*; nothing proves it is *right*. Three things stand in:

1. the assert in `55-libvmaf.sh`, which fails the build if the libvmaf motion fix stops applying;
2. `verify-binary.sh --score <binary>`, run on a GPU host — it scores generated 10- and 8-bit clips
   and asserts CUDA against the binary's own CPU `libvmaf` filter, refusing (exit 2) rather than
   skipping if there is no GPU. On the #1566 bug it discriminates by +24.3 VMAF against a 0.01
   tolerance;
3. the table above, to be re-measured after any libvmaf bump.

Wiring (2) into CI needs a self-hosted GPU runner; the command is written so such a job would just
invoke it.

## Using it

No `scale_cuda` needed; feed native 10-bit straight in:

```bash
ffmpeg -init_hw_device cuda=cu -filter_hw_device cu \
       -i dis.mkv -i ref.mkv \
       -lavfi "[0:v]format=yuv420p10le,hwupload_cuda[d]; \
               [1:v]format=yuv420p10le,hwupload_cuda[r]; \
               [d][r]libvmaf_cuda=log_fmt=json:log_path=out.json" \
       -f null -
```

⚠ Adding `feature=name=cambi|name=psnr|name=float_ssim` works, but those three have no CUDA
extractor — only ADM, motion and VIF do. libvmaf keeps a host copy and downloads every frame off
the GPU for them, which is most of what the GPU path saves. If speed is the point, leave them off.
