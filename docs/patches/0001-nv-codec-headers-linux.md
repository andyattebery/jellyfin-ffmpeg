# 0001 — nv-codec-headers pin, linux build system

| | |
|---|---|
| **Status** | Shipping. Gated on every linux build. |
| **Covers** | `linux64` **and** `linuxarm64` — one file feeds both |
| **Retires when** | Upstream bumps its own nv-codec-headers pin, at which point `git apply` fails loudly |
| **Gate** | `checks/0001.checks` — four `encoder-option` checks on `hevc_nvenc`, declared `linux` |

## What it does

Moves `SCRIPT_COMMIT` in `builder/scripts.d/50-ffnvcodec.sh` from `n12.0.16.1` to **`n13.0.19.1`**.

That is the whole change. What it buys, and why the pin is low upstream, is in
[the nv-codec-headers pin](../nv-codec-headers-pin.md) — read that first if you are touching either
pin patch.

## Why it covers both linux targets

`builder/build.sh:27` sources `scripts.d/` whatever `$TARGET` is, so `linux64` and `linuxarm64`
share this one line. The patch attaches to a **build system**, not to a target — which is why
adding the arm64 target cost no new patches.

## Gate

Proven by four AVOptions on `hevc_nvenc`, which only exist when the headers report API ≥ 12.2:

```
uhq   tf_level   lookahead_level   split_encode_mode
```

`checks/0001.checks` declares them `linux`. **`checks/0002.checks` declares the same four as
`windows`** — that duplication is deliberate and must not be collapsed. See
[the pin doc](../nv-codec-headers-pin.md#how-the-gate-mirrors-this) for why.

## Gotchas

- **This patch alone is not enough.** Windows pins the same headers somewhere else entirely.
  Patching one build system and not the other produces a binary with NVENC and none of the
  options, silently — it has already shipped that way once.
- The pin stops at `n13.0.19.1` because `n13.1.15.0` would raise the NVIDIA driver floor from 570.0
  to 610.0.
