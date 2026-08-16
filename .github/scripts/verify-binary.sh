#!/usr/bin/env bash
#
# verify-binary.sh <path to ffmpeg or ffmpeg.exe>
#
# Asks ffmpeg whether the built binary carries the features this fork exists for, rather than
# grepping the binary for strings. `-h encoder=` reads the encoder's static AVOption table and
# `-filters` the compiled-in filter list; neither loads the NVIDIA driver, so this runs on a
# machine with no GPU. Must run on the binary's own platform.
#
# Exists because a win64 asset shipped with NVENC but none of the tuning options: Windows pins
# nv-codec-headers in msys2/PKGBUILD, not builder/scripts.d, and nothing in the pipeline looked
# past the plumbing.

set -uo pipefail

FF="${1:-}"
[ -n "$FF" ] || { echo "::error::usage: verify-binary.sh <ffmpeg binary>"; exit 2; }
[ -f "$FF" ] || { echo "::error::not found: $FF"; exit 1; }

out=$("$FF" -hide_banner -h encoder=hevc_nvenc 2>&1) || {
  echo "::error::$FF could not describe hevc_nvenc"
  echo "$out"
  exit 1
}

fail=0

# ffmpeg prints options as "  -tf_level  <int>  E..V..." and named constants inside a unit as
# "     uhq  4  E..V..." — undashed and further indented. Anchoring to line start with optional
# dash matches both. An unanchored \bopt\b would also match description text: \bnone\b appears
# six times in libx264's help output.
for opt in uhq tf_level lookahead_level split_encode_mode; do
  if grep -qE "^[[:space:]]+-?${opt}[[:space:]]" <<<"$out"; then
    echo "  ok    hevc_nvenc: ${opt}"
  else
    echo "::error::hevc_nvenc is missing: ${opt}"
    fail=1
  fi
done

if "$FF" -hide_banner -filters 2>/dev/null | grep -qE '[[:space:]]tonemap_cuda[[:space:]]'; then
  echo "  ok    filter: tonemap_cuda"
else
  echo "::error::missing filter: tonemap_cuda"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::$FF does not carry the features this fork exists for"
  exit 1
fi
echo "  all checks passed for $FF"
