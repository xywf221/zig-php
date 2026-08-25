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

## Results (register bytecode VM, ReleaseFast)

| workload | description | zphp (ms) | php (ms) | ratio |
|---|---|---:|---:|---:|
| fib | recursive fibonacci(27) — call overhead, branching | 125 | 96 | 1.3x |
| loop | 30M iteration integer accumulation | 1334 | 494 | 2.7x |
| arrays | 500k appends + foreach sum | 74 | 99 | **0.7x** |
| strings | 100k `.` concatenations into a growing string | 1027 | 84 | 12.5x |

The compiler is target-directed (`compileInto(dst, expr)`): expressions
write straight into their destination register, so even "generic" code
contains no operand-stack shuffling. Fused compare-and-branch instructions
remain for loop conditions; the loop body is down to 4 dispatched
instructions per iteration.

## History

| engine | fib | loop | arrays | strings |
|---|---:|---:|---:|---:|
| tree-walking interpreter | 1.7x | 7.8x | 1.5x | 11.9x |
| stack bytecode VM (fused) | 1.1x | 2.6x | 0.8x | 12.0x |
| **register bytecode VM** | 1.3x | **2.7x** | **0.7x** | 12.5x |

(ratios vs PHP 8.5 + OPcache; lower is better)

## Notes

- The remaining loop gap is dispatch overhead per instruction (~4 per
  iteration vs PHP's tighter opcode stream). Further fusion or a register
  bytecode would narrow it.
- String workloads pay double: each `.` allocates a fresh arena string
  (O(n^2) total for repeated append), same asymptotics as PHP but without
  its internal optimizations (e.g. target-string reuse in CONCAT ops).
- Array performance beats the reference because ordered-dict operations map
  well onto an entry list with a next-index fast path.

## Planned improvements

1. Rope/string-builder representation for `.=` accumulation (strings).
2. Optional interned-key hash index for large assoc arrays (currently linear
   scan on non-append writes).
