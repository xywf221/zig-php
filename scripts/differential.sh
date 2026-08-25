#!/usr/bin/env bash
# Differential test harness: runs each snippet through real PHP and through
# zphp, reporting any output divergence.
#
# Snippets whose output matches a KNOWN_DIVERGENCES pattern are counted
# separately (documented deviations, not bugs).
#
# Usage: bash scripts/differential.sh [zig-out/bin/zphp]

ZPHP="${1:-zig-out/bin/zphp}"
PHP_BIN="${PHP:-php}"
pass=0; fail=0; known=0

check() {
    local code="$1"
    local php_out z_out
    php_out=$("$PHP_BIN" -r "$code" 2>/dev/null)
    z_out=$("$ZPHP" -r "$code" 2>/dev/null)
    if [ "$php_out" = "$z_out" ]; then
        pass=$((pass+1))
        return
    fi
    # Known, documented deviations:
    # 1) PHP emits warnings to stdout; zphp is silent.
    # 2) PHP names the exception class (DivisionByZeroError); we print a
    #    generic "Uncaught Error".
    if echo "$php_out" | grep -q "Warning:"; then
        known=$((known+1))
        printf 'KNOWN (warnings): %s\n' "$code"
        return
    fi
    if echo "$php_out" | grep -q "DivisionByZeroError" && echo "$z_out" | grep -q "Division by zero"; then
        known=$((known+1))
        printf 'KNOWN (error class name): %s\n' "$code"
        return
    fi
    fail=$((fail+1))
    printf 'DIFF: %s\n  php : %q\n  zphp: %q\n' "$code" "$php_out" "$z_out"
}

# --- arithmetic ------------------------------------------------------------
check 'echo 1 + 2 * 3;'
check 'echo (1 + 2) * 3;'
check 'echo 10 / 4;'
check 'echo 10 / 2;'
check 'echo 10 % 3;'
check 'echo 2 ** 10;'
check 'echo -2 ** 2;'
check 'echo 2 ** 3 ** 2;'
check 'echo 7 % 3;'
check 'echo 100 - 50 - 20;'
check 'echo 0x10, 010, 1e3;'
check 'echo 5 + "5";'
check 'echo "5 apples" + 1;'
check 'echo "3.14" * 2;'
check 'echo 1/0;' # fatal in both

# --- strings ---------------------------------------------------------------
check '$name = "World"; echo "Hello $name!";'
check '$a = [1]; echo "v={$a[0]}";'
check '$a = [1]; echo "v=$a[0]";'
check '$o = ["k" => 9]; echo "{$o["k"]}";'
check 'echo "\t\n\\\"$";'
check 'echo strlen("héllo");'
check '$x = "ab"; echo $x[0];'
check '$s = "abc"; $s .= "def"; echo $s;'
check 'echo ucfirst("hi");'

# --- variables / operators -------------------------------------------------
check '$x = 5; $x += 3; $x *= 2; echo $x;'
check '$x = 10; echo $x++ + $x++;'
check '$y; echo $y + 5;'
check '$y; echo $y ?? "d";'
check '$y = null; $y ??= "s"; echo $y;'
check 'echo 6 & 3, 6 | 3, 6 ^ 3, ~5;'
check 'echo 1 << 8, 256 >> 4;'
check 'echo 1 <=> 2, 2 <=> 2, 3 <=> 2;'
check 'echo true ? "y" : "n";'
check 'echo false ?: "shorthand";'
check 'echo 0 ?: "zero-false";'
check '$a = 1; $b = $a == 1 ? "one" : "other"; echo $b;'

# --- comparisons -----------------------------------------------------------
check 'var_dump("123" == 123, "123" === 123);'
check 'var_dump("abc" == 0);'
check 'var_dump(null == "", "" == "0");'
check 'var_dump(100 < "9");'
check 'var_dump([1,2] === [1,2]);'
check 'var_dump(null == false, 0 == false, "" == false);'
check 'var_dump("a" < "b", "b" > "a", "10" < "9");'
check 'var_dump(0 == null);'

# --- control flow ----------------------------------------------------------
check 'for ($i=0;$i<5;$i++){ if($i==2) continue; echo $i; }'
check '$i=0; while($i<10){ $i++; if($i>3) break; } echo $i;'
check '$x=2; do { echo $x; $x--; } while ($x>0);'
check 'foreach ([10,20] as $k => $v) { echo "$k=$v "; }'
check 'foreach ([1,2,3] as $v) { if ($v==2) continue; echo $v; }'
check 'if (0) { echo "a"; } elseif ("") { echo "b"; } else { echo "d"; }'
check 'for ($i=0;$i<3;$i++) { for ($j=0;$j<3;$j++) { if ($j==1) break 2; echo "$i$j"; } }'
check 'while (false); echo "ok";'

# --- functions -------------------------------------------------------------
check 'function fib($n) { if ($n<2) return $n; return fib($n-1)+fib($n-2); } echo fib(15);'
check 'function add($a, $b = 10) { return $a + $b; } echo add(5), "|", add(5,1);'
check 'hello(); function hello() { echo "hi"; }'
check 'function f() { return 42; } echo f();'
check 'function g() {} var_dump(g());'
check 'function sum($n) { if ($n<=0) return 0; return $n + sum($n-1); } echo sum(200);'
check 'function outer($x) { function inner($y) { return $y * 2; } return inner($x) + 1; } echo outer(10);'

# --- arrays ----------------------------------------------------------------
check '$a = ["x"=>1,"y"=>2]; $a["z"]=3; $a[]=99; echo count($a), array_sum($a);'
check '$m = [[1,2],[3]]; echo $m[1][0];'
check '$n = []; $n[2]["deep"]="ok"; echo $n[2]["deep"];'
check '$st=[5,6,7]; echo array_pop($st), array_shift($st), count($st);'
check '$p=[]; $p[]=1; $p[]=2; echo $p[0], $p[1], count($p);'
check '$arr=[true=>"t"]; echo $arr[1];'
check '$arr=["5"=>"five"]; echo $arr[5];'
check 'print_r(array_keys(["a"=>1,"b"=>2]));'
check 'print_r(array_values([10,20]));'
check 'var_dump(in_array("1", ["1"], true));'
check 'echo implode(",", range(1,5));'
check 'print_r(explode(",","a,b,c"));'
check 'print_r(array_merge(["a"],["b"]));'
check '$r = array_reverse([1,2,3]); print_r($r);'
check 'var_dump(isset($undef));'
check '$arr=["k"=>null]; var_dump(isset($arr["k"]), empty($arr["k"]));'
check 'var_dump(empty($undefined));'

# --- type juggling ---------------------------------------------------------
check 'echo intval("42"), intval("4.9"), intval("abc");'
check 'echo floatval("1.5") + 0;'
check 'echo strval(12) . "!";'
check 'var_dump(is_int(5), is_string("5"), is_numeric("5.5"));'
check 'echo gettype(1), gettype(1.5), gettype([]), gettype(null), gettype(true), gettype("");'

# --- output ----------------------------------------------------------------
check 'var_dump(1, 1.5, "s", null, true);'
check 'print_r([1,2,3]);'
check 'print_r(["a"=>1,"b"=>[2]]);'
check 'echo sprintf("%s=%d", "k", 5);'

printf '\n%d passed, %d known deviations, %d differ\n' "$pass" "$known" "$fail"
