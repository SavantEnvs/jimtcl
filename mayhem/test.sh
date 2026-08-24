#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Jim Tcl's own functional test suite (built by mayhem/build.sh
# step 1, the plain in-tree `./configure && make` oracle build). This replays
# upstream's own regression suite: tests/*.test, each of which uses the
# `test <name> {...} <script> <expected-result>` procedure from
# tests/testutils.tcl to assert an EXACT computed value per case (not just
# "didn't crash") — a genuine behavioral oracle. tests/runall.tcl drives all
# 98 *.test files and prints one aggregate line:
#   Totals: Total  <N>   Passed  <P>  Skipped  <S>  Failed  <F>
# We parse that line for the CTRF counts. A neutered/no-op ./jimsh (the
# sabotage LD_PRELOAD check) never reaches that print (it _exit(0)s at
# process start, before a single test file is sourced), so the regex match
# fails and this script FAILS loudly rather than reporting 0 tests as a skip.
#
# Do NOT build here -- mayhem/build.sh already compiled ./jimsh with the
# project's normal (unsanitized) flags and every default extension enabled.
# This script only RUNS the pre-built binary and reports counts.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$SRC/jimsh" ]; then
  echo "test.sh: $SRC/jimsh missing -- build.sh should have produced it" >&2
  emit_ctrf "jimtcl-selftest" 0 1
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) Upstream's own regression suite, run exactly as tests/Makefile.in's own
#    `test` rule does (cd into tests/, so relative-path temp files land there;
#    tests/Makefile's own `clean` target already expects gorp.file, sleepx,
#    exec.tmp1, etc at this cwd) -- but invoked directly (no `make`) so
#    test.sh can never trigger a rebuild.
# ---------------------------------------------------------------------------
raw="$(cd "$SRC/tests" && LD_LIBRARY_PATH="$SRC:${LD_LIBRARY_PATH:-}" "$SRC/jimsh" "$SRC/tests/runall.tcl" 2>&1)"
suite_rc=$?
echo "$raw" | tail -40

# Parse the aggregate line. Unconditional: a missing/unparseable line (e.g.
# the sabotage shim killed jimsh before runall.tcl ever printed it) is a
# FAILURE, not a 0-tests skip.
totals_line="$(printf '%s\n' "$raw" | grep -E 'Totals: Total' | tail -1)"
if [ -z "$totals_line" ]; then
  echo "test.sh: FAIL -- no 'Totals: Total ...' summary line found (suite_rc=$suite_rc); jimsh likely did not run the suite" >&2
  emit_ctrf "jimtcl-selftest" 0 1
  exit 1
fi

# shellcheck disable=SC2001
read -r suite_total suite_passed suite_skipped suite_failed <<EOF
$(printf '%s\n' "$totals_line" | sed -E 's/.*Total[[:space:]]+([0-9]+)[[:space:]]+Passed[[:space:]]+([0-9]+)[[:space:]]+Skipped[[:space:]]+([0-9]+)[[:space:]]+Failed[[:space:]]+([0-9]+).*/\1 \2 \3 \4/')
EOF

if [ -z "${suite_total:-}" ] || [ -z "${suite_passed:-}" ] || [ -z "${suite_failed:-}" ]; then
  echo "test.sh: FAIL -- could not parse counts out of: $totals_line" >&2
  emit_ctrf "jimtcl-selftest" 0 1
  exit 1
fi

echo "test.sh: upstream tests/*.test suite: total=$suite_total passed=$suite_passed skipped=$suite_skipped failed=$suite_failed"

# ---------------------------------------------------------------------------
# 2) A few direct known-answer probes on top of the suite, run straight
#    through the same dynamically-linked ./jimsh via `-e` (bash/coreutils are
#    whitelisted by the sabotage shim, so the comparison happens where
#    sabotage cannot hide). Unconditional -- a missing/wrong value is a
#    failure, not a skip.
# ---------------------------------------------------------------------------
kat_pass=0
kat_fail=0

check_kat() {
  local desc="$1" script="$2" want="$3"
  local got
  got="$("$SRC/jimsh" -e "$script" 2>&1)"
  if [ "$got" = "$want" ]; then
    kat_pass=$((kat_pass+1))
  else
    kat_fail=$((kat_fail+1))
    echo "test.sh: KAT FAIL [$desc]: script=<$script> want=<$want> got=<$got>" >&2
  fi
}

check_kat "arithmetic"    'expr {6 * 7}'                                   '42'
check_kat "string-upper"  'string toupper {jim tcl}'                       'JIM TCL'
check_kat "list-join"     'join [list a b c] ,'                            'a,b,c'
check_kat "dict-get"      'dict get [dict create a 1 b 2 c 3] b'           '2'

echo "test.sh: KAT probes: $kat_pass passed, $kat_fail failed (of $((kat_pass+kat_fail)))"

total_passed=$((suite_passed + kat_pass))
total_failed=$((suite_failed + kat_fail))
total_skipped=$suite_skipped

emit_ctrf "jimtcl-selftest" "$total_passed" "$total_failed" "$total_skipped"
