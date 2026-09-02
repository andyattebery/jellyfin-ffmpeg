#!/usr/bin/env bash
#
# verify-binary.sh <path to ffmpeg or ffmpeg.exe> [target]
#                  --self-test          pure-logic assertions plus the repo's own manifests. <1s.
#                  --list [target]      what would run, and where, without a binary.
#                  --score <binary>     score generated 10- and 8-bit clips on a real GPU. Needs
#                                       CUDA; NOT part of the CI gate. See "Scoring" below.
#
# Asks ffmpeg whether the built binary carries the features this fork exists for, rather than
# grepping the binary for strings. `-h encoder=` reads the encoder's static AVOption table and
# `-filters` the compiled-in filter list; neither loads the NVIDIA driver, so this runs on a
# machine with no GPU. Must run on the binary's own platform.
#
# Exists because a win64 asset shipped with NVENC but none of the tuning options: Windows pins
# nv-codec-headers in msys2/PKGBUILD, not builder/scripts.d, and nothing in the pipeline looked
# past the plumbing.
#
# WHAT IT CHECKS IS NOT WRITTEN HERE. Each patch declares its own checks in
# patches/jellyfin-ffmpeg/checks/NNNN.checks, and this script is the generic runner over them.
# The pairing rule is the point: every NNNN-*.patch must have a checks/NNNN.checks and vice versa,
# or this script fails before it looks at a binary. A patch cannot ship without either saying how
# it is proven or declaring itself unprovable, with the reason. `baseline.checks` is the single
# exempt filename, for checks no patch here owns.
#
# Directive format -- whitespace separated, one per line, whole-line `#` comments only (an
# `ungateable` reason is prose and may contain a `#`):
#
#     encoder-option  <platform>  <encoder>  <option>
#     filter          <platform>  <name>
#     ungateable      <platform>  <reason...>
#
# <platform> is one of two tiers:
#
#   coarse   all, linux, windows          inferred from whether the binary path ends in .exe
#   fine     linux64, linuxarm64,         NOT inferable -- the workflow must pass the target as
#            win64, winarm64              the second argument, because both linux jobs hand us a
#                                         path named `ffmpeg` and architecture is not recoverable
#                                         from it. Do not try to guess arch from the binary.
#
# Use the coarse tier whenever the feature really is whole-platform; 0001 and 0002 are the model.
# Reach for the fine tier only when a patch genuinely builds for one target and not its sibling,
# as 0008 does (`ffbuild_enabled` gates on linux64, so linuxarm64 has no libvmaf at all).
#
# A fine directive encountered with NO target argument is a HARD ERROR, never a skip. Skipping
# would mean a declaration silently covering nothing -- the same class of failure as an
# unregistered kind, and the reason this gate exists at all.
#
# To add a kind:
#   1. write check_<kind>() taking the directive's args, returning 0/1, printing nothing
#   2. add its arm to run_checks
#   3. add its token to VALID_KINDS   <-- without this a misspelled kind is a silent no-op
#   4. add a --self-test fixture WITH AT LEAST ONE NEGATIVE CONTROL: a positive-only assertion
#      proves nothing about a grep
#   5. document it above
#
# Scoring (--score): the one thing this gate CANNOT prove on a CI runner.
#
# 0009 widens the pixel formats libvmaf_cuda accepts, and 0008's 55-libvmaf.sh carries a libvmaf
# motion-kernel fix. Neither is observable through `-h encoder=` or `-filters` -- the only way to
# tell a correct VMAF from a wrong one is to compute one, and libvmaf_cuda needs a real CUDA device
# that no GitHub-hosted runner has. So both are declared `ungateable`, and this mode is what stands
# in: run it by hand on a GPU host after any libvmaf bump.
#
# It asserts CUDA against the binary's OWN CPU libvmaf filter, not against a golden number. That is
# deliberate -- a hardcoded score would rot the moment the model, the content or libvmaf changed,
# whereas the two filters must agree with each other whatever they are computing.
#
# Content is GENERATED, not shipped: two identical testsrc2 sources in one graph, one distorted by
# a scale round-trip. No sample file, no licence question, no temp files, and nothing to keep in
# sync. Measured discrimination on the Netflix/vmaf#1566 motion-stride bug: delta -0.000046 with
# the fix, +24.298661 without it. A 0.01 tolerance catches that by ~2400x.
#
# To add a target: add its token to VALID_PLATFORMS and to FINE_PLATFORMS, teach
# platform_of_target() its coarse platform, add a --self-test fixture with a negative control, and
# pass it from that job's verify-binary.sh call site in build-release.yaml.

set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="${PATCH_DIR:-$SELF_DIR/../../patches/jellyfin-ffmpeg}"
CHECKS_DIR="${CHECKS_DIR:-$PATCH_DIR/checks}"
DOCS_DIR="${DOCS_DIR:-$SELF_DIR/../../docs/patches}"

VALID_KINDS=" encoder-option filter ungateable "
VALID_PLATFORMS=" all linux windows linux64 linuxarm64 win64 winarm64 "
FINE_PLATFORMS=" linux64 linuxarm64 win64 winarm64 "

# ---------------------------------------------------------------------------------------
# Pure helpers -- everything --self-test asserts against. Text in, text out, no filesystem.
# ---------------------------------------------------------------------------------------

# One directive per line, trimmed. `tr -d '\r'` is not cosmetic: a CRLF checkout leaves the CR on
# the LAST field, so `dolbyvision` becomes a pattern that can never match -- a false failure on the
# two windows jobs only, 2.5h into a build. .gitattributes pins eol=lf as the other lock.
normalise() {
  tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v -e '^$' -e '^#'
}

valid_kind()     { case "$VALID_KINDS"     in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
valid_platform() { case "$VALID_PLATFORMS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
fine_platform()  { case "$FINE_PLATFORMS"  in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# The coarse platform a fine target belongs to. Used to reject `win64` passed alongside a binary
# called `ffmpeg`, which would otherwise run the windows declarations against a linux build.
platform_of_target() {
  case "$1" in
    linux64|linuxarm64) echo linux ;;
    win64|winarm64)     echo windows ;;
    *)                  echo "" ;;
  esac
}

# A file id is four digits, or the one whitelisted name. Anything else is an error rather than a
# quiet exemption from pairing.
valid_id() { case "$1" in baseline) return 0 ;; [0-9][0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

# The binary's platform, from the filename the workflow already hands us.
platform_of() { case "$1" in *.exe|*.EXE) echo windows ;; *) echo linux ;; esac; }

# applies <declared> <platform> [target]
# `all` matches everything; a coarse token matches the binary's platform; a fine token matches only
# the target the workflow named. With no target, a fine token matches nothing -- and run_checks
# turns that into an error rather than a skip.
applies() { [ "$1" = all ] || [ "$1" = "$2" ] || { [ -n "${3:-}" ] && [ "$1" = "$3" ]; }; }

# `ffmpeg -h encoder=X` EXITS 0 when X does not exist -- it prints "Codec 'X' is not recognized by
# FFmpeg." and returns success. So `out=$(... ) || die` is dead code, which is what the previous
# version of this script had. Presence must be read out of the text, and it is a HARD failure:
# hevc_vaapi vanishing from a linux build is precisely what this gate exists to catch, and
# "is it in -encoders?" would degrade that into a skip.
encoder_present() { printf '%s\n' "$1" | grep -q '^Encoder '; }

# ffmpeg prints options as "  -tf_level  <int>  E..V..." and named constants inside a unit as
# "     uhq  4  E..V..." -- undashed and further indented. Anchoring to line start with optional
# dash matches both. An unanchored \bopt\b would also match description text: \bnone\b appears
# six times in libx264's help output.
has_option() { printf '%s\n' "$1" | grep -qE "^[[:space:]]+-?${2}[[:space:]]"; }

# -filters lines are " .. tonemap_cuda   V->V   <description>". Anchoring past the flags column
# stops a match inside another filter's description prose.
has_filter() { printf '%s\n' "$2" | grep -qE "^[[:space:]]*[.A-Z]+[[:space:]]+${1}[[:space:]]"; }

# Last "VMAF score: N" in ffmpeg's stderr. Last, not first: the filter prints one per model, and a
# graph with two vmaf instances would print several. Empty output means no score at all, which the
# caller must treat as a failure rather than as zero.
parse_vmaf_score() { printf '%s\n' "$1" | grep -oE 'VMAF score: [0-9.]+' | tail -1 | sed 's/^VMAF score: //'; }

# |a - b| <= tol, via awk because bash has no float arithmetic and `bc` is not always installed --
# it is absent from the sweepbox container, for one. Returns 1 on any non-numeric input rather than
# treating it as zero, so a missing score cannot pass.
within_tolerance() {
  case "$1$2$3" in *[!0-9.]*|'') return 1 ;; esac
  awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'
}

# Names are interpolated into grep -E, so they may not carry regex metacharacters.
safe_name() { case "$1" in *[!A-Za-z0-9_]*|'') return 1 ;; *) return 0 ;; esac; }

# Pure set comparison over two newline-separated id lists. BOTH directions matter: an orphan means
# a patch was deleted and its declaration left behind, still claiming coverage that is gone.
pair_ids() {
  local a b
  a=$(printf '%s\n' "$1" | grep -v '^$' | sort -u)
  b=$(printf '%s\n' "$2" | grep -v '^$' | sort -u)
  comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/missing /'
  comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/orphan /'
}

# ---------------------------------------------------------------------------------------
# Filesystem -- deliberately trivial, so the logic above stays testable without fixtures.
# ---------------------------------------------------------------------------------------

# Without nullglob an empty directory yields the literal pattern, and ${b%%-*} would turn it into
# the phantom id "*.patch": a bogus pairing reported instead of the true "there are no patches".
patch_ids() {
  local f b
  for f in "$PATCH_DIR"/*.patch; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    echo "${b%%-*}"
  done
}

check_ids() {
  local f b
  for f in "$CHECKS_DIR"/*.checks; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    echo "${b%.checks}"
  done
}

# Docs are keyed on the four-digit prefix only, same as checks: patch titles get edited, and a
# full-name-keyed doc would silently orphan on a retitle. The glob is NNNN-*.md so the filename can
# still be readable.
doc_ids() {
  local f b
  for f in "$DOCS_DIR"/*.md; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    # Only well-formed names produce an id. A malformed one is reported by the filename lint in
    # pair_gate; letting it through here too would pair it against nothing and print a second,
    # nonsensical "orphan" error for the same cause.
    case "$b" in [0-9][0-9][0-9][0-9]-*.md) echo "${b%%-*}" ;; esac
  done
}

# Every directive prefixed with the id of the file it came from, so errors name the offender.
load_all() {
  local f id
  for f in "$CHECKS_DIR"/*.checks; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .checks)
    normalise <"$f" | sed "s|^|$id |"
  done
}

# ---------------------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------------------

fail=0
ran=0
# Set when run_checks bails before running anything on purpose. The vacuous-pass guard in main
# must not also fire in that case: one cause, one error.
aborted=0

pair_gate() {
  local line
  while read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "missing "*) echo "::error::patch ${line#missing } has no checks/${line#missing }.checks — declare how it is proven, or declare it ungateable with a reason"; fail=1 ;;
      "orphan "*)  echo "::error::checks/${line#orphan }.checks has no matching patch — a deleted patch left a declaration claiming coverage"; fail=1 ;;
    esac
  done <<<"$(pair_ids "$(patch_ids)" "$(check_ids | grep -v '^baseline$')")"

  # Same rule for the per-patch docs. A patch has to say how it is proven (checks) AND what it is
  # (doc); the doc is the canonical description, so a missing one is not cosmetic.
  while read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "missing "*) echo "::error::patch ${line#missing } has no docs/patches/${line#missing }-*.md — every patch needs a doc, and it is the canonical description"; fail=1 ;;
      "orphan "*)  echo "::error::docs/patches/${line#orphan }-*.md has no matching patch — a deleted patch left its doc behind"; fail=1 ;;
    esac
  done <<<"$(pair_ids "$(patch_ids)" "$(doc_ids)")"

  # A doc whose name does not start NNNN- would land in doc_ids as junk and pair against nothing.
  local f b
  for f in "$DOCS_DIR"/*.md; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      [0-9][0-9][0-9][0-9]-*.md) ;;
      *) echo "::error::docs/patches/$b: filename must be NNNN-slug.md"; fail=1 ;;
    esac
  done
}

lint() {
  local ids id kind platform rest n line
  ids=$(check_ids)
  while read -r id; do
    [ -n "$id" ] || continue
    valid_id "$id" || { echo "::error::checks/$id.checks: filename is neither NNNN nor baseline"; fail=1; }
    [ -n "$(normalise <"$CHECKS_DIR/$id.checks")" ] || {
      echo "::error::checks/$id.checks declares nothing — an empty declaration is not a declaration"; fail=1
    }
  done <<<"$ids"

  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    valid_kind "$kind"         || { echo "::error::checks/$id.checks: unknown kind '$kind'"; fail=1; continue; }
    valid_platform "$platform" || { echo "::error::checks/$id.checks: unknown platform '$platform' — a typo here means the check runs nowhere and nothing says so"; fail=1; continue; }
    case "$kind" in
      encoder-option)
        for n in $rest; do
          safe_name "$n" || { echo "::error::checks/$id.checks: '$n' is not a bare name"; fail=1; }
        done
        [ "$(printf '%s\n' "$rest" | wc -w)" -eq 2 ] || { echo "::error::checks/$id.checks: encoder-option takes <encoder> <option>"; fail=1; }
        ;;
      filter)
        safe_name "$rest" || { echo "::error::checks/$id.checks: '$rest' is not a bare filter name"; fail=1; }
        ;;
      ungateable)
        [ -n "$rest" ] || { echo "::error::checks/$id.checks: ungateable needs a reason"; fail=1; }
        ;;
    esac
  done <<<"$(load_all)"

  # Copying 0001 to 0002 and forgetting to change the platform is how the broken win64 asset
  # shipped. Identical (kind, platform, args) across two files is that mistake.
  local dupes
  dupes=$(load_all | cut -d' ' -f2- | sort | uniq -d)
  if [ -n "$dupes" ]; then
    while read -r line; do
      [ -n "$line" ] || continue
      echo "::error::duplicate declaration '$line' in: $(load_all | grep -F " $line" | cut -d' ' -f1 | sort -u | paste -sd' ' -)"
      fail=1
    done <<<"$dupes"
  fi
}

# ---------------------------------------------------------------------------------------
# Binary checks
# ---------------------------------------------------------------------------------------

run_checks() {
  local FF="$1" PLATFORM="$2" TARGET="${3:-}" applicable enc out id kind platform rest opt

  applicable=$(load_all)

  # A fine-grained declaration with no target named is unprovable here, and silently skipping it
  # would let a patch claim coverage nothing ever checks. Fail loudly and say how to fix it.
  #
  # Reported once per checks file, not once per directive: 0008 alone declares two, and repeating
  # the same two-line remedy for each is noise that buries the ids that actually need fixing.
  if [ -z "$TARGET" ]; then
    local offenders
    offenders=$(awk '$2!="ungateable" {print $1, $3}' <<<"$applicable" \
                | while read -r id platform; do
                    [ -n "$id" ] || continue
                    fine_platform "$platform" && echo "$id ($platform)"
                  done | sort -u | tr '\n' ' ')
    if [ -n "$offenders" ]; then
      echo "::error::these declare a target-specific platform: ${offenders% }"
      echo "::error::pass the target as the 2nd argument:"
      echo "::error::  verify-binary.sh <binary> <linux64|linuxarm64|win64|winarm64>"
      fail=1
      aborted=1
      return 0
    fi
  fi

  # ungateable and out-of-platform first, so the log reads as a complete account of every
  # declaration rather than only the ones that happened to run here.
  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    if [ "$kind" = ungateable ]; then
      echo "  n/a   $id: ungateable — $rest"
    elif ! valid_platform "$platform"; then
      : # lint already errored on this; a skip line here would falsely claim a sibling job covers it
    elif ! applies "$platform" "$PLATFORM" "$TARGET"; then
      echo "  skip  $id: $kind $rest (declared $platform, this binary is ${TARGET:-$PLATFORM})"
    fi
  done <<<"$applicable"

  # One `-h encoder=X` per encoder, not per option. Grouping is a sort -u over the encoder column
  # plus an inner filter: bash 3.2 has no associative arrays and none is needed.
  while read -r enc; do
    [ -n "$enc" ] || continue
    out=$("$FF" -hide_banner -h "encoder=$enc" 2>&1)
    if ! encoder_present "$out"; then
      # Counts toward `ran`: an assertion executed and came back false. Not counting it would trip
      # the vacuous-pass guard below on a build that lost every declared encoder, printing two
      # errors for one cause.
      ran=$((ran + 1))
      echo "::error::$enc: $FF cannot describe this encoder at all"
      printf '%s\n' "$out" | head -3
      fail=1
      continue
    fi
    while read -r id opt; do
      [ -n "$opt" ] || continue
      ran=$((ran + 1))
      if has_option "$out" "$opt"; then
        echo "  ok    $enc: $opt"
      else
        echo "::error::$enc is missing: $opt   (declared by $id)"
        fail=1
      fi
    done <<<"$(awk -v e="$enc" -v p="$PLATFORM" -v t="$TARGET" '$2=="encoder-option" && $4==e && ($3=="all" || $3==p || (t!="" && $3==t)) {print $1, $5}' <<<"$applicable")"
  done <<<"$(awk -v p="$PLATFORM" -v t="$TARGET" '$2=="encoder-option" && ($3=="all" || $3==p || (t!="" && $3==t)) {print $4}' <<<"$applicable" | sort -u)"

  local filters_out
  filters_out=""
  if [ -n "$(awk -v p="$PLATFORM" -v t="$TARGET" '$2=="filter" && ($3=="all" || $3==p || (t!="" && $3==t))' <<<"$applicable")" ]; then
    filters_out=$("$FF" -hide_banner -filters 2>/dev/null)
  fi
  while read -r id rest; do
    [ -n "$rest" ] || continue
    ran=$((ran + 1))
    if has_filter "$rest" "$filters_out"; then
      echo "  ok    filter: $rest"
    else
      echo "::error::missing filter: $rest   (declared by $id)"
      fail=1
    fi
  done <<<"$(awk -v p="$PLATFORM" -v t="$TARGET" '$2=="filter" && ($3=="all" || $3==p || (t!="" && $3==t)) {print $1, $4}' <<<"$applicable")"
}

# ---------------------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------------------

# `want` may be coarse (linux) or fine (linux64). Given a fine one, coarse declarations still
# apply, so resolve its platform and pass both -- otherwise `--list linux64` would wrongly show
# every `linux` declaration as skipped.
list_for() {
  local want="$1" coarse id kind platform rest verdict run=0 skipped=0 na=0
  if fine_platform "$want"; then coarse=$(platform_of_target "$want"); else coarse="$want"; want=""; fi
  echo "checks for ${want:-$coarse}:"
  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    if [ "$kind" = ungateable ]; then verdict="n/a"; na=$((na + 1))
    elif applies "$platform" "$coarse" "$want"; then verdict="run"; run=$((run + 1))
    else verdict="skip"; skipped=$((skipped + 1))
    fi
    printf '  %-8s %-14s %-8s %-4s %s\n' "$id" "$kind" "$platform" "$verdict" "$rest"
  done <<<"$(load_all)"
  echo "  ${want:-$coarse}: $run to run, $skipped skipped, $na ungateable"
}

# ---------------------------------------------------------------------------------------
# --score
# ---------------------------------------------------------------------------------------

SCORE_SRC="testsrc2=s=1280x720:r=30:d=2"
SCORE_DIS="scale=426x240,scale=1280x720"          # a real distortion, ~75 VMAF -- not near the
                                                  # 100 ceiling, where everything looks equal
SCORE_TOL_DEFAULT="0.01"

# One measurement. Prints the score on stdout, nothing else; diagnostics go to stderr.
run_one_score() {
  local ff="$1" pixfmt="$2" mode="$3" out hw graph
  if [ "$mode" = cuda ]; then
    hw="-init_hw_device cuda=cu -filter_hw_device cu"
    graph="[0:v]${SCORE_DIS},format=${pixfmt},hwupload_cuda[d];[1:v]format=${pixfmt},hwupload_cuda[r];[d][r]libvmaf_cuda"
  else
    hw=""
    graph="[0:v]${SCORE_DIS},format=${pixfmt}[d];[1:v]format=${pixfmt}[r];[d][r]libvmaf"
  fi
  # word-splitting $hw is intentional: it is a flag list, not a path.
  # shellcheck disable=SC2086
  out=$("$ff" -nostdin -hide_banner $hw -f lavfi -i "$SCORE_SRC" -f lavfi -i "$SCORE_SRC" \
        -lavfi "$graph" -f null - 2>&1)
  printf '%s' "$(parse_vmaf_score "$out")"
  [ -n "$(parse_vmaf_score "$out")" ] || printf '%s\n' "$out" | tail -4 >&2
}

score_mode() {
  local ff="$1" tol="${2:-$SCORE_TOL_DEFAULT}" pixfmt label cpu cuda failed=0

  [ -f "$ff" ] || { echo "::error::not found: $ff"; return 2; }
  case "$(platform_of "$ff")" in
    windows) echo "::error::--score needs libvmaf_cuda, which is linux64 only"; return 2 ;;
  esac

  # Refuse to run rather than report a vacuous pass. Each of these is a different missing thing and
  # says so, because "no score" and "score is wrong" must never look alike.
  local filters
  filters=$("$ff" -hide_banner -filters 2>/dev/null)
  has_filter libvmaf      "$filters" || { echo "::error::$ff has no libvmaf filter"; return 2; }
  has_filter libvmaf_cuda "$filters" || { echo "::error::$ff has no libvmaf_cuda filter — is this a linux64 build with 0008 applied?"; return 2; }
  has_filter hwupload_cuda "$filters" || { echo "::error::$ff has no hwupload_cuda filter"; return 2; }
  if ! "$ff" -nostdin -hide_banner -init_hw_device cuda=cu -f lavfi -i testsrc2=s=64x64:d=1 \
       -f null - >/dev/null 2>&1; then
    echo "::error::no usable CUDA device — --score must run on a GPU host, and a skip here would be"
    echo "::error::a vacuous pass. This is why 0008/0009 are declared ungateable."
    return 2
  fi

  echo "  scoring $ff (tolerance ${tol}, content generated not shipped)"
  for pixfmt in yuv420p10le yuv420p; do
    case "$pixfmt" in
      yuv420p10le) label="10-bit  (0009 + the libvmaf motion fix)" ;;
      *)           label="8-bit   (0008's original path)" ;;
    esac
    cpu=$(run_one_score  "$ff" "$pixfmt" cpu)
    cuda=$(run_one_score "$ff" "$pixfmt" cuda)
    if [ -z "$cpu" ] || [ -z "$cuda" ]; then
      echo "::error::$label: no VMAF score produced (cpu='$cpu' cuda='$cuda')"
      failed=1
      continue
    fi
    if within_tolerance "$cpu" "$cuda" "$tol"; then
      printf '  ok    %s  cpu=%s cuda=%s\n' "$label" "$cpu" "$cuda"
    else
      printf '::error::%s: cuda=%s but cpu=%s — beyond %s\n' "$label" "$cuda" "$cpu" "$tol"
      echo "::error::  a wrong VMAF that looks plausible is worse than no VMAF. Do not ship this build."
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] || return 1
  echo "  both bit depths agree with the CPU filter"
  return 0
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
  echo "verify-binary --self-test"

  local NVENC_HELP='Encoder hevc_nvenc [NVIDIA NVENC hevc encoder]:
    General capabilities: dr1 delay hardware
  -tf_level          <int>        E..V....... Specifies the strength of the temporal filtering
  -tune              <int>        E..V....... Set the encoding tuning info (default none)
     uhq             4            E..V....... Ultra high quality
     lossless        3            E..V....... Lossless mode
  -lookahead_level   <int>        E..V....... Specifies the lookahead level
  -split_encode_mode <int>        E..V....... Specifies the split encoding mode'

  local MISSING_ENC="Codec 'hevc_vaapi' is not recognized by FFmpeg.

Exiting with exit code 0"

  local FILTERS=' ... alphaextract     V->N       Extract an alpha channel.
 .S. scale            V->V       Scale the input video size.
 ..C tonemap_cuda     V->V       GPU accelerated HDR to SDR tonemapping.
 ... showinfo         V->V       Show textual info, unlike tonemap_cuda which does not.'

  local FILTERS_DECOY=' ... showinfo         V->V       Show textual info, unlike tonemap_cuda which does not.'

  # -- parser
  ok "blank lines and comments dropped" \
     "$(printf '# a comment\n\nfilter all tonemap_cuda\n' | normalise)" 'filter all tonemap_cuda'
  ok "leading and trailing whitespace trimmed" \
     "$(printf '   filter all tonemap_cuda   \n' | normalise)" 'filter all tonemap_cuda'
  ok "a # inside an ungateable reason survives" \
     "$(printf 'ungateable all needs a hwmap; see #123\n' | normalise)" 'ungateable all needs a hwmap; see #123'
  # The assertion that catches a windows-only false failure without spending a 2.5h build.
  ok "CRLF normalises identically to LF" \
     "$(printf 'encoder-option linux hevc_vaapi dolbyvision\r\n' | normalise)" \
     "$(printf 'encoder-option linux hevc_vaapi dolbyvision\n' | normalise)"

  # -- platform
  ok "linux binary path"        "$(platform_of /tmp/x/ffmpeg)"     linux
  ok "windows binary path"      "$(platform_of ./dist/ffmpeg.exe)" windows
  ok "uppercase .EXE"           "$(platform_of ./FFMPEG.EXE)"      windows
  ok_true  "all applies to windows"    applies all windows
  ok_true  "all applies to linux"      applies all linux
  ok_true  "linux applies to linux"    applies linux linux
  ok_false "linux does not apply to windows" applies linux windows
  ok_false "windows does not apply to linux" applies windows linux

  # Fine-grained targets. The negative controls are the point: linux64 must NOT match the arm64
  # job, and must NOT match when no target was passed -- those are the two ways a declaration
  # could silently cover nothing.
  ok_true  "all applies with a target"          applies all       linux linux64
  ok_true  "linux applies to linux64"           applies linux     linux linux64
  ok_true  "linux applies to linuxarm64"        applies linux     linux linuxarm64
  ok_true  "linux64 applies to linux64"         applies linux64   linux linux64
  ok_false "linux64 does not apply to arm64"    applies linux64   linux linuxarm64
  ok_false "linux64 without a target"           applies linux64   linux
  ok_false "linux64 does not apply to win64"    applies linux64   windows win64
  ok_true  "winarm64 applies to winarm64"       applies winarm64  windows winarm64
  ok_false "win64 does not apply to winarm64"   applies win64     windows winarm64

  ok_true  "linux64 is a fine platform"      fine_platform linux64
  ok_true  "winarm64 is a fine platform"     fine_platform winarm64
  ok_false "linux is not a fine platform"    fine_platform linux
  ok_false "all is not a fine platform"      fine_platform all
  ok_true  "linux64 is a valid platform"     valid_platform linux64
  ok_false "linux86 is not a valid platform" valid_platform linux86
  ok "linux64 coarse platform"   "$(platform_of_target linux64)"    linux
  ok "linuxarm64 coarse platform" "$(platform_of_target linuxarm64)" linux
  ok "win64 coarse platform"     "$(platform_of_target win64)"      windows
  ok "winarm64 coarse platform"  "$(platform_of_target winarm64)"   windows
  ok "unknown target has no platform" "$(platform_of_target mac64)" ""

  # --score's pure halves. The negative controls are the point: a missing score must never be
  # readable as 0.0 and then compared as if it were a real measurement.
  ok "parse last vmaf score"  "$(parse_vmaf_score 'x
[Parsed_libvmaf_0 @ 0x1] VMAF score: 75.257781')" 75.257781
  ok "parse picks the LAST"   "$(parse_vmaf_score 'VMAF score: 1.5
VMAF score: 99.556442')" 99.556442
  ok "no score parses empty"  "$(parse_vmaf_score 'Conversion failed!')" ""
  ok_true  "identical scores are within tolerance"  within_tolerance 75.257781 75.257781 0.01
  ok_true  "the measured fixed delta passes"        within_tolerance 75.257781 75.257735 0.01
  ok_false "the measured #1566 delta fails"         within_tolerance 75.257781 99.556442 0.01
  ok_true  "tolerance is symmetric"                 within_tolerance 99.556442 99.556000 0.01
  ok_false "and symmetric when it fails"            within_tolerance 99.556442 75.257781 0.01
  ok_false "empty score never passes"               within_tolerance "" 75.257781 0.01
  ok_false "non-numeric never passes"               within_tolerance "n/a" 75.257781 0.01
  # A typo'd platform must be rejected, not become permanent invisibility.
  ok_true  "known platform accepted"   valid_platform linux
  ok_false "typo'd platform rejected"  valid_platform linix
  ok_true  "known kind accepted"       valid_kind encoder-option
  ok_false "typo'd kind rejected"      valid_kind encoder-optoin
  ok_true  "baseline is a valid id"    valid_id baseline
  ok_true  "NNNN is a valid id"        valid_id 0004
  ok_false "0004x is not a valid id"   valid_id 0004x

  # -- encoder presence. `-h encoder=X` exits 0 for a missing encoder, so this cannot be done
  #    with $?; these two assertions are what pin that.
  ok_true  "a real help block means present" encoder_present "$NVENC_HELP"
  ok_false "not-recognized means absent"     encoder_present "$MISSING_ENC"

  # -- option matching, with the negative controls that give the positives meaning
  ok_true  "dashed option matches"           has_option "$NVENC_HELP" tf_level
  ok_true  "undashed unit constant matches"  has_option "$NVENC_HELP" uhq
  ok_false "description text does not match" has_option "$NVENC_HELP" none
  ok_false "substring does not match"        has_option "$NVENC_HELP" level
  ok_false "absent option does not match"    has_option "$NVENC_HELP" dolbyvision

  # -- filters. Anchoring is a behaviour change from the previous unanchored grep, so it needs
  #    both controls before it replaces a check that passes today.
  ok_true  "filter present matches"          has_filter tonemap_cuda "$FILTERS"
  ok_false "a name only in a description does not match" has_filter tonemap_cuda "$FILTERS_DECOY"
  ok_false "absent filter does not match"    has_filter tonemap_vulkan "$FILTERS"

  # -- names that would be interpolated into grep -E
  ok_true  "bare name accepted"   safe_name dv_l5_canvas
  ok_false "regex metachar rejected" safe_name 'dv.*'
  ok_false "empty name rejected"  safe_name ''

  # -- the pairing gate, pure
  ok "a patch with no checks file is missing" \
     "$(pair_ids '0001
0002
0005' '0001
0002')" 'missing 0005'
  ok "a checks file with no patch is an orphan" \
     "$(pair_ids '0001' '0001
0009')" 'orphan 0009'
  ok "both directions report together" \
     "$(pair_ids '0001
0005' '0001
0009')" 'missing 0005
orphan 0009'
  ok "a consistent set reports nothing" "$(pair_ids '0001' '0001')" ''
  # the doc pairing reuses pair_ids, so it inherits these -- but assert the direction names too
  ok "a patch with no doc is missing" \
     "$(pair_ids '0001
0004' '0001')" 'missing 0004'
  ok "empty on both sides reports nothing" "$(pair_ids '' '')" ''

  # -- fail accumulation must survive the loops. `awk | while read` puts the body in a subshell
  #    in bash 3.2 and would discard this, so every failure would print and the script exit 0.
  local acc
  acc=$( fail=0
         while read -r x; do [ -n "$x" ] && fail=1; done <<<"$(printf 'a\n')"
         echo "$fail" )
  ok "a here-string loop propagates fail=1" "$acc" 1

  # -- now the real repo. This is what makes --self-test the gate rather than a test of the gate.
  echo "  -- against $CHECKS_DIR"
  ok_true "checks dir exists" [ -d "$CHECKS_DIR" ]
  ok "every patch is declared, and no declaration is orphaned" \
     "$(pair_ids "$(patch_ids)" "$(check_ids | grep -v '^baseline$')")" ''
  ok "every patch has a doc, and no doc is orphaned" \
     "$(pair_ids "$(patch_ids)" "$(doc_ids)")" ''
  local baddoc=0 d
  for d in "$DOCS_DIR"/*.md; do
    [ -e "$d" ] || continue
    case "$(basename "$d")" in [0-9][0-9][0-9][0-9]-*.md) ;; *) baddoc=$((baddoc+1)) ;; esac
  done
  ok "no doc filename outside NNNN-slug.md" "$baddoc" 0

  local bad_id=0 bad_kind=0 bad_plat=0 empty_file=0 no_reason=0 id kind platform rest
  while read -r id; do
    [ -n "$id" ] || continue
    valid_id "$id" || bad_id=$((bad_id + 1))
    [ -n "$(normalise <"$CHECKS_DIR/$id.checks")" ] || empty_file=$((empty_file + 1))
  done <<<"$(check_ids)"
  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    valid_kind "$kind" || bad_kind=$((bad_kind + 1))
    valid_platform "$platform" || bad_plat=$((bad_plat + 1))
    [ "$kind" != ungateable ] || [ -n "$rest" ] || no_reason=$((no_reason + 1))
  done <<<"$(load_all)"
  ok "no bad filenames"        "$bad_id"     0
  ok "no unknown kinds"        "$bad_kind"   0
  ok "no unknown platforms"    "$bad_plat"   0
  ok "no empty checks files"   "$empty_file" 0
  ok "every ungateable has a reason" "$no_reason" 0
  ok "no duplicate declarations" "$(load_all | cut -d' ' -f2- | sort | uniq -d)" ''

  # The static form of the ran==0 guard: a manifest set whose declarations all skip on one
  # platform is caught in a second rather than in a build.
  # Per TARGET, not per platform. Every build job runs at target granularity, so a target with no
  # runnable declaration is a vacuous pass on that job -- and once the fine tier exists, `linux`
  # having checks says nothing about whether `linuxarm64` does.
  local tgt runnable summary=""
  for tgt in linux64 linuxarm64 win64 winarm64; do
    runnable=$(load_all | awk -v p="$(platform_of_target "$tgt")" -v t="$tgt" \
                 '$2!="ungateable" && ($3=="all" || $3==p || $3==t)' | wc -l | tr -d ' ')
    ok_true "$tgt has at least one runnable check" [ "$runnable" -gt 0 ]
    summary="$summary $tgt $runnable,"
  done
  summary="${summary%,}"

  self_test_e2e

  [ "$FAILED" -eq 0 ] || { echo "::error::self-test: $FAILED of $TESTS assertions failed"; exit 1; }
  echo "  self-test: $TESTS assertions passed  (runnable:${summary})"
}

# ---------------------------------------------------------------------------------------
# End-to-end, against stub binaries
#
# The assertions above are all pure text. They cannot tell you whether the SCRIPT passes a good
# binary -- and a gate that can only fail is useless. A full CI cycle costs 2.5 hours, so the
# green path is proven here instead, with a stub `ffmpeg` that prints canned help. No compile,
# no GPU, no network, ~1s.
#
# The `no-vaapi` flavour is the one that earns its keep: it must FAIL on linux (VAAPI vanished
# from a linux build -- exactly what this gate exists to catch) and PASS on windows (hevc_vaapi
# does not exist there, and an unconditional check would block every publish). Getting that pair
# wrong is the 2.5-hour mistake.
# ---------------------------------------------------------------------------------------

# $1 = directory, $2 = binary name, $3 = flavour (good | no-vaapi | no-filter | no-uhq)
make_stub() {
  local dir="$1" name="$2" flavour="$3"
  mkdir -p "$dir"
  cat >"$dir/$name" <<STUB
#!/usr/bin/env bash
flavour="$flavour"
STUB
  cat >>"$dir/$name" <<'STUB'
want=""
filters=0
for a in "$@"; do
  case "$a" in
    encoder=*) want="${a#encoder=}" ;;
    -filters)  filters=1 ;;
  esac
done

if [ "$filters" = 1 ]; then
  echo " ... alphaextract     V->N       Extract an alpha channel."
  echo " .S. scale            V->V       Scale the input video size."
  [ "$flavour" = no-filter ] || echo " ..C tonemap_cuda     V->V       GPU accelerated HDR to SDR tonemapping."
  # libvmaf is present on every flavour except no-vmaf; libvmaf_cuda additionally goes missing on
  # no-vmafcuda, which is the negative control for 0008's claim that BOTH lines are load-bearing.
  if [ "$flavour" != no-vmaf ]; then
    echo " .. libvmaf           VV->V      Calculate the VMAF between two video streams."
    [ "$flavour" = no-vmafcuda ] || \
      echo " .. libvmaf_cuda      VV->V      Calculate the VMAF between two video streams."
  fi
  exit 0
fi

case "$want" in
  hevc_nvenc)
    echo "Encoder hevc_nvenc [NVIDIA NVENC hevc encoder]:"
    echo "    General capabilities: dr1 delay hardware"
    echo "  -tf_level          <int>        E..V....... Specifies the strength of the temporal filtering"
    echo "  -lookahead_level   <int>        E..V....... Specifies the lookahead level"
    echo "  -split_encode_mode <int>        E..V....... Specifies the split encoding mode"
    echo "  -tune              <int>        E..V....... Set the encoding tuning info (default none)"
    [ "$flavour" = no-uhq ] || echo "     uhq             4            E..V....... Ultra high quality"
    # Declared by 0007, on every platform -- NVENC is built for all four targets.
    echo "  -dolbyvision       <boolean>    E..V....... Enable Dolby Vision RPU coding (default auto)"
    echo "  -dv_l5             <int>        E..V....... Dolby Vision L5 (active area) handling (default keep)"
    echo "  -dv_l5_canvas      <image_size> E..V....... Frame size the source Dolby Vision L5 offsets refer to"
    exit 0 ;;
  hevc_vaapi)
    # ffmpeg exits 0 for an unknown encoder; the stub reproduces that faithfully, because the
    # script's handling of it is the thing under test.
    if [ "$flavour" = no-vaapi ]; then
      echo "Codec 'hevc_vaapi' is not recognized by FFmpeg."
      echo ""
      echo "Exiting with exit code 0"
      exit 0
    fi
    echo "Encoder hevc_vaapi [hevc (VAAPI)]:"
    echo "    General capabilities: delay hardware"
    echo "  -dolbyvision       <boolean>    E..V....... Enable Dolby Vision RPU passthrough (default auto)"
    echo "  -dv_l5             <int>        E..V....... How to handle the DV level 5 metadata (default keep)"
    echo "  -dv_l5_canvas      <image_size> E..V....... Canvas size for dv_l5=scale"
    exit 0 ;;
  *)
    echo "Codec '$want' is not recognized by FFmpeg."
    echo ""
    echo "Exiting with exit code 0"
    exit 0 ;;
esac
STUB
  chmod +x "$dir/$name"
}

# Runs the real script, end to end, against a stub. Echoes "<exit> <last line>".
run_stub() {
  local out rc
  out=$("$SELF_DIR/verify-binary.sh" "$@" 2>&1); rc=$?
  printf '%s | %s' "$rc" "$(printf '%s\n' "$out" | tail -1)"
}

self_test_e2e() {
  local tmp
  tmp=$(mktemp -d) || { echo "::error::mktemp failed"; return 1; }

  echo "  -- end to end, against stub binaries"

  # THE GREEN PATH. Nothing else in this file proves the gate can pass.
  make_stub "$tmp/good" ffmpeg     good
  make_stub "$tmp/good" ffmpeg.exe good
  ok "a complete linux64 binary passes" "$(run_stub "$tmp/good/ffmpeg" linux64)"     "0 |   all 13 checks passed for $tmp/good/ffmpeg (linux64)"
  ok "a complete win64 binary passes"   "$(run_stub "$tmp/good/ffmpeg.exe" win64)"   "0 |   all 8 checks passed for $tmp/good/ffmpeg.exe (win64)"

  # VAAPI gone from a LINUX build must be a hard failure, never a skip.
  make_stub "$tmp/novaapi" ffmpeg     no-vaapi
  make_stub "$tmp/novaapi" ffmpeg.exe no-vaapi
  ok "linux build without hevc_vaapi fails" \
     "$(run_stub "$tmp/novaapi/ffmpeg" linux64)" \
     "1 | ::error::$tmp/novaapi/ffmpeg does not carry the features this fork exists for"
  ok_true "and it says the encoder could not be described" \
     grep -q "hevc_vaapi: .* cannot describe this encoder at all" <("$SELF_DIR/verify-binary.sh" "$tmp/novaapi/ffmpeg" linux64 2>&1)

  # ...but the SAME binary on the windows path must pass, because hevc_vaapi does not exist there.
  # If this ever fails, every publish is blocked and it costs 2.5h to find out.
  ok "windows build without hevc_vaapi still passes" \
     "$(run_stub "$tmp/novaapi/ffmpeg.exe" win64)" \
     "0 |   all 8 checks passed for $tmp/novaapi/ffmpeg.exe (win64)"

  # Single-feature regressions, one per declaration source, so a passing run means something.
  make_stub "$tmp/nouhq" ffmpeg no-uhq
  ok "a linux binary missing one nvenc option fails" \
     "$(run_stub "$tmp/nouhq/ffmpeg" linux64)" \
     "1 | ::error::$tmp/nouhq/ffmpeg does not carry the features this fork exists for"
  ok_true "and it names the option and the patch that declared it" \
     grep -q "hevc_nvenc is missing: uhq   (declared by 0001)" <("$SELF_DIR/verify-binary.sh" "$tmp/nouhq/ffmpeg" linux64 2>&1)

  make_stub "$tmp/nofilter" ffmpeg no-filter
  ok "a binary missing tonemap_cuda fails" \
     "$(run_stub "$tmp/nofilter/ffmpeg" linux64)" \
     "1 | ::error::$tmp/nofilter/ffmpeg does not carry the features this fork exists for"

  # 0008 is the first fine-grained declaration, so these four are what prove the arch tier works.
  # The arm64 case is the one that matters most: 55-libvmaf.sh does not build for linuxarm64, so a
  # binary with no vmaf at all must PASS there -- and the same binary must FAIL as linux64.
  make_stub "$tmp/novmaf" ffmpeg no-vmaf
  ok "arm64 without libvmaf passes"  "$(run_stub "$tmp/novmaf/ffmpeg" linuxarm64)" \
     "0 |   all 11 checks passed for $tmp/novmaf/ffmpeg (linuxarm64)"
  ok "linux64 without libvmaf fails" "$(run_stub "$tmp/novmaf/ffmpeg" linux64)" \
     "1 | ::error::$tmp/novmaf/ffmpeg does not carry the features this fork exists for"

  # Half a libvmaf is the silent-degradation case: --enable-libvmaf always yields the CPU filter,
  # so a `libvmaf`-only declaration would pass a build whose CUDA half quietly no-op'd.
  make_stub "$tmp/novmafcuda" ffmpeg no-vmafcuda
  ok "linux64 with libvmaf but not libvmaf_cuda fails" \
     "$(run_stub "$tmp/novmafcuda/ffmpeg" linux64)" \
     "1 | ::error::$tmp/novmafcuda/ffmpeg does not carry the features this fork exists for"
  ok_true "and it names the missing filter and its patch" \
     grep -q "missing filter: libvmaf_cuda   (declared by 0008)" \
       <("$SELF_DIR/verify-binary.sh" "$tmp/novmafcuda/ffmpeg" linux64 2>&1)

  # A fine declaration with no target must ERROR, not skip. Skipping is the failure this whole
  # tier exists to prevent.
  ok_true "a fine declaration with no target is an error" \
     grep -q "these declare a target-specific platform: 0008 (linux64)" \
       <("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" 2>&1)
  ok "and it exits non-zero" \
     "$("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" >/dev/null 2>&1; echo $?)" 1
  # 0008 declares TWO fine directives; the remedy must be printed once, not once each.
  ok "the remedy is printed once, not per directive" \
     "$("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" 2>&1 | grep -c 'pass the target as the 2nd argument')" 1
  # And it must not ALSO claim a vacuous pass -- that is two errors for one cause.
  ok "and it does not also report a vacuous pass" \
     "$("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" 2>&1 | grep -c 'vacuous pass')" 0

  # A target that contradicts the binary must be refused rather than silently believed.
  ok "win64 against a linux binary is refused" \
     "$("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" win64 >/dev/null 2>&1; echo $?)" 2
  ok "an unknown target is refused" \
     "$("$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" mac64 >/dev/null 2>&1; echo $?)" 2

  # A CRLF manifest must behave exactly like the LF one END TO END, not just through normalise().
  # This is the windows-only failure that would otherwise surface 2.5h into a build.
  local crlf="$tmp/crlfchecks"
  mkdir -p "$crlf"
  local f
  for f in "$CHECKS_DIR"/*.checks; do
    sed 's/$/\r/' "$f" >"$crlf/$(basename "$f")"
  done
  ok "a CRLF manifest passes a good binary end to end" \
     "$(CHECKS_DIR="$crlf" "$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" linux64 >/dev/null 2>&1; echo $?)" 0

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------

[ -d "$CHECKS_DIR" ] || { echo "::error::no checks directory at $CHECKS_DIR"; exit 1; }
[ -n "$(check_ids)" ] || { echo "::error::$CHECKS_DIR declares nothing — refusing to pass vacuously"; exit 1; }
[ -n "$(patch_ids)" ] || { echo "::error::no patches found in $PATCH_DIR"; exit 1; }
[ -d "$DOCS_DIR" ] || { echo "::error::no patch-docs directory at $DOCS_DIR"; exit 1; }

case "${1:-}" in
  --self-test) self_test; exit 0 ;;
  --list)
    case "${2:-}" in
      linux|windows|linux64|linuxarm64|win64|winarm64) list_for "$2" ;;
      '')            list_for linux64; echo; list_for linuxarm64; echo
                     list_for win64;   echo; list_for winarm64 ;;
      *)             echo "usage: $0 --list [linux|windows|linux64|linuxarm64|win64|winarm64]" >&2; exit 2 ;;
    esac
    exit 0 ;;
  --score)
    [ -n "${2:-}" ] || { echo "usage: $0 --score <ffmpeg binary> [tolerance]" >&2; exit 2; }
    score_mode "$2" "${3:-}"
    exit $? ;;
  -h|--help|'')
    echo "usage: $0 <ffmpeg binary> [linux64|linuxarm64|win64|winarm64]" >&2
    echo "       $0 --score <ffmpeg binary> [tolerance]   # needs a GPU; not part of the CI gate" >&2
    echo "       $0 --self-test | --list [platform|target]" >&2
    exit 2 ;;
esac

FF="$1"
[ -f "$FF" ] || { echo "::error::not found: $FF"; exit 1; }
PLATFORM=$(platform_of "$FF")

# The target is optional so a hand-run against a downloaded asset still works, but if it is given
# it must agree with the binary. `win64` alongside a path called `ffmpeg` would otherwise run the
# windows declarations against a linux build and report a confident pass on the wrong thing.
TARGET="${2:-}"
if [ -n "$TARGET" ]; then
  if ! fine_platform "$TARGET"; then
    echo "::error::unknown target '$TARGET' (expected linux64, linuxarm64, win64 or winarm64)"
    exit 2
  fi
  if [ "$(platform_of_target "$TARGET")" != "$PLATFORM" ]; then
    echo "::error::target '$TARGET' is a $(platform_of_target "$TARGET") target, but $FF is $PLATFORM"
    exit 2
  fi
fi

pair_gate
lint
run_checks "$FF" "$PLATFORM" "$TARGET"

# `aborted` means run_checks already said why it stopped. Reporting a vacuous pass on top of that
# is two errors for one cause, and sends the reader after the wrong problem.
if [ "$ran" -eq 0 ] && [ "$aborted" -eq 0 ]; then
  echo "::error::no check actually ran for $FF (platform: ${TARGET:-$PLATFORM}) — every declaration"
  echo "::error::was skipped or ungateable. That is a vacuous pass, not a pass."
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::$FF does not carry the features this fork exists for"
  exit 1
fi
echo "  all $ran checks passed for $FF (${TARGET:-$PLATFORM})"
