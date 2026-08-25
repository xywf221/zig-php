<?php
// Array write path: auto-vivification-free appends and key writes.
$a = [];
for ($i = 0; $i < 500000; $i++) {
    $a[] = $i;
}
$s = 0;
foreach ($a as $k => $v) {
    $s += $v;
}
echo $s, "\n";
