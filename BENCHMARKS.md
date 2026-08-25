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

## Results (bytecode VM + fused superinstructions, ReleaseFast)

| workload | description | zphp (ms) | php (ms) | ratio |
|---|---|---:|---:|---:|
| fib | recursive fibonacci(27) — call overhead, branching | 102 | 97 | 1.1x |
| loop | 30M iteration integer accumulation | 1278 | 488 | 2.6x |
| arrays | 500k appends + foreach sum | 83 | 99 | **0.8x** |
| strings | 100k `.` concatenations into a growing string | 1006 | 84 | 12.0x |

Fusion: hot-loop patterns compile to single instructions —
`local CMP const/local` + jump → `cmp_jmp_*`, `local += local/const`
→ `add/sub_set_local_*`, `$i++` statement → discard variant.
The loop benchmark drops from ~13 dispatched instructions per iteration to 4.

## History

| engine | fib | loop | arrays | strings |
|---|---:|---:|---:|---:|
| tree-walking interpreter | 1.7x | 7.8x | 1.5x | 11.9x |
| bytecode VM v1 | 1.1x | 8.2x | 1.4x | 12.0x |
| + top-level slot promotion | 1.1x | 4.4x | 1.0x | 11.9x |
| + instruction fusion | 1.1x | **2.6x** | **0.8x** | 12.0x |

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
