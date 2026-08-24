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
 * No timer or watchdog: Jim bounds recursion by default (JIM_MAX_CALLFRAME_DEPTH
 * / JIM_MAX_EVAL_DEPTH in jim.h) and the harness tightens both below. A flat
 * native loop (`while {1} {}`) is a hang, reported like a crash; Mayhem's
 * per-exec `timeout:` in the Mayhemfile bounds every input.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <jim.h>

/* Jim's own defaults (JIM_MAX_CALLFRAME_DEPTH / JIM_MAX_EVAL_DEPTH, jim.h)
 * are 1000/2000 -- plenty deep for real scripts, but we tighten them a bit
 * so a runaway recursive proc fails fast as a normal Tcl error (caught by
 * Jim_Eval's return code) rather than building a very deep call stack. */
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

    Jim_Eval(interp, src);

    Jim_FreeInterp(interp);
    free(src);
    return 0;
}
