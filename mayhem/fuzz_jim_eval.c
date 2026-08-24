/**
 * mayhem/fuzz_jim_eval.c — libFuzzer harness for Jim Tcl's script evaluator.
 *
 * Feeds raw fuzzer bytes straight to Jim_Eval(), the same entry point jimsh's
 * own `-e CMD` path uses (see jimsh.c main(): Jim_CreateInterp() +
 * Jim_RegisterCoreCommands() + Jim_InitStaticExtensions() + Jim_Eval()).
 * This exercises the full pipeline: the Tcl-style parser/tokenizer -> the
 * bytecode-free tree-walking evaluator -> the object system (string/list/
 * dict/array/expr/proc/oo/namespace/json/regexp/binary/pack/...) -> GC
 * (reference counting).
 *
 * We deliberately do NOT call Jim_initjimshInit() (jimsh's own interactive
 * setup, from initjimsh.tcl): it probes $HOME for ~/.jimrc and searches
 * $PATH/argv0 on disk (see jimtcl's initjimsh.tcl, proc _jimsh_init) purely
 * to support the interactive shell. Skipping it keeps the harness itself
 * free of filesystem I/O, matching docs/netnew-worker-prompt.md §3.
 *
 * No host bindings: mayhem/build.sh configures the FUZZ library (a separate
 * build from the oracle jimsh — see build.sh step 2) with
 *   --without-ext=exec,load,posix,aio,file,readdir,glob,syslog,signal,history
 * which compiles OUT every Jim command that can touch the filesystem
 * (file/aio/readdir/glob), spawn or signal a process (exec/posix/signal),
 * dlopen a shared object (load), write syslog, or read ~/.jimrc (history's
 * interactive-only sibling risk). Verified: only jim-aio.c, jim-exec.c,
 * jim-file.c, jim-load.c, jim-posix.c (and the win32-only jim-win32compat.c)
 * call fopen/open/stat/system/dlopen/execv/fork/popen/mkdir/unlink/socket —
 * all excluded. What remains (array, binary, clock, ensemble, eventloop,
 * interp, json, jsonencode, namespace, oo, pack, package, regexp, stdlib,
 * tclcompat, tclprefix, tree, zlib) is pure in-memory language + data
 * structure surface, plus the built-in Tcl-compatible regexp engine
 * (jimregexp.c, not POSIX regex).
 *
 * Watchdog: Jim bounds *recursion* by default (JIM_MAX_CALLFRAME_DEPTH=1000,
 * JIM_MAX_EVAL_DEPTH=2000 in jim.h, enforced in jim.c) — that catches a
 * runaway `proc` calling itself. It does NOT bound a flat native loop:
 * `while {1} {}` or `for {} 1 {} {}` runs entirely as host C code inside
 * Jim_Eval() with nothing to interrupt it, and neither does a single huge
 * allocation (`string repeat x 999999999`). This is exactly the shape
 * documented in docs/netnew-worker-prompt.md §6b (proven on goja/kuroko/ark):
 * an interpreter with host-implemented builtins needs an INDEPENDENT
 * process-level watchdog, not just its own recursion guard. Per §6b, do NOT
 * use alarm()/SIGALRM/setitimer(ITIMER_REAL, ...): libFuzzer's own -timeout
 * owns ITIMER_REAL/SIGALRM, and a harness alarm() either gets silently
 * swallowed by libFuzzer's handler or (if we install our own SIGALRM
 * handler) permanently disables libFuzzer's own timeout reporting for the
 * rest of the process. Use an independent POSIX per-process timer instead:
 * timer_create(CLOCK_MONOTONIC, ...) delivering a realtime signal
 * (SIGRTMIN+5) that libFuzzer never touches, armed immediately before each
 * Jim_Eval() and disarmed right after.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

#include <jim.h>

/* Independent watchdog signal + budget (see header comment above). */
#ifndef MAYHEM_WATCHDOG_SIGNAL
#define MAYHEM_WATCHDOG_SIGNAL (SIGRTMIN + 5)
#endif
#ifndef MAYHEM_WATCHDOG_MS
#define MAYHEM_WATCHDOG_MS 1500L
#endif
/* Jim's own defaults (JIM_MAX_CALLFRAME_DEPTH / JIM_MAX_EVAL_DEPTH, jim.h)
 * are 1000/2000 -- plenty deep for real scripts, but we tighten them a bit
 * so a runaway recursive proc fails fast as a normal Tcl error (caught by
 * Jim_Eval's return code) rather than eating a large fraction of the
 * per-input time budget building call frames. */
#ifndef MAYHEM_MAX_CALLFRAME_DEPTH
#define MAYHEM_MAX_CALLFRAME_DEPTH 256
#endif
#ifndef MAYHEM_MAX_EVAL_DEPTH
#define MAYHEM_MAX_EVAL_DEPTH 512
#endif
/* Nothing about Tcl's grammar needs a multi-megabyte source to explore new
 * parser/evaluator code paths; keep individual runs fast. */
#ifndef MAYHEM_MAX_INPUT
#define MAYHEM_MAX_INPUT (64 * 1024)
#endif

static timer_t g_watchdog;
static int g_watchdog_ok = 0;

static void mayhem_watchdog_fire(int signo)
{
    (void)signo;
    /* _exit(), not exit(): no atexit()/stdio flushing that could itself
     * block or reenter a half-broken interpreter. 70 is EX_SOFTWARE-ish and
     * distinct from a plain ASan/UBSan abort, so it is recognizable in
     * triage as "watchdog fired", not "crash". */
    _exit(70);
}

static void mayhem_watchdog_init(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = mayhem_watchdog_fire;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    if (sigaction(MAYHEM_WATCHDOG_SIGNAL, &sa, NULL) != 0) {
        return;
    }

    struct sigevent sev;
    memset(&sev, 0, sizeof(sev));
    sev.sigev_notify = SIGEV_SIGNAL;
    sev.sigev_signo = MAYHEM_WATCHDOG_SIGNAL;
    sev.sigev_value.sival_ptr = &g_watchdog;
    if (timer_create(CLOCK_MONOTONIC, &sev, &g_watchdog) != 0) {
        return;
    }
    g_watchdog_ok = 1;
}

static void mayhem_watchdog_arm(long ms)
{
    if (!g_watchdog_ok) {
        return;
    }
    struct itimerspec its;
    memset(&its, 0, sizeof(its));
    its.it_value.tv_sec = ms / 1000;
    its.it_value.tv_nsec = (ms % 1000) * 1000000L;
    timer_settime(g_watchdog, 0, &its, NULL);
}

static void mayhem_watchdog_disarm(void)
{
    if (!g_watchdog_ok) {
        return;
    }
    struct itimerspec its;
    memset(&its, 0, sizeof(its));
    timer_settime(g_watchdog, 0, &its, NULL);
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void)argc;
    (void)argv;
    mayhem_watchdog_init();
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0 || size > MAYHEM_MAX_INPUT) {
        return 0;
    }

    /* Jim_Eval() takes a NUL-terminated C string (jim.h: `const char
     * *script`) -- an embedded NUL would silently truncate what the fuzzer
     * generated, wasting the input re-exploring a prefix. Real Tcl source
     * cannot itself contain a NUL, so reject rather than truncate. */
    if (memchr(data, 0, size) != NULL) {
        return 0;
    }

    char *src = (char *)malloc(size + 1);
    if (!src) {
        return 0;
    }
    memcpy(src, data, size);
    src[size] = '\0';

    Jim_Interp *interp = Jim_CreateInterp();
    if (!interp) {
        free(src);
        return 0;
    }
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    interp->maxCallFrameDepth = MAYHEM_MAX_CALLFRAME_DEPTH;
    interp->maxEvalDepth = MAYHEM_MAX_EVAL_DEPTH;

    mayhem_watchdog_arm(MAYHEM_WATCHDOG_MS);
    Jim_Eval(interp, src);
    mayhem_watchdog_disarm();

    Jim_FreeInterp(interp);
    free(src);
    return 0;
}
