# Benchmarks

Methodology:

- zphp built with `zig build -Doptimize=ReleaseFast`
- reference: PHP 8.5.7 CLI with OPcache enabled (`opcache.enable_cli=1`, JIT off)
- wall-clock time, best (minimum) of 5 runs per workload
- Windows x64

Reproduce:

```console
zig build -Doptimize=ReleaseFast
bash scripts/bench.sh 5
```

## Results (hash arrays + rope strings, ReleaseFast, vs PHP 8.5 CLI)

| workload | description | zphp (ms) | php (ms) | ratio |
|---|---|---:|---:|---:|
| fib | recursive fibonacci(27) — call overhead, branching | 77 | 96 | **0.8x** |
| loop | 30M iteration integer accumulation | 887 | 511 | 1.7x |
| arrays | 500k appends + foreach sum | 100 | 100 | **1.0x** |
| strings | 100k `.` concatenations into a growing string | 37 | 83 | **0.4x** |

Key optimizations beyond the ISA switch itself:
- hash-indexed arrays: O(1) key lookup (string keys normalized, so byte
  equality is exact)
- rope concatenation: `.`/`.=` chains build cons cells; materialization
  is deferred until raw bytes are needed (O(total), not O(n²))
- target-directed codegen: expressions write their destination register
  directly; compound assigns read var operands in place (no temp+mov)
- int/int fast paths bypass the loose-comparison machinery
- call frames only null-init locals, not temporaries; arguments copy
  directly between register files; register files are pooled across calls
- strings boxed behind heap headers: Value is a 16-byte tagged struct
  (was 24), Zend-zval style. True single-word NaN-boxing was evaluated
  and rejected: PHP requires full i64 (NaN-boxing caps at 48-bit SMIs)
  and slice strings need two words anyway

## History

| engine | fib | loop | arrays | strings |
|---|---:|---:|---:|---:|
| tree-walking interpreter | 1.7x | 7.8x | 1.5x | 11.9x |
| stack bytecode VM (fused) | 1.1x | 2.6x | 0.8x | 12.0x |
| register bytecode VM | 1.1x | 2.2x | 0.7x | 12.0x |
| **+ hash arrays / ropes / frame pool** | **0.8x** | **1.9x** | **1.0x** | **0.4x** |

(ratios vs PHP 8.5 + OPcache; lower is better)

## Notes

- The remaining loop gap (~4 instructions/iteration vs PHP's ~3) is per-
  instruction fixed cost, measured at ~5.6ns/instr vs PHP's ~2ns on an
  empty-body loop: tagged-union Value operations and register indirection,
  not jump-table dispatch. Threaded dispatch was evaluated and rejected:
  Zig gives no tail-call guarantee (native-stack growth), and full labeled-
  switch chaining is high-churn for an unproven win. The next lever is a
  specialized small-value representation (e.g. NaN-boxing) to collapse
  per-op type checks.
- String workloads pay double: each `.` allocates a fresh arena string
  (O(n^2) total for repeated append), same asymptotics as PHP but without
  its internal optimizations (e.g. target-string reuse in CONCAT ops).
- Array performance beats the reference because ordered-dict operations map
  well onto an entry list with a next-index fast path.

## JIT (baseline, tier-1) — EXPERIMENTAL, opt-in via `--jit`

`src/jit.zig` compiles eligible user functions to native x86-64 on first
invocation (Windows x64 ABI). Tier-1 op set: int const/mov/add/sub/mul,
inc, int compare-and-branch, jmp, returns. Every potentially-failing check
is guarded (tag-byte compares + overflow `jo`); a failed guard deopts by
returning the bytecode resume-ip and the interpreter finishes the call.
Compilation is all-or-nothing per function: one unsupported op (division,
strings, calls...) bails to interpretation.

**Status: NOT enabled by default.** Under ReleaseFast builds, deopt-path
executions corrupt VM state nondeterministically (garbage operand types,
segfaults far from the call site). The emitted machine code hand-decodes
correct and the ABI contract is verified; Debug/ReleaseSafe never exercise
the JIT because probeLayout legitimately fails there (tag-word padding),
which masked the issue during development. The trigger interacts with
apparently irrelevant source changes (layout-dependent UB); suspected but
unconfirmed causes include Zig 0.16-dev codegen around indirect calls into
raw executable memory. Isolation hardening (running against a scratch
buffer) reduces but does not eliminate it.

Measured when it does run (ReleaseFast, microtime inside PHP):

| workload | zphp interp | zphp --jit | php 8.5 |
|---|---:|---:|---:|
| sumTo(30M) — pure int accumulation | 948 ms | **46 ms** | 403 ms |

i.e. ~20x over our interpreter, ~9x over PHP CLI for the tier-1 sweet spot.

Debug notes for future work:
- Value layout is probed at runtime (payload/tag word order varies with
  Zig's union layout); tag guards must be byte compares (`80 B9 disp8`)
  because the interpreter only writes the low tag byte — pooled register
  files leave stale high bytes.
- ADD/SUB/CMP encode dest in rm field, src in reg field; IMUL r64,r/m64
  is the reverse. Getting REX.B/R backwards silently corrupts results.
- The normal-exit block must not fall through into the deopt-exit block;
  that turned every completion into a spurious deopt (correct output,
  double execution).
- invokeUser (methods/ctors/statics) must dispatch after pushing a deopt-
  resumed frame — its callers sit inside an outer dispatch() that keeps
  executing the CALLER frame; an undispatched zombie frame corrupts the
  frame stack (segfault). doCall already dispatched correctly.
- probeLayout fails under Debug/ReleaseSafe (union padding leaves garbage
  in the tag word's high bytes), so the JIT is silently skipped there;
  don't trust Debug-mode JIT test results as JIT coverage.

## Planned improvements

1. Rope/string-builder representation for `.=` accumulation (strings).
2. Optional interned-key hash index for large assoc arrays (currently linear
   scan on non-append writes).
