#!/usr/bin/env bash
#
# unbound/mayhem/build.sh — build the 5 OSS-Fuzz-parity libFuzzer harnesses that exercise
# unbound's DNS wire-format packet parser (util/data/msgparse.c parse_packet(), the iterator's
# message scrubber iter_scrub.c scrub_message(), and sldns/{wire2str,str2wire}.c), PLUS unbound's
# own internal unit-test binary (testcode/unitmain.c) as the clean functional oracle for test.sh.
#
# Targets (names match google/oss-fuzz/projects/unbound exactly — §6.2 item 12 parity):
#   parse_packet_fuzzer  - parse_packet() on a raw wire-format buffer
#   fuzz_1_fuzzer         - parse_packet() + scrub_message() (the iterator response scrubber)
#   fuzz_2_fuzzer         - sldns_wire2str_* EDNS-option / scan functions
#   fuzz_3_fuzzer         - sldns_str2wire_* buffer parsers
#   fuzz_4_fuzzer         - parse_packet() + scrub_message() with a live rrset cache attached
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS
cd "$SRC"

# libexpat is required unconditionally by unbound's configure.ac (unbound-anchor links -lexpat).
# It is NOT in the base image's default package set, so mayhem/Dockerfile apt-get installs
# libexpat1-dev as root before USER mayhem / this script runs. Fail loudly (not silently) if it's
# somehow still missing, rather than letting configure's own cryptic error stand in for this.
[ -f /usr/include/expat.h ] || { echo "libexpat1-dev (expat.h) missing — install it in mayhem/Dockerfile as root" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# 1) Build unbound's OWN unit-test binary FIRST, with NORMAL (unsanitized) flags — a clean,
#    independent build — and stash it to /mayhem so mayhem/test.sh only RUNS it. `make clean`
#    both before (idempotent PATCH-tier re-run) and after (drop normal-flags objects before the
#    sanitized rebuild below).
# ---------------------------------------------------------------------------------------------
make clean >/dev/null 2>&1 || true
./configure --disable-shared
make -j"$MAYHEM_JOBS" unittest
cp unittest /mayhem/unbound-unittest-oracle
make clean

# ---------------------------------------------------------------------------------------------
# 2) Build unbound itself WITH the sanitizers + fuzzer-no-link coverage instrumentation (so the
#    fuzzed LIBRARY carries SanCov edges, not just the harness translation unit) + DWARF-3 debug
#    info. `-DVALGRIND=1` matches upstream's own fuzz build.sh: util/storage/lookup3.c has a
#    documented-safe unaligned-read idiom that otherwise trips ASan; the VALGRIND branch avoids it.
# ---------------------------------------------------------------------------------------------
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DVALGRIND=1" \
  ./configure --disable-shared
make -j"$MAYHEM_JOBS" all unittest

# The exact object list unbound's own OSS-Fuzz build.sh links each fuzzer against (the library,
# minus the daemon/checkconf/control/anchor mains) — kept identical for parity/maintainability.
OBJECTS_TO_LINK="dns.o infra.o rrset.o dname.o \
  msgencode.o as112.o msgparse.o msgreply.o packed_rrset.o iterator.o \
  iter_delegpt.o iter_donotq.o iter_fwd.o iter_hints.o iter_priv.o \
  iter_resptype.o iter_scrub.o iter_utils.o localzone.o mesh.o modstack.o view.o \
  outbound_list.o alloc.o config_file.o configlexer.o configparser.o \
  fptr_wlist.o edns.o locks.o log.o mini_event.o module.o net_help.o random.o \
  rbtree.o regional.o rtt.o dnstree.o lookup3.o lruhash.o slabhash.o \
  tcp_conn_limit.o timehist.o tube.o winsock_event.o autotrust.o val_anchor.o \
  validator.o val_kcache.o val_kentry.o val_neg.o val_nsec3.o val_nsec.o \
  val_secalgo.o val_sigcrypt.o val_utils.o dns64.o authzone.o \
  respip.o netevent.o listen_dnsport.o outside_network.o ub_event.o keyraw.o \
  sbuffer.o wire2str.o parse.o parseutil.o rrdef.o str2wire.o libunbound.o \
  libworker.o context.o rpz.o proxy_protocol.o timeval_func.o rfc_1982.o \
  siphash.o"
LIBOBJS="$(make --eval 'echolibobjs: ; @echo "$(LIBOBJS)"' echolibobjs)"

# ---------------------------------------------------------------------------------------------
# 3) Compile + link each harness TWICE: once against $LIB_FUZZING_ENGINE (the fuzzer binary), once
#    against $STANDALONE_FUZZ_MAIN (a run-once, non-fuzzer reproducer). The harnesses are plain C
#    (LLVMFuzzerTestOneInput keeps C linkage); link the fuzzer binary with $CXX (libFuzzer's
#    runtime is C++) and the standalone with $CC (pure C, no libFuzzer runtime involved).
# ---------------------------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# Binary names match google/oss-fuzz/projects/unbound EXACTLY (§6.2 item 12 parity check compares
# basenames): parse_packet_fuzzer.c -> "parse_packet_fuzzer" (no extra suffix, source already named
# it); fuzz_N.c -> "fuzz_N_fuzzer" (oss-fuzz's build.sh appends _fuzzer to those four).
declare -A OUTNAME=(
  [parse_packet_fuzzer]=parse_packet_fuzzer
  [fuzz_1]=fuzz_1_fuzzer
  [fuzz_2]=fuzz_2_fuzzer
  [fuzz_3]=fuzz_3_fuzzer
  [fuzz_4]=fuzz_4_fuzzer
)
for f in parse_packet_fuzzer fuzz_1 fuzz_2 fuzz_3 fuzz_4; do
  out="${OUTNAME[$f]}"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DVALGRIND=1 \
      -I. -DSRCDIR=. -c "mayhem/$f.c" -o "/tmp/$f.harness.o"

  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I. -DSRCDIR=. \
      "/tmp/$f.harness.o" $OBJECTS_TO_LINK $LIBOBJS -lssl -lcrypto -lpthread \
      -o "/mayhem/${out}"

  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      "/tmp/$f.harness.o" /tmp/standalone_main.o $OBJECTS_TO_LINK $LIBOBJS -lssl -lcrypto -lpthread \
      -o "/mayhem/${out}-standalone"
done

echo "build.sh: built 5 fuzz targets + standalone reproducers + unittest oracle"
