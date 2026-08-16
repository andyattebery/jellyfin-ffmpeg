#!/usr/bin/env bash
#
# resolve-upstream.sh — decide which upstream release to build, and what to call the result.
#
# This repo is a build recipe, not a fork of the source (same shape as BtbN/FFmpeg-Builds, from
# which jellyfin-ffmpeg's builder/ is derived). The change we carry lives in patches/, applied
# with `git apply` at build time — so this script does NO git operations at all. It only
# resolves, decides, and emits outputs.
#
#   ./resolve-upstream.sh --self-test   pure-logic assertions, no network, <1s.
#                                       The workflow runs this FIRST on every invocation.
#   ./resolve-upstream.sh --plan        resolve against the live API and print what it would do.
#   ./resolve-upstream.sh               emit outputs for the workflow.
#
# Env: UPSTREAM LINE PIN_NAME WANT_TAG FORCE MODE GH_TOKEN GITHUB_REPOSITORY GITHUB_OUTPUT

set -euo pipefail

: "${UPSTREAM:=jellyfin/jellyfin-ffmpeg}"
# Track the 8.x line specifically: upstream still ships 7.1.x as "stable" and marks every 8.x
# release a prerelease, so /releases/latest reports v7.1.4-3 and would silently downgrade this
# recipe off the line that carries NVENC_HAVE_UHQ_TUNING.
: "${LINE:=v8.}"
: "${PIN_NAME:=n13.0.19.1}"
: "${WANT_TAG:=}"
: "${FORCE:=false}"
: "${MODE:=full}"          # full | dry_run | smoke

die()  { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*" >&2; }
note() { echo "$*"; }

# ---------------------------------------------------------------------------------------
# Pure helpers — everything --self-test asserts against. No network, no filesystem.
# ---------------------------------------------------------------------------------------

# Our release tags carry a fork suffix; upstream's do not. Every comparison must run on the
# stripped base. Comparing a suffixed tag against a bare one never matches, which would rebuild
# and republish every single day.
base_tag() { printf '%s\n' "${1%%+*}"; }

# '+' is semver build-metadata and legal in a git ref (verified with git check-ref-format).
fork_tag() { printf '%s+nvenc-%s\n' "$1" "$PIN_NAME"; }

# Tags produced by test runs, which must never be treated as a real prior release. A leftover
# -dryrun/-smoke release would otherwise be picked as .[0], strip to the current upstream tag,
# and make the next real run a silent no-op. Same trap a hand-made release would spring.
is_test_tag() { case "$1" in *-dryrun|*-smoke) return 0 ;; *) return 1 ;; esac; }

# Newest of OUR real releases. Reads a tag list on stdin, newest first.
pick_ours() {
  local t
  while read -r t; do
    [ -n "$t" ] || continue
    is_test_tag "$t" && continue
    printf '%s\n' "$t"
    return 0
  done
  return 0
}

# is_older A B — true when A sorts strictly older than B. Both bare (no leading 'v').
is_older() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# proceed_verdict UP OURS FORCE -> build | skip. Both args already stripped to bare upstream form.
proceed_verdict() {
  if [ "$1" = "$2" ] && [ "$3" != "true" ]; then echo skip; else echo build; fi
}

# Assets are named from debian/changelog by builder/build.sh:88, NOT from the git tag, so a fork
# build is byte-identically named to upstream's. '-nvenc-' not '+nvenc-': '+' is fine in a git
# ref but invites encoding trouble in filenames and URLs.
asset_renamed() { case "$1" in *-nvenc-*) return 0 ;; *) return 1 ;; esac; }
asset_rename()  { printf '%s\n' "${1/_${2}_/_${2}-nvenc-${PIN_NAME}_}"; }

# Like asset_rename but fails when the substitution did nothing. `mv a a` exits 0 (verified), and
# an "expected 2 files" count passes just as happily with 2 UNRENAMED files — so a no-op cannot
# be left for `set -e` to catch. Without this the release ships upstream-named assets, green.
asset_rename_checked() {
  local new; new=$(asset_rename "$1" "$2")
  [ "$new" != "$1" ] || return 1
  printf '%s\n' "$new"
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

self_test() {
  echo "resolve-upstream --self-test"

  # -- tag suffix handling
  ok "base_tag strips fork suffix"   "$(base_tag 'v8.1.2-2+nvenc-n13.0.19.1')"        'v8.1.2-2'
  ok "base_tag strips test suffix"   "$(base_tag 'v8.1.2-2+nvenc-n13.0.19.1-dryrun')" 'v8.1.2-2'
  ok "base_tag passes bare through"  "$(base_tag 'v8.1.2-2')"                         'v8.1.2-2'
  ok "fork_tag builds our tag"       "$(fork_tag 'v8.1.2-2')"      'v8.1.2-2+nvenc-n13.0.19.1'

  # -- test-tag exclusion. A leftover test release must not be mistaken for a real one, or the
  #    next real run silently does nothing — the same trap a hand-made release would spring.
  ok_true  "is_test_tag: -dryrun" is_test_tag 'v8.1.2-2+nvenc-n13.0.19.1-dryrun'
  ok_true  "is_test_tag: -smoke"  is_test_tag 'v8.1.2-2+nvenc-n13.0.19.1-smoke'
  ok_false "is_test_tag: real release" is_test_tag 'v8.1.2-2+nvenc-n13.0.19.1'
  ok "pick_ours skips test tags" \
     "$(printf 'v8.1.2-2+nvenc-n13.0.19.1-dryrun\nv8.1.2-2+nvenc-n13.0.19.1-smoke\nv8.1.1-4+nvenc-n13.0.19.1\n' | pick_ours)" \
     'v8.1.1-4+nvenc-n13.0.19.1'
  ok "pick_ours keeps real releases" \
     "$(printf 'v8.1.2-2+nvenc-n13.0.19.1\nv8.1.1-4+nvenc-n13.0.19.1\n' | pick_ours)" \
     'v8.1.2-2+nvenc-n13.0.19.1'
  ok "pick_ours on empty input" "$(printf '' | pick_ours)" ''
  ok "pick_ours when ALL are test tags" \
     "$(printf 'v8.1.2-2+nvenc-n13.0.19.1-dryrun\nv8.1.2-2+nvenc-n13.0.19.1-smoke\n' | pick_ours)" ''

  # -- the proceed decision, on stripped bases
  ok "already released -> skip" \
     "$(proceed_verdict 'v8.1.2-2' "$(base_tag 'v8.1.2-2+nvenc-n13.0.19.1')" false)" skip
  ok "unsuffixed compare would rebuild forever" \
     "$(proceed_verdict 'v8.1.2-2' 'v8.1.2-2+nvenc-n13.0.19.1' false)" build
  ok "newer upstream -> build" \
     "$(proceed_verdict 'v8.1.2-2' "$(base_tag 'v8.1.1-4+nvenc-n13.0.19.1')" false)" build
  ok "force overrides already-released" "$(proceed_verdict 'v8.1.2-2' 'v8.1.2-2' true)" build
  ok "no prior release -> build"        "$(proceed_verdict 'v8.1.2-2' none false)"      build

  # -- version ordering (the no-downgrade guard)
  ok_false "same tag is not older"            is_older '8.1.2-2' '8.1.2-2'
  ok_true  "8.1.1-4 older than 8.1.2-2"       is_older '8.1.1-4' '8.1.2-2'
  ok_false "8.1.2-2 not older than 8.1.1-4"   is_older '8.1.2-2' '8.1.1-4'
  ok_true  "7.1.4-3 older than 8.1.1-1"       is_older '7.1.4-3' '8.1.1-1'
  ok_true  "raw suffixed tag misorders (why we strip)" is_older '8.1.2-2' '8.1.2-2+nvenc-n13.0.19.1'

  # -- asset renaming, against the real upstream filenames. All four built targets:
  #    linux64 and linuxarm64 from builder/build.sh:88, win64 and winarm64 from
  #    msys2/build.sh and msys2/buildarm64.sh.
  local L='dist/jellyfin-ffmpeg_8.1.2-2_portable_linux64-gpl.tar.xz'
  local LA='dist/jellyfin-ffmpeg_8.1.2-2_portable_linuxarm64-gpl.tar.xz'
  local W='dist/jellyfin-ffmpeg_8.1.2-2_portable_win64-clang-gpl.zip'
  local WA='dist/jellyfin-ffmpeg_8.1.2-2_portable_winarm64-clang-gpl.zip'
  ok "rename linux asset"   "$(asset_rename "$L" '8.1.2-2')" \
     'dist/jellyfin-ffmpeg_8.1.2-2-nvenc-n13.0.19.1_portable_linux64-gpl.tar.xz'
  ok "rename linuxarm64 asset" "$(asset_rename "$LA" '8.1.2-2')" \
     'dist/jellyfin-ffmpeg_8.1.2-2-nvenc-n13.0.19.1_portable_linuxarm64-gpl.tar.xz'
  ok "rename windows asset" "$(asset_rename "$W" '8.1.2-2')" \
     'dist/jellyfin-ffmpeg_8.1.2-2-nvenc-n13.0.19.1_portable_win64-clang-gpl.zip'
  ok "rename winarm64 asset" "$(asset_rename "$WA" '8.1.2-2')" \
     'dist/jellyfin-ffmpeg_8.1.2-2-nvenc-n13.0.19.1_portable_winarm64-clang-gpl.zip'

  # The renamed name must still match upstream's own glob shape — build-linux-amd64:24 uses
  # jellyfin-ffmpeg*portable_linux64-gpl*.tar.xz. This is the assertion that chose the scheme
  # over inserting after _portable_, which breaks it.
  local renamed; renamed=$(basename "$(asset_rename "$L" '8.1.2-2')")
  case "$renamed" in
    jellyfin-ffmpeg*portable_linux64-gpl*.tar.xz) ok "renamed keeps upstream glob shape" y y ;;
    *) ok "renamed keeps upstream glob shape" "$renamed" 'a name matching the glob' ;;
  esac
  local rejected='jellyfin-ffmpeg_8.1.2-2_portable_nvenc-n13.0.19.1_linux64-gpl.tar.xz'
  case "$rejected" in
    jellyfin-ffmpeg*portable_linux64-gpl*.tar.xz) ok "rejected scheme breaks the glob" matched 'no match' ;;
    *) ok "rejected scheme breaks the glob" 'no match' 'no match' ;;
  esac

  # Same glob assertion for the arm64 target — build-linux-arm64:24 uses
  # jellyfin-ffmpeg*portable_linuxarm64-gpl*.tar.xz.
  local renamed_arm; renamed_arm=$(basename "$(asset_rename "$LA" '8.1.2-2')")
  case "$renamed_arm" in
    jellyfin-ffmpeg*portable_linuxarm64-gpl*.tar.xz) ok "renamed arm64 keeps upstream glob shape" y y ;;
    *) ok "renamed arm64 keeps upstream glob shape" "$renamed_arm" 'a name matching the glob' ;;
  esac

  # THE architecture assertion. Both linux assets are .tar.xz and differ only by an infix, so a
  # deployment glob that matched both would install an aarch64 binary on an x86-64 host. It does
  # not — 'linux64' is not a substring of 'linuxarm64' — but that is worth pinning down rather
  # than re-reasoning about, because the Ansible playbook globs on exactly this shape.
  case "$renamed_arm" in
    jellyfin-ffmpeg*portable_linux64-gpl*.tar.xz) ok "linux64 glob does NOT match an arm64 asset" matched 'no match' ;;
    *) ok "linux64 glob does NOT match an arm64 asset" 'no match' 'no match' ;;
  esac
  case "$renamed" in
    jellyfin-ffmpeg*portable_linuxarm64-gpl*.tar.xz) ok "linuxarm64 glob does NOT match an amd64 asset" matched 'no match' ;;
    *) ok "linuxarm64 glob does NOT match an amd64 asset" 'no match' 'no match' ;;
  esac
  # Same trap on the windows side: winarm64-clang vs win64-clang. Positive control first — a
  # "does not match" result proves nothing unless the same glob is shown to match something.
  local renamed_win64; renamed_win64=$(basename "$(asset_rename "$W" '8.1.2-2')")
  case "$renamed_win64" in
    jellyfin-ffmpeg*portable_win64-clang-gpl*.zip) ok "win64 glob matches the win64 asset (control)" y y ;;
    *) ok "win64 glob matches the win64 asset (control)" "$renamed_win64" 'a name matching the glob' ;;
  esac
  local renamed_win; renamed_win=$(basename "$(asset_rename "$WA" '8.1.2-2')")
  case "$renamed_win" in
    jellyfin-ffmpeg*portable_win64-clang-gpl*.zip) ok "win64 glob does NOT match a winarm64 asset" matched 'no match' ;;
    *) ok "win64 glob does NOT match a winarm64 asset" 'no match' 'no match' ;;
  esac
  case "$renamed_win" in
    jellyfin-ffmpeg*portable_winarm64-clang-gpl*.zip) ok "winarm64 glob matches the winarm64 asset (control)" y y ;;
    *) ok "winarm64 glob matches the winarm64 asset (control)" "$renamed_win" 'a name matching the glob' ;;
  esac
  # Both directions, as for the linux pair — one-way exclusion is not the same claim.
  case "$renamed_win64" in
    jellyfin-ffmpeg*portable_winarm64-clang-gpl*.zip) ok "winarm64 glob does NOT match a win64 asset" matched 'no match' ;;
    *) ok "winarm64 glob does NOT match a win64 asset" 'no match' 'no match' ;;
  esac

  ok_true  "guard trips on already-renamed" asset_renamed 'jellyfin-ffmpeg_8.1.2-2-nvenc-n13.0.19.1_portable_linux64-gpl.tar.xz'
  ok_false "guard passes a fresh name"      asset_renamed 'jellyfin-ffmpeg_8.1.2-2_portable_linux64-gpl.tar.xz'
  ok_false "checked rename REJECTS a no-op" asset_rename_checked 'dist/jellyfin-ffmpeg-8.1.2-2-linux64.tar.xz' '8.1.2-2'
  ok_true  "checked rename accepts a real rename" asset_rename_checked "$L" '8.1.2-2'
  ok_false "checked rename rejects a wrong version" asset_rename_checked "$L" '9.9.9-9'

  # -- rename holds across every tag on the tracked line
  local t v
  for t in v8.1.2-2 v8.1.2-1 v8.1.1-4 v8.1.1-3 v8.1.1-2 v8.1.1-1; do
    v="${t#v}"
    ok "rename holds for $t" \
       "$(asset_rename "jellyfin-ffmpeg_${v}_portable_linux64-gpl.tar.xz" "$v")" \
       "jellyfin-ffmpeg_${v}-nvenc-n13.0.19.1_portable_linux64-gpl.tar.xz"
  done

  ok_true "fork tag is a legal git ref" git check-ref-format "refs/tags/$(fork_tag v8.1.2-2)"

  echo
  [ "$FAILED" -eq 0 ] || die "self-test: $FAILED of $TESTS assertions failed"
  note "self-test: $TESTS assertions passed"
}

# ---------------------------------------------------------------------------------------

# Read a file out of upstream at a tag. Uses the raw Accept header rather than base64, because
# `base64 -d` (GNU) and `base64 -D` (BSD) differ and --plan runs on macOS.
read_upstream() {
  gh api "repos/${UPSTREAM}/contents/$1?ref=${UP}" -H "Accept: application/vnd.github.raw"
}

resolve() {
  if [ -n "$WANT_TAG" ]; then
    UP="$WANT_TAG"
    note "upstream tag pinned by input: $UP"
  else
    UP=$(gh api "repos/${UPSTREAM}/releases?per_page=100" \
           --jq "[.[] | select(.draft==false) | .tag_name | select(startswith(\"${LINE}\"))] | .[0] // empty")
    [ -n "$UP" ] || die "no upstream release matching ${LINE}* in the first 100 releases"
  fi

  OURS_RAW=$(gh api "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
               --jq '[.[] | select(.draft==false) | .tag_name] | .[]' 2>/dev/null | pick_ours || true)
  OURS_RAW="${OURS_RAW:-none}"
  if [ "$OURS_RAW" = "none" ]; then OURS=none; else OURS=$(base_tag "$OURS_RAW"); fi

  note "upstream=$UP  ours=$OURS (from ${OURS_RAW})  line=${LINE}  force=${FORCE}  mode=${MODE}"

  if [ "$OURS" != "none" ] && is_older "${UP#v}" "${OURS#v}"; then
    die "upstream $UP sorts older than our $OURS — refusing to downgrade."
  fi

  RELEASE_TAG=$(fork_tag "$UP")
  case "$MODE" in
    dry_run) RELEASE_TAG="${RELEASE_TAG}-dryrun" ;;
    smoke)   RELEASE_TAG="${RELEASE_TAG}-smoke" ;;
  esac

  if [ "$(proceed_verdict "$UP" "$OURS" "$FORCE")" = "skip" ]; then
    PROCEED=false
    note "Already released $UP here. Nothing to do."
  else
    PROCEED=true
  fi
}

# The build derives asset names from debian/changelog (builder/build.sh:88), not the git tag.
# Read it the same way so the rename cannot drift, and surface it if the two disagree.
read_pkg_ver() {
  PKG_VER=$(read_upstream debian/changelog | sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p')
  [ -n "$PKG_VER" ] || die "could not parse a version from upstream debian/changelog at ${UP}"
  [ "$PKG_VER" = "${UP#v}" ] || \
    warn "changelog says ${PKG_VER} but the tag is ${UP} — assets are named off the changelog"
}

# Advisory. We copy 4 wrapper steps out of upstream's reusable workflows; this warns if upstream
# edits them. Reads UPSTREAM at the tag, never a local copy — a stale local copy compared against
# itself could never fire. Warning-only: failing would block releases on a reformat.
drift_check() {
  local h
  h=$( { read_upstream .github/workflows/_meta_portable.yaml
         read_upstream .github/workflows/_meta_win_clang_portable.yaml
       } | grep -E '^[[:space:]]+(run:|- name: Build Portable|install:)|^[[:space:]]{12}[a-z0-9-]+$' \
         | shasum -a 256 | cut -c1-16 )
  if [ -z "${DRIFT_HASH:-}" ]; then
    note "drift baseline (record as DRIFT_HASH): $h"
  elif [ "$h" != "$DRIFT_HASH" ]; then
    warn "upstream build-wrapper steps changed (hash $h, expected $DRIFT_HASH) — re-check our copies"
  else
    note "drift check: wrapper unchanged ($h)"
  fi
}

emit() {
  note ""
  note "proceed=${PROCEED}"
  note "upstream_tag=${UP}"
  note "release_tag=${RELEASE_TAG}"
  note "pkg_ver=${PKG_VER:-<unread>}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "proceed=${PROCEED}"
      echo "upstream_tag=${UP}"
      echo "release_tag=${RELEASE_TAG}"
      echo "pkg_ver=${PKG_VER:-}"
    } >> "$GITHUB_OUTPUT"
  fi
}

main() {
  case "${1:-}" in
    --self-test) self_test; exit 0 ;;
    --plan)      PLAN=true ;;
    "")          PLAN=false ;;
    *)           echo "usage: $0 [--self-test|--plan]" >&2; exit 2 ;;
  esac

  [ -n "${GITHUB_REPOSITORY:-}" ] || die "GITHUB_REPOSITORY is not set"
  resolve

  if [ "$PROCEED" != "true" ]; then emit; exit 0; fi

  read_pkg_ver
  drift_check

  if [ "$PLAN" = "true" ]; then
    note ""
    note "--plan: would build ${UP} and publish ${RELEASE_TAG}"
    note "        assets renamed to *_${PKG_VER}-nvenc-${PIN_NAME}_portable_*"
  fi
  emit
}

main "$@"
