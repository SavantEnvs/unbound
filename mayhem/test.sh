#!/usr/bin/env bash
#
# unbound/mayhem/test.sh — RUN unbound's own internal unit-test binary (testcode/unitmain.c, built
# with NORMAL flags by mayhem/build.sh and stashed at /mayhem/unbound-unittest-oracle). It exercises
# dname/msgparse/ldns/validator/authzone/zonemd/tcpreuse/lruhash/slabhash/infra-cache/mesh/regional/
# alloc code via `unit_assert()` (testcode/unitmain.h) — a real, dynamically-linked, project-authored
# assertion suite, not a wrapper we invented.
#
# PATCH-grade oracle, behavioral (not exit-code-only): unitmain.c prints the EXACT number of
# assertions it ran ("<N> checks ok.") only after every unit_assert() in the fixed run sequence
# passed, and calls exit(1) immediately (via unit_assert's `if(!(x)) exit(1)`) the instant one fails
# — so the count line is only ever printed on a fully successful, non-neutered run. A program
# neutered to exit(0) immediately prints NEITHER line below and this fails loudly.
#
# Two assertions, for two different reasons:
#  1. A genuine KNOWN-ANSWER check: testcode/unitmsgparse.c's encode-speed micro-benchmark encodes a
#     FIXED root-hints wire packet (a literal hex blob in the test source) exactly 10000 times (a
#     compile-time constant, `size_t max = 10000`) and prints the encoded size in bytes — both are
#     fixed values independent of timing/host load: "[0] did 10000 in <T> msec for <R> encode/sec
#     size 615". We assert the "10000"/"615" fields exactly (the only two non-timing fields).
#  2. A floor on the total assertion count. This is NOT pinned to an exact number: measured across
#     three separate builds of the SAME commit on this (heavily loaded, shared) box the total varied
#     by a few hundred (1306640 / 1306695 / 1306802 checks ok) — some of unitmain.c's suites (infra
#     cache probing/mesh) branch on real wall-clock timing, so the exact count is not reproducible
#     under contention even though the suite is otherwise deterministic. A floor comfortably below
#     the observed range but far above what a broken/partial/neutered run could ever print still
#     proves the full suite ran to completion.
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

BIN=/mayhem/unbound-unittest-oracle
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; emit_ctrf "unbound-unittest" 0 1; exit $?; }

# Floor well below the observed ~1,306,640-1,306,802 range (comfortable margin for further
# environment jitter) but far above anything a broken/partial/neutered run could print (the suite
# fails fast via exit(1) on the FIRST bad assertion, so a truncated run prints a much smaller count
# or, for a neutered exit(0), no count line at all).
MIN_CHECKS=1300000

out="$("$BIN" 2>&1)"; rc=$?
echo "$out"

bench="$(printf '%s\n' "$out" | grep -E '^\[0\] did [0-9]+ in .* encode/sec size [0-9]+$' | tail -1)"
bench_iters="$(printf '%s\n' "$bench" | sed -n 's/^\[0\] did \([0-9]*\) in.*/\1/p')"
bench_size="$(printf '%s\n' "$bench" | sed -n 's/.*encode\/sec size \([0-9]*\)$/\1/p')"

got="$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) checks ok\.$/\1/p' | tail -1)"

if [ "$rc" -eq 0 ] && [ "${bench_iters:-0}" -eq 10000 ] && [ "${bench_size:-0}" -eq 615 ] \
   && [ -n "$got" ] && [ "$got" -ge "$MIN_CHECKS" ]; then
  emit_ctrf "unbound-unittest" 1 0
else
  echo "FAIL: expected rc=0, encode-benchmark '10000 .. size 615' (got iters='${bench_iters:-<none>}' size='${bench_size:-<none>}'), and >=$MIN_CHECKS checks ok (got rc=$rc checks='${got:-<none>}')" >&2
  emit_ctrf "unbound-unittest" 0 1
fi
