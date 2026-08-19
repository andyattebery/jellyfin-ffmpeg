#!/usr/bin/env bash
#
# verify-binary.sh <path to ffmpeg or ffmpeg.exe>
#                  --self-test          pure-logic assertions plus the repo's own manifests. <1s.
#                  --list [platform]    what would run, and where, without a binary.
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
# <platform> is `all`, `linux` or `windows`, inferred from whether the binary path ends in .exe --
# which is all the four workflow call sites pass. NOTE THE CEILING: both linux jobs pass a path
# named `ffmpeg`, so architecture is NOT recoverable from it. A patch that ever needs to
# discriminate linuxarm64 from linux64 needs a second argument from the workflow; do not try to
# guess arch here.
#
# To add a kind:
#   1. write check_<kind>() taking the directive's args, returning 0/1, printing nothing
#   2. add its arm to run_checks
#   3. add its token to VALID_KINDS   <-- without this a misspelled kind is a silent no-op
#   4. add a --self-test fixture WITH AT LEAST ONE NEGATIVE CONTROL: a positive-only assertion
#      proves nothing about a grep
#   5. document it above

set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="${PATCH_DIR:-$SELF_DIR/../../patches/jellyfin-ffmpeg}"
CHECKS_DIR="${CHECKS_DIR:-$PATCH_DIR/checks}"

VALID_KINDS=" encoder-option filter ungateable "
VALID_PLATFORMS=" all linux windows "

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

# A file id is four digits, or the one whitelisted name. Anything else is an error rather than a
# quiet exemption from pairing.
valid_id() { case "$1" in baseline) return 0 ;; [0-9][0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

# The binary's platform, from the filename the workflow already hands us.
platform_of() { case "$1" in *.exe|*.EXE) echo windows ;; *) echo linux ;; esac; }

applies() { [ "$1" = all ] || [ "$1" = "$2" ]; }

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

pair_gate() {
  local line
  while read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "missing "*) echo "::error::patch ${line#missing } has no checks/${line#missing }.checks — declare how it is proven, or declare it ungateable with a reason"; fail=1 ;;
      "orphan "*)  echo "::error::checks/${line#orphan }.checks has no matching patch — a deleted patch left a declaration claiming coverage"; fail=1 ;;
    esac
  done <<<"$(pair_ids "$(patch_ids)" "$(check_ids | grep -v '^baseline$')")"
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
  local FF="$1" PLATFORM="$2" applicable enc out id kind platform rest opt

  applicable=$(load_all)

  # ungateable and out-of-platform first, so the log reads as a complete account of every
  # declaration rather than only the ones that happened to run here.
  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    if [ "$kind" = ungateable ]; then
      echo "  n/a   $id: ungateable — $rest"
    elif ! valid_platform "$platform"; then
      : # lint already errored on this; a skip line here would falsely claim a sibling job covers it
    elif ! applies "$platform" "$PLATFORM"; then
      echo "  skip  $id: $kind $rest (declared $platform, this binary is $PLATFORM)"
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
    done <<<"$(awk -v e="$enc" -v p="$PLATFORM" '$2=="encoder-option" && $4==e && ($3=="all" || $3==p) {print $1, $5}' <<<"$applicable")"
  done <<<"$(awk -v p="$PLATFORM" '$2=="encoder-option" && ($3=="all" || $3==p) {print $4}' <<<"$applicable" | sort -u)"

  local filters_out
  filters_out=""
  if [ -n "$(awk -v p="$PLATFORM" '$2=="filter" && ($3=="all" || $3==p)' <<<"$applicable")" ]; then
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
  done <<<"$(awk -v p="$PLATFORM" '$2=="filter" && ($3=="all" || $3==p) {print $1, $4}' <<<"$applicable")"
}

# ---------------------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------------------

list_for() {
  local want="$1" id kind platform rest verdict run=0 skipped=0 na=0
  echo "checks for $want:"
  while read -r id kind platform rest; do
    [ -n "$id" ] || continue
    if [ "$kind" = ungateable ]; then verdict="n/a"; na=$((na + 1))
    elif applies "$platform" "$want"; then verdict="run"; run=$((run + 1))
    else verdict="skip"; skipped=$((skipped + 1))
    fi
    printf '  %-8s %-14s %-8s %-4s %s\n' "$id" "$kind" "$platform" "$verdict" "$rest"
  done <<<"$(load_all)"
  echo "  $want: $run to run, $skipped skipped, $na ungateable"
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
  local runnable_linux runnable_windows
  runnable_linux=$(load_all   | awk '$2!="ungateable" && ($3=="all" || $3=="linux")'   | wc -l | tr -d ' ')
  runnable_windows=$(load_all | awk '$2!="ungateable" && ($3=="all" || $3=="windows")' | wc -l | tr -d ' ')
  ok_true "linux has at least one runnable check"   [ "$runnable_linux"   -gt 0 ]
  ok_true "windows has at least one runnable check" [ "$runnable_windows" -gt 0 ]

  self_test_e2e

  [ "$FAILED" -eq 0 ] || { echo "::error::self-test: $FAILED of $TESTS assertions failed"; exit 1; }
  echo "  self-test: $TESTS assertions passed  (runnable: linux $runnable_linux, windows $runnable_windows)"
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
  out=$("$SELF_DIR/verify-binary.sh" "$1" 2>&1); rc=$?
  printf '%s | %s' "$rc" "$(printf '%s\n' "$out" | tail -1)"
}

self_test_e2e() {
  local tmp
  tmp=$(mktemp -d) || { echo "::error::mktemp failed"; return 1; }

  echo "  -- end to end, against stub binaries"

  # THE GREEN PATH. Nothing else in this file proves the gate can pass.
  make_stub "$tmp/good" ffmpeg     good
  make_stub "$tmp/good" ffmpeg.exe good
  ok "a complete linux binary passes"   "$(run_stub "$tmp/good/ffmpeg")"     "0 |   all 8 checks passed for $tmp/good/ffmpeg (linux)"
  ok "a complete windows binary passes" "$(run_stub "$tmp/good/ffmpeg.exe")" "0 |   all 5 checks passed for $tmp/good/ffmpeg.exe (windows)"

  # VAAPI gone from a LINUX build must be a hard failure, never a skip.
  make_stub "$tmp/novaapi" ffmpeg     no-vaapi
  make_stub "$tmp/novaapi" ffmpeg.exe no-vaapi
  ok "linux build without hevc_vaapi fails" \
     "$(run_stub "$tmp/novaapi/ffmpeg")" \
     "1 | ::error::$tmp/novaapi/ffmpeg does not carry the features this fork exists for"
  ok_true "and it says the encoder could not be described" \
     grep -q "hevc_vaapi: .* cannot describe this encoder at all" <("$SELF_DIR/verify-binary.sh" "$tmp/novaapi/ffmpeg" 2>&1)

  # ...but the SAME binary on the windows path must pass, because hevc_vaapi does not exist there.
  # If this ever fails, every publish is blocked and it costs 2.5h to find out.
  ok "windows build without hevc_vaapi still passes" \
     "$(run_stub "$tmp/novaapi/ffmpeg.exe")" \
     "0 |   all 5 checks passed for $tmp/novaapi/ffmpeg.exe (windows)"

  # Single-feature regressions, one per declaration source, so a passing run means something.
  make_stub "$tmp/nouhq" ffmpeg no-uhq
  ok "a linux binary missing one nvenc option fails" \
     "$(run_stub "$tmp/nouhq/ffmpeg")" \
     "1 | ::error::$tmp/nouhq/ffmpeg does not carry the features this fork exists for"
  ok_true "and it names the option and the patch that declared it" \
     grep -q "hevc_nvenc is missing: uhq   (declared by 0001)" <("$SELF_DIR/verify-binary.sh" "$tmp/nouhq/ffmpeg" 2>&1)

  make_stub "$tmp/nofilter" ffmpeg no-filter
  ok "a binary missing tonemap_cuda fails" \
     "$(run_stub "$tmp/nofilter/ffmpeg")" \
     "1 | ::error::$tmp/nofilter/ffmpeg does not carry the features this fork exists for"

  # A CRLF manifest must behave exactly like the LF one END TO END, not just through normalise().
  # This is the windows-only failure that would otherwise surface 2.5h into a build.
  local crlf="$tmp/crlfchecks"
  mkdir -p "$crlf"
  local f
  for f in "$CHECKS_DIR"/*.checks; do
    sed 's/$/\r/' "$f" >"$crlf/$(basename "$f")"
  done
  ok "a CRLF manifest passes a good binary end to end" \
     "$(CHECKS_DIR="$crlf" "$SELF_DIR/verify-binary.sh" "$tmp/good/ffmpeg" >/dev/null 2>&1; echo $?)" 0

  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------

[ -d "$CHECKS_DIR" ] || { echo "::error::no checks directory at $CHECKS_DIR"; exit 1; }
[ -n "$(check_ids)" ] || { echo "::error::$CHECKS_DIR declares nothing — refusing to pass vacuously"; exit 1; }
[ -n "$(patch_ids)" ] || { echo "::error::no patches found in $PATCH_DIR"; exit 1; }

case "${1:-}" in
  --self-test) self_test; exit 0 ;;
  --list)
    case "${2:-}" in
      linux|windows) list_for "$2" ;;
      '')            list_for linux; echo; list_for windows ;;
      *)             echo "usage: $0 --list [linux|windows]" >&2; exit 2 ;;
    esac
    exit 0 ;;
  -h|--help|'') echo "usage: $0 <ffmpeg binary> | --self-test | --list [linux|windows]" >&2; exit 2 ;;
esac

FF="$1"
[ -f "$FF" ] || { echo "::error::not found: $FF"; exit 1; }
PLATFORM=$(platform_of "$FF")

pair_gate
lint
run_checks "$FF" "$PLATFORM"

if [ "$ran" -eq 0 ]; then
  echo "::error::no check actually ran for $FF (platform: $PLATFORM) — every declaration was"
  echo "::error::skipped or ungateable. That is a vacuous pass, not a pass."
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::$FF does not carry the features this fork exists for"
  exit 1
fi
echo "  all $ran checks passed for $FF ($PLATFORM)"
