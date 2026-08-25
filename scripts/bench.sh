#!/usr/bin/env bash
# Benchmark harness: times zphp vs reference PHP on identical workloads.
#
# Usage:
#   zig build -Doptimize=ReleaseFast
#   bash scripts/bench.sh [reps]
#
# Each workload runs N times for both interpreters; the best (min) wall time
# is reported, following common benchmarking practice.

set -euo pipefail

ZPHP="${ZPHP:-zig-out/bin/zphp}"
PHP="${PHP:-php}"
REPS="${1:-5}"
BENCH_DIR="$(cd "$(dirname "$0")/../bench" && pwd)"

time_run() {
    # $1 = command; prints best of REPS wall-clock ms.
    local best=999999999
    for _ in $(seq "$REPS"); do
        local s e ms
        s=$(date +%s%N)
        "$@" > /dev/null
        e=$(date +%s%N)
        ms=$(( (e - s) / 1000000 ))
        if [ "$ms" -lt "$best" ]; then best=$ms; fi
    done
    echo "$best"
}

printf '%-12s %10s %10s %8s\n' "workload" "zphp(ms)" "php(ms)" "ratio"
for f in fib loop arrays strings; do
    zt=$(time_run "$ZPHP" "$BENCH_DIR/$f.php")
    pt=$(time_run "$PHP" -d opcache.enable_cli=1 "$BENCH_DIR/$f.php")
    ratio=$(python -c "print(f'{$zt/$pt:.1f}x')" 2>/dev/null || echo "?")
    printf '%-12s %10d %10d %8s\n' "$f" "$zt" "$pt" "$ratio"
done
