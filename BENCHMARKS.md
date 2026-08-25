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

## Results (2025, initial tree-walking interpreter)

| workload | description | zphp (ms) | php (ms) | ratio |
|---|---|---:|---:|---:|
| fib | recursive fibonacci(27) — call overhead, branching | 161 | 97 | 1.7x |
| loop | 30M iteration integer accumulation | 3935 | 507 | 7.8x |
| arrays | 500k appends + foreach sum | 151 | 101 | 1.5x |
| strings | 100k `.` concatenations into a growing string | 1035 | 87 | 11.9x |

## Notes

- The gap comes from architecture, not micro-inefficiency: zphp walks the AST
  and re-dispatches on tagged unions every node visit, while PHP compiles to
  a register-style VM with specialized handlers.
- String workloads pay double: each `.` allocates a fresh arena string
  (O(n^2) total for repeated append), same asymptotics as PHP but without
  its internal optimizations (e.g. target-string reuse in CONCAT ops).
- Array performance is competitive because ordered-dict operations map well
  onto an entry list with a next-index fast path.

## Planned improvements

1. Constant folding + AST reuse won't close the loop gap; a bytecode VM will:
   compile once, dispatch a flat switch over u8 opcodes, keep values in a
   stack slots array (removes per-node union tag checks and pointer chasing).
2. Rope/string-builder representation for `.=` accumulation.
3. Optional interned-key hash index for large assoc arrays (currently linear
   scan on non-append writes).
