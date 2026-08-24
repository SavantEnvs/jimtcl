# UBSan: left shift of 1 by 63 in `binary format`/`binary scan` bit-pack helper

**Found:** same local fork-mode smoke run as `../split-utf8-heap-overflow/`
(see that README for the run parameters). This exact crash PC
(`jim-pack.c:188:43`) recurred at least twice independently during the run
(different corpus inputs), and coverage kept climbing around it — a real,
easily-reachable bug, not a fuzzer fluke.

**Reproduce:**
```
/mayhem/fuzz_jim_eval-standalone mayhem/fuzz_jim_eval/known-findings/pack-shift-ub/repro.bin
```

**UBSan report:**
```
../jim-pack.c:188:43: runtime error: left shift of 1 by 63 places cannot be represented in type 'long long'
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior ../jim-pack.c:188:43
```

**Cause (`jim-pack.c`, `JimSetBitsIntLittleEndian`, and its big-endian twin
`JimSetBitsIntBigEndian` a few lines above have the same shape):**

```c
static void JimSetBitsIntLittleEndian(unsigned char *bitvec, jim_wide value, int pos, int width)
{
    int i;
    if (pos % 8 == 0 && width == 8) { bitvec[pos / 8] = value; return; }
    for (i = 0; i < width; i++) {
        int bit = !!(value & ((jim_wide)1 << i));   /* jim-pack.c:188 */
        JimSetBitLittleEndian(bitvec, pos + i, bit);
    }
}
```

`jim_wide` is a signed 64-bit integer (`long long`). `width` comes from the
user-supplied pack/scan format string's bit-count field (the `B`/`b` etc.
directives accept an arbitrary count, e.g. `binary format b64 ...`). When
`width` reaches 64, the loop's `i` reaches 63, and `(jim_wide)1 << 63`
shifts a 1-bit into the sign bit of a signed type — undefined behavior in C
(only well-defined for unsigned types), caught here by
`-fsanitize=undefined`'s shift check.

Note this repo's current HEAD (`825be07 pack: reject bitoffset that
overflows int in JimSetBitsInt*`) already fixes a *related* but distinct
overflow in the same file (the bit **position/offset** argument overflowing
`int`) — this finding is a **different, still-open** overflow in the same
family of helpers, on the **width** (shift amount) rather than the position.

**Impact:** undefined behavior (signed left-shift overflow) reachable from
ordinary Tcl script text via `binary format`/`binary scan` with an
attacker-controlled bit-width field — no special extension needed (core
`jim-pack.c`, part of the always-on `pack` extension). In practice, on
x86-64/clang without UBSan this typically evaluates predictably (shifts mod
64), but it is formally UB and the C standard does not guarantee that across
compilers/optimization levels — a UBSan-instrumented or otherwise-conforming
build can miscompile or trap on it.

**Upstream fix (not applied here — additive-only integration):** cast to the
unsigned counterpart before shifting (`((unsigned jim_wide)1 << i)`), the
same style of fix the current HEAD already applied to the position/offset
overflow in the neighboring `JimSetBitsBigEndian`/`JimSetBitsLittleEndian`.
