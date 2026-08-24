#!/usr/bin/env bash
#
# mayhem/build.sh — build Jim Tcl's fuzz harness + oracle test suite.
#
# Jim Tcl (msteveb/jimtcl) is a small-footprint Tcl interpreter in C, built via
# its own "autosetup" (Tcl-flavored autoconf) ./configure + make. It bootstraps
# a local jimsh0 to generate a few extensions from embedded Tcl source
# (jim-stdlib.c etc, via the TCLEXT rule in Makefile.in) — fully self-contained,
# no network/tclsh required.
#
# Two independent builds (the dual-build pattern from the porting skill).
# jimtcl's own Makefile IS VPATH/out-of-tree capable (Makefile.in:
# `VPATH := @srcdir@`, `@builddir@`, `@abs_top_srcdir@`), which is what makes
# the two coexist in principle -- BUT the ORDER below is load-bearing:
#
#   1) FUZZ    FIRST, out-of-tree under mayhem-build/, sanitized + restricted
#      extensions. Must run while $SRC ($SRC/*.o) is still completely
#      pristine: GNU Make's VPATH search treats a same-named object file it
#      finds in @srcdir@ (== $SRC) as satisfying a target if present, WITHOUT
#      checking which ./configure produced it. Empirically confirmed: doing
#      the (unsanitized, full-extension) oracle build FIRST leaves jim-*.o
#      sitting at $SRC, and a subsequent out-of-tree `make libjim.a` in
#      mayhem-build/ silently VPATH-reuses those stale, wrongly-configured
#      objects instead of recompiling its own -- e.g. jim-eventloop.o built
#      WITH `signal` enabled gets pulled into the FUZZ archive even though
#      this build disables `signal`, so the linker fails on an undefined
#      `Jim_SignalSetIgnored` (jim-signal.c, which this build never compiles).
#      Doing FUZZ first means $SRC has zero objects yet, so VPATH has nothing
#      stale to match and mayhem-build/ always compiles its own.
#   2) ORACLE  SECOND, in-tree at $SRC (upstream's own recipe: plain
#      ./configure && make, unsanitized, every default extension). This step
#      is a normal in-tree build (srcdir == builddir == $SRC), so it is not
#      subject to the VPATH trap above -- order relative to it only matters
#      for step (1).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${AR:=ar}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
[ -x ./configure ] || { echo "build.sh: no ./configure at repo root -- upstream layout changed?" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1) FUZZ build (FIRST -- see ordering note above): out-of-tree (VPATH)
#    configure + build of libjim.a only, with sanitizer + debug flags, PLUS a
#    restricted extension set that drops every Jim command able to touch the
#    filesystem, spawn/signal a process, dlopen a shared object, or write
#    syslog -- so the fuzzed interpreter has no host bindings beyond the bare
#    language (see mayhem/fuzz_jim_eval.c's header comment for the exact
#    file-by-file justification):
#      exec     — jim-exec.c    (spawns child processes)
#      load     — jim-load.c    (dlopen())
#      posix    — jim-posix.c   (os.fork, kill, uptime, ...)
#      aio      — jim-aio.c     (file + socket I/O)
#      file     — jim-file.c    (file exists/delete/mkdir/...)
#      readdir  — jim-readdir.c (opendir/readdir)
#      glob     — glob.tcl      (Tcl-level, implemented ON TOP of readdir)
#      syslog   — jim-syslog.c  (openlog/syslog)
#      signal   — jim-signal.c  (kill())
#      history  — interactive-only; disabled for symmetry (not needed here)
#    `-fsanitize=fuzzer-no-link` is appended UNCONDITIONALLY -- including when
#    SANITIZER_FLAGS is the empty/no-sanitizer build -- so the LIBRARY (not
#    just the harness TU) carries SanCov coverage instrumentation; without it
#    Mayhem records 0 edges even though the harness builds and smoke-tests
#    fine locally.
# ---------------------------------------------------------------------------
FUZZ_BUILD_DIR="$SRC/mayhem-build"
mkdir -p "$FUZZ_BUILD_DIR"
(
  cd "$FUZZ_BUILD_DIR"
  # shellcheck disable=SC2086
  CC="$CC" "$SRC/configure" \
    --without-ext=exec,load,posix,aio,file,readdir,glob,syslog,signal,history \
    --disable-lineedit
  # shellcheck disable=SC2086
  make CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -j"$MAYHEM_JOBS" libjim.a
)
[ -f "$FUZZ_BUILD_DIR/libjim.a" ] || { echo "build.sh: FUZZ build did not produce libjim.a" >&2; exit 1; }
# Guard against the VPATH trap regressing silently: the restricted archive
# must NOT contain the symbols only jim-signal.c/jim-load.c (excluded above)
# provide -- if it does, some member got VPATH-reused from a differently
# configured build instead of compiled fresh here.
if "$AR" t "$FUZZ_BUILD_DIR/libjim.a" | grep -qE '^jim-(signal|load)\.o$'; then
  echo "build.sh: FUZZ libjim.a unexpectedly contains jim-signal.o/jim-load.o -- VPATH likely reused a stale object from \$SRC; ensure the FUZZ build runs before the ORACLE build touches \$SRC" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2) ORACLE build (SECOND): plain upstream recipe, in-tree, unsanitized,
#    upstream's normal flags. Produces ./jimsh (dynamically linked — needed
#    for the LD_PRELOAD sabotage check) plus tests/Makefile so mayhem/test.sh
#    can run the real upstream suite (tests/*.test via tests/runall.tcl)
#    unmodified. All default extensions enabled (matches upstream's own
#    ./configure with no args, i.e. what .github/workflows/makefile.yml's
#    build-linux job effectively exercises for the language core — we skip
#    only that CI's --allextmod/--maintainer, which pull in optional
#    sqlite3/hiredis/ssl deps unrelated to the interpreter core and not
#    installed in this image).
# ---------------------------------------------------------------------------
CC="$CC" ./configure
make -j"$MAYHEM_JOBS"
[ -x ./jimsh ] || { echo "build.sh: oracle build did not produce ./jimsh" >&2; exit 1; }
file ./jimsh | grep -q 'dynamically linked' || { echo "build.sh: ./jimsh is not dynamically linked (needed by the sabotage/LD_PRELOAD check)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3) Harness: one fuzzer binary (linked against $LIB_FUZZING_ENGINE) and one
#    standalone (non-fuzzer) reproducer (linked against $STANDALONE_FUZZ_MAIN,
#    LLVM's run-once driver) -- both plain C, so no C++-mangling split compile
#    is needed. -lz for zlib (statically-linked extension list still includes
#    the zlib command's compiled object even though we don't call it from
#    fuzzed script paths reachable without file I/O -- harmless to keep
#    linked); -lrt for timer_create/timer_settime (the independent watchdog;
#    glibc >= 2.34 folds librt into libc, but -lrt is a harmless no-op there
#    and required on older glibc).
# ---------------------------------------------------------------------------
mkdir -p /mayhem

# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I"$FUZZ_BUILD_DIR" -I"$SRC" \
  $LIB_FUZZING_ENGINE \
  mayhem/fuzz_jim_eval.c "$FUZZ_BUILD_DIR/libjim.a" \
  -lm -lz -lrt \
  -o /mayhem/fuzz_jim_eval

# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I"$FUZZ_BUILD_DIR" -I"$SRC" \
  "$STANDALONE_FUZZ_MAIN" \
  mayhem/fuzz_jim_eval.c "$FUZZ_BUILD_DIR/libjim.a" \
  -lm -lz -lrt \
  -o /mayhem/fuzz_jim_eval-standalone

[ -x /mayhem/fuzz_jim_eval ] || { echo "build.sh: fuzz_jim_eval was not produced" >&2; exit 1; }
[ -x /mayhem/fuzz_jim_eval-standalone ] || { echo "build.sh: fuzz_jim_eval-standalone was not produced" >&2; exit 1; }

echo "build.sh: OK -- ./jimsh (oracle), /mayhem/fuzz_jim_eval (fuzz), /mayhem/fuzz_jim_eval-standalone (repro)"
