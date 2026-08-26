<?php
// JIT benchmark: user-defined functions (eligible for baseline compilation).

// 1. Pure int loop — the tier-1 sweet spot.
function sumTo($n) {
    $s = 0;
    for ($i = 0; $i < $n; $i++) {
        $s += $i;
    }
    return $s;
}

// 2. Arithmetic mix: mul/sub/compare + branch.
function mix($n) {
    $s = 0;
    for ($i = 0; $i < $n; $i++) {
        $d = $i - $n / 2;
        if ($d < 0) {
            $s += $i * 3;
        } else {
            $s -= $i;
        }
    }
    return $s;
}

// 3. Many small calls (call overhead dominates; NOT jitted — control group).
function addOne($x) { return $x + 1; }

$t0 = microtime(true);
echo sumTo(30000000), "|";
echo mix(20000000), "|";
$s = 0;
for ($i = 0; $i < 5000000; $i++) { $s = addOne($s); }
echo $s, "|";
echo round((microtime(true) - $t0) * 1000), "\n";
