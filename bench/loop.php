<?php
// Tight loop: integer add + compare + local variable traffic.
$sum = 0;
for ($i = 0; $i < 30000000; $i++) {
    $sum += $i;
}
echo $sum, "\n";
