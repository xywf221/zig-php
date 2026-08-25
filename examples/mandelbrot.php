<?php
// Mandelbrot ASCII — floats, nested loops, string building.
$rows = 16;
$cols = 60;
$out = "";
for ($y = 0; $y < $rows; $y++) {
    for ($x = 0; $x < $cols; $x++) {
        $cr = -2.0 + 3.0 * $x / $cols;
        $ci = -1.0 + 2.0 * $y / $rows;
        $zr = 0.0; $zi = 0.0; $iter = 0;
        while ($zr * $zr + $zi * $zi < 4.0 && $iter < 12) {
            $t = $zr * $zr - $zi * $zi + $cr;
            $zi = 2.0 * $zr * $zi + $ci;
            $zr = $t;
            $iter++;
        }
        $out .= $iter >= 10 ? "#" : ($iter > 6 ? "+" : ($iter > 3 ? "." : " "));
    }
    $out .= "\n";
}
echo $out;
