#!/usr/bin/env bash
#
# release-notes.sh — the body of a GitHub release, rendered for one build.
#
#   ./release-notes.sh               print the notes for the build described by the env below
#   ./release-notes.sh --self-test   render against fixtures and check them against docs/patches/. <1s.
#
# Env: UPSTREAM_TAG PIN_NAME GITHUB_REPOSITORY   required -- an empty one would render a broken name
#      UPSTREAM MODE GITHUB_SHA                  defaulted; GITHUB_SHA falls back to this checkout's HEAD
#
# Preview locally:
#   UPSTREAM_TAG=v8.1.3-1 PIN_NAME=n13.0.19.1 GITHUB_REPOSITORY=owner/repo ./release-notes.sh
#
# EVERY PATCH DOC MUST BE LINKED FROM THE NOTES. --self-test fails otherwise, and it runs in
# checks.yaml and in build-release.yaml's resolve job. So adding a patch means adding it here: a
# row in FEATURES if it changes what the binary can do, a line in BUILD_ONLY if it does not. The
# notes this replaced were echo lines in the workflow that each patch appended a paragraph to, and
# nothing noticed what was left out -- v8.1.3-1's notes mention neither Dolby Vision patch, nor
# 0003 or 0005.
#
# Doc links are pinned to the recipe commit that was built (GITHUB_SHA), not to main: the notes
# describe that binary, and a retired patch's doc no longer exists on main.

set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$SELF_DIR/../.."
DOCS_DIR="${DOCS_DIR:-$REPO_ROOT/docs/patches}"
README="${README:-$REPO_ROOT/README.md}"

: "${UPSTREAM:=jellyfin/jellyfin-ffmpeg}"
: "${MODE:=full}"          # full | dry_run | smoke
: "${GITHUB_SHA:=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)}"

# One row per user-visible feature:  label | linux64 | linuxarm64 | win64 | winarm64 | doc files
# y means the feature WORKS on that target, which is not the same as the patch applying there: a
# source patch reaches every build system, but VAAPI is only built for linux.
# shellcheck disable=SC2016  # the backticks are markdown, not command substitution
FEATURES='NVENC `-tune uhq`, `-tf_level`, `-lookahead_level` and `-split_encode_mode`|y|y|y|y|0001-nv-codec-headers-linux.md 0002-nv-codec-headers-windows.md
Dolby Vision RPU passthrough in `hevc_nvenc`|y|y|y|y|0007-dolby-vision-hevc-nvenc.md
Dolby Vision RPU passthrough in `hevc_vaapi`|y|y|n|n|0004-dolby-vision-hevc-vaapi.md
10-bit VAAPI↔Vulkan tonemapping at the speed of the 8-bit path|y|y|n|n|0003-vaapi-alpha-10bit-rgb.md
options on a derived hardware device (`-init_hw_device vulkan=vk@dr,disable_multiplane=1`)|y|y|y|y|0005-allow-options-on-derived-hw-devices.md
`libvmaf` filter|y|n|y|y|0008-cuda-libvmaf.md 0010-libvmaf-windows.md
`libvmaf_cuda` filter, 8- to 16-bit input|y|n|n|n|0008-cuda-libvmaf.md 0009-libvmaf-cuda-10bit.md'

# Patches that change how the binary is built but not what it can do:  doc file | what it does
BUILD_ONLY='0006-disable-msys2-doxygen-doc-builds.md|stops the msys2 packages building doxygen docs, which was crashing winarm64 builds'

# The footer links here rather than repeating the commands. A copy in the notes drifted once
# already: it lost the debian/patches/series step, and following it built without any source patch.
README_HEADING='Reproducing a build by hand'
README_ANCHOR='reproducing-a-build-by-hand'

# ---------------------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------------------

blob_url() { printf 'https://github.com/%s/blob/%s/%s\n' "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$1"; }

# "0001-foo.md 0002-bar.md" -> "[0001](...) [0002](...)"
doc_links() {
  local f out=""
  for f in $1; do
    out="${out:+$out }[${f%%-*}]($(blob_url "docs/patches/$f"))"
  done
  printf '%s\n' "$out"
}

mark() { if [ "$1" = y ]; then printf '✓'; fi; }

# One paragraph or bullet per output line. GitHub renders a newline inside a release body as a
# hard line break, so wrapping the output the way this source is wrapped breaks sentences on screen.
para() { printf '%s\n' "$*"; }

render() {
  : "${UPSTREAM_TAG:?UPSTREAM_TAG is required}"
  : "${PIN_NAME:?PIN_NAME is required}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GITHUB_SHA:?GITHUB_SHA is required (and not recoverable from git here)}"

  local label l64 la64 w64 wa64 docs desc
  if [ "$MODE" != full ]; then
    para "**${MODE} run — these assets are empty stubs. Delete this release and its tag.**"
    echo
  fi
  para "jellyfin-ffmpeg [\`${UPSTREAM_TAG}\`](https://github.com/${UPSTREAM}/releases/tag/${UPSTREAM_TAG})" \
       "with this repo's patches applied, built from recipe commit" \
       "[\`${GITHUB_SHA:0:7}\`](https://github.com/${GITHUB_REPOSITORY}/tree/${GITHUB_SHA})."
  echo
  para "| | linux64 | linuxarm64 | win64 | winarm64 | doc |"
  para "|---|:-:|:-:|:-:|:-:|---|"
  while IFS='|' read -r label l64 la64 w64 wa64 docs; do
    para "| ${label} | $(mark "$l64") | $(mark "$la64") | $(mark "$w64") | $(mark "$wa64") | $(doc_links "$docs") |"
  done <<EOF
$FEATURES
EOF
  echo
  while IFS='|' read -r docs desc; do
    para "Also applied, build-only: $(doc_links "$docs") ${desc}. The binary is unchanged by it."
  done <<EOF
$BUILD_ONLY
EOF
  echo
  para "**NVIDIA driver floor: 570.0.** \`libvmaf_cuda\` alone needs **580 or newer** and a" \
       "**Turing or newer** GPU; without those only that filter fails, nothing else."
  echo
  para "**These go wrong without an error:**"
  echo
  para "- Dolby Vision needs \`-dolbyvision 1\`. The \`auto\` default never engages under the ffmpeg" \
       "CLI; it warns once and writes no Dolby Vision."
  para "- MP4 output also needs \`-strict unofficial\`, or the container never declares Dolby Vision" \
       "and the file plays as plain HDR10. Matroska needs no flag."
  para "- \`libvmaf_cuda\` on 10-bit input: convert with \`scale_cuda=format=yuv420p10\`, never" \
       "\`format=yuv420p\`, which silently measures the 8-bit projection. (\`p010\` from a CUDA" \
       "decode is rejected outright, so it has to be converted.)"
  echo
  para "Assets carry \`-nvenc-${PIN_NAME}\` in the filename so they cannot be mistaken for" \
       "upstream's identically-versioned builds. To build them yourself, see" \
       "[${README_HEADING}]($(blob_url README.md)#${README_ANCHOR})."
}

# ---------------------------------------------------------------------------------------
# Pure helpers for --self-test. Text in, text out.
# ---------------------------------------------------------------------------------------

# Every doc file the two tables name, one per line.
referenced_docs() {
  { printf '%s\n' "$FEATURES" | cut -d'|' -f6 | tr ' ' '\n'
    printf '%s\n' "$BUILD_ONLY" | cut -d'|' -f1
  } | grep -v '^$' | sort -u
}

# Doc basenames linked from rendered notes, one per line.
linked_docs() { printf '%s\n' "$1" | grep -oE 'docs/patches/[^)]+\.md' | sed 's|^docs/patches/||' | sort -u; }

# unlinked <notes> <doc basenames> -> the basenames the notes never link
unlinked() { comm -23 <(printf '%s\n' "$2" | grep -v '^$' | sort -u) <(linked_docs "$1"); }

# missing_files <basenames> <dir> -> the basenames with no file in dir
missing_files() {
  local f
  for f in $1; do [ -f "$2/$f" ] || printf '%s\n' "$f"; done
}

# Rows that are not exactly six fields of label|y/n x4|docs, or that mark no target at all.
malformed_rows() {
  printf '%s\n' "$1" | awk -F'|' '
    NF != 6 { print; next }
    { for (i = 2; i <= 5; i++) if ($i != "y" && $i != "n") { print; next } }
    ($2 $3 $4 $5) == "nnnn" || $6 == "" { print }'
}

# ---------------------------------------------------------------------------------------
# --self-test
# ---------------------------------------------------------------------------------------

TESTS=0 FAILED=0
ok() {
  TESTS=$((TESTS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else FAILED=$((FAILED + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"; fi
}
ok_true()  { TESTS=$((TESTS+1)); if "${@:2}"; then printf '  ok   %s\n' "$1"; else FAILED=$((FAILED+1)); printf '  FAIL %s (expected true)\n' "$1"; fi; }
ok_false() { TESTS=$((TESTS+1)); if "${@:2}"; then FAILED=$((FAILED+1)); printf '  FAIL %s (expected false)\n' "$1"; else printf '  ok   %s\n' "$1"; fi; }

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

self_test() {
  echo "release-notes --self-test"
  local sha=0123456789abcdef0123456789abcdef01234567 notes docs f

  # Fixtures, so the result does not depend on the caller's env or checkout.
  UPSTREAM=jellyfin/jellyfin-ffmpeg UPSTREAM_TAG=v8.1.3-1 PIN_NAME=n13.0.19.1
  GITHUB_REPOSITORY=owner/repo GITHUB_SHA=$sha MODE=full

  # -- the tables themselves
  ok "every FEATURES row is label|y/n x4|docs and marks a target" "$(malformed_rows "$FEATURES")" ''
  ok "malformed_rows catches a short row (control)"  "$(malformed_rows 'x|y|y|y|a.md')" 'x|y|y|y|a.md'
  ok "malformed_rows catches a bad mark (control)"   "$(malformed_rows 'x|y|Y|y|y|a.md')" 'x|y|Y|y|y|a.md'
  ok "malformed_rows catches an all-n row (control)" "$(malformed_rows 'x|n|n|n|n|a.md')" 'x|n|n|n|n|a.md'
  ok "every doc the tables name exists" "$(missing_files "$(referenced_docs)" "$DOCS_DIR")" ''
  ok "missing_files reports a typo (control)" "$(missing_files '0001-nope.md' "$DOCS_DIR")" '0001-nope.md'

  # -- coverage: THE rule. Every patch doc in the repo must be linked from the notes.
  notes=$(render)
  docs=$(for f in "$DOCS_DIR"/[0-9][0-9][0-9][0-9]-*.md; do [ -e "$f" ] && basename "$f"; done || true)
  ok_true "there are patch docs to check against" [ -n "$docs" ]
  ok "every docs/patches/NNNN-*.md is linked from the notes" "$(unlinked "$notes" "$docs")" ''
  ok "an unlisted doc is reported (control)" \
     "$(unlinked "$notes" "$(printf '%s\n9999-not-in-the-notes.md' "$docs")")" '9999-not-in-the-notes.md'

  # -- links are pinned to the built commit, including the README one
  ok "every doc link is pinned to the built sha" \
     "$(printf '%s\n' "$notes" | grep -oE 'docs/patches/[^)]+' | wc -l | tr -d ' ')" \
     "$(printf '%s\n' "$notes" | grep -oE "/blob/${sha}/docs/patches/[^)]+" | wc -l | tr -d ' ')"
  ok_true "the README link is pinned to the built sha" contains "$notes" "/blob/${sha}/README.md#${README_ANCHOR}"
  ok_true "README still has the heading the footer links to" grep -qxF "## ${README_HEADING}" "$README"
  ok_true "the recipe commit is named" contains "$notes" "/tree/${sha}"

  # -- mode banner: only a real build is presented as one
  ok_false "full run carries no stub banner" contains "$notes" 'empty stubs'
  ok_true  "smoke run says its assets are stubs"   contains "$(MODE=smoke render)"   'empty stubs'
  ok_true  "dry_run run says its assets are stubs" contains "$(MODE=dry_run render)" 'empty stubs'

  ok_true "asset suffix names the pin" contains "$notes" "-nvenc-n13.0.19.1"
  # shellcheck disable=SC2016  # a literal '${' is exactly what must not appear
  ok_false "nothing left unexpanded" contains "$notes" '${'

  # -- an empty required input fails loudly instead of rendering a broken name
  ok_false "empty UPSTREAM_TAG is refused" eval '(UPSTREAM_TAG=; render) >/dev/null 2>&1'
  ok_false "empty PIN_NAME is refused"     eval '(PIN_NAME=; render) >/dev/null 2>&1'

  echo
  if [ "$FAILED" -ne 0 ]; then
    echo "::error::self-test: $FAILED of $TESTS assertions failed" >&2
    exit 1
  fi
  echo "  self-test: $TESTS assertions passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  "")          render ;;
  *)           echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
