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

## Results (register bytecode VM + type fast paths, ReleaseFast)

| workload | description | zphp (ms) | php (ms) | ratio |
|---|---|---:|---:|---:|
| fib | recursive fibonacci(27) - call overhead, branching | 104 | 99 | **1.1x** |
| loop | 30M iteration integer accumulation | 1072 | 491 | 2.2x |
| arrays | 500k appends + foreach sum | 73 | 102 | **0.7x** |
| strings | 100k `.` concatenations into a growing string | 1035 | 86 | 12.0x |

Key optimizations beyond the ISA switch itself:
- target-directed codegen: expressions write their destination register
  directly; compound assigns read var operands in place (no temp+mov)
- int/int fast paths bypass the loose-comparison machinery
- call frames only null-init locals, not temporaries; arguments copy
  directly between register files

## History

| engine | fib | loop | arrays | strings |
|---|---:|---:|---:|---:|
| tree-walking interpreter | 1.7x | 7.8x | 1.5x | 11.9x |
| stack bytecode VM (fused) | 1.1x | 2.6x | 0.8x | 12.0x |
| **register bytecode VM** | **1.1x** | **2.2x** | **0.7x** | 12.0x |

(ratios vs PHP 8.5 + OPcache; lower is better)

## Notes

- The remaining loop gap (~4 instructions/iteration vs PHP's ~3 specialized
  opcodes) is dispatch overhead. Next lever: superinstruction for the whole
  `local += local` + increment pattern, or a register allocator that keeps
  loop counters pinned.
- String workloads pay double: each `.` allocates a fresh arena string
  (O(n^2) total for repeated append), same asymptotics as PHP but without
  its internal optimizations (e.g. target-string reuse in CONCAT ops).
- Array performance beats the reference because ordered-dict operations map
  well onto an entry list with a next-index fast path.

## Planned improvements

1. Rope/string-builder representation for `.=` accumulation (strings).
2. Optional interned-key hash index for large assoc arrays (currently linear
   scan on non-append writes).
