<?php
// String concatenation growth pattern.
$s = "";
$n = 0;
for ($i = 0; $i < 100000; $i++) {
    $s .= "x";
    $n++;
}
echo $n, "\n";
