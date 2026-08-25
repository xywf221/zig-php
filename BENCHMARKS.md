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
| loop | 30M iteration integer accumulation | 945 | 486 | 1.9x |
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

## Planned improvements

1. Rope/string-builder representation for `.=` accumulation (strings).
2. Optional interned-key hash index for large assoc arrays (currently linear
   scan on non-append writes).
