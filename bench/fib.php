<?php
// Recursive Fibonacci — exercises call overhead, branching, arithmetic.
function fib($n) {
    if ($n < 2) return $n;
    return fib($n - 1) + fib($n - 2);
}
echo fib(27), "\n";
