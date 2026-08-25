<?php
// Prime sieve — arrays, nested loops, break.
$limit = 50;
$primes = [];
for ($n = 2; $n <= $limit; $n++) {
    $isPrime = true;
    foreach ($primes as $p) {
        if ($p * $p > $n) break;
        if ($n % $p == 0) {
            $isPrime = false;
            break;
        }
    }
    if ($isPrime) $primes[] = $n;
}
echo "primes up to $limit:\n";
foreach ($primes as $p) {
    echo "$p ";
}
echo "\n";
