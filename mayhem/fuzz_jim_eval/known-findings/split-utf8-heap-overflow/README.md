# heap-buffer-overflow READ in `split` on malformed UTF-8 input

**Found:** local fork-mode smoke run (`-fork=4 -ignore_crashes=1 -ignore_ooms=1
-ignore_timeouts=1`, seeded from `mayhem/fuzz_jim_eval/testsuite/`), well within
the first 90 seconds. Coverage kept climbing across it (not a "stuck on one
bug" flat-coverage case) — this and `../pack-shift-ub/` were two distinct
crash PCs found in the same run, plus two independent timeouts.

**Reproduce:**
```
/mayhem/fuzz_jim_eval-standalone mayhem/fuzz_jim_eval/known-findings/split-utf8-heap-overflow/repro.bin
```

**ASan report (trimmed to the relevant frames):**
```
==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x502000006775
READ of size 3 at 0x502000006775 thread T0
    #0 __asan_memcpy
    #1 Jim_StrDupLen             jim.c:717
    #2 Jim_NewStringObj          jim.c:2518
    #3 Jim_NewStringObjUtf8      jim.c:2534
    #4 Jim_SplitCoreCommand      jim.c:16475
    ...
0x502000006775 is located 0 bytes after 5-byte region [...,0x502000006775)
allocated by thread T0 here:
    #0 malloc
    #1 Jim_StrDupLen             jim.c:715
```

A second, independently-discovered crash in the same fork-mode run
(`crash-c3e3944664513bdd0ae3a0e947fb4f69a95f1d3a`, not committed here — same
PC/stack, "READ of size 4" instead of "size 3") confirms this is a real,
repeatable bug class, not a one-off fuzzer fluke.

**Cause (from source review, `jim.c`'s `Jim_SplitCoreCommand`):** when the
`splitChars` argument is empty (`split $s {}`, the "split into individual
characters" mode), the per-character loop does:

```c
strLen = Jim_Utf8Length(interp, argv[1]);   /* counts UTF-8 CHARACTERS */
...
while (strLen--) {
    int n = utf8_tounicode(str, &c);
    ...
    Jim_ListAppendElement(interp, resObjPtr, Jim_NewStringObjUtf8(interp, str, 1));
    str += n;
}
```

`Jim_Utf8Length()` walks the string decoding UTF-8 sequences to get a
*character* count. If the string contains a byte sequence that
`Jim_Utf8Length()`'s decoder and `utf8_tounicode()`'s decoder disagree about
(e.g. an overlong/invalid multi-byte lead byte near the end of the buffer),
`strLen` can end up larger than the number of `utf8_tounicode()` steps
actually needed to consume the string — so the loop keeps calling
`Jim_NewStringObjUtf8(interp, str, 1)` after `str` has already walked past
the live bytes of the underlying string object, and `Jim_StrDupLen`'s
`memcpy` reads past the allocation.

**Impact:** an out-of-bounds heap READ (up to a few bytes past the
allocation) reachable from ordinary Tcl script text via the built-in `split`
command with malformed/truncated UTF-8 input — no special extension needed
(this path is unaffected by the fuzz build's disabled-extension list; it's
core `jim.c`). In this ASan build it aborts the process (denial of service /
crash on attacker-controlled script input); in a build without ASan it is an
information-disclosure-shaped OOB read whose result feeds into the returned
list element.

**Upstream fix (not applied here — additive-only integration):** bound the
per-character walk by the same decoding rule `Jim_Utf8Length()` uses (or, more
robustly, stop the loop as soon as `str` reaches `strEnd = str_orig + len`,
rather than trusting a separately-computed character count against a
byte-oriented decode loop that can desync on malformed input).
