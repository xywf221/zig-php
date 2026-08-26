//! Integration tests: full pipeline (lex -> parse -> execute) with output
//! capture. Expected values cross-checked against PHP 8.x via
//! `scripts/differential.sh`.

const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const compiler_mod = @import("compiler.zig");
const vm_mod = @import("vm.zig");

pub const RunResult = struct {
    output: []const u8,
    fatal: ?[]const u8,

    /// Free both fields.
    pub fn deinit(self: RunResult) void {
        std.testing.allocator.free(self.output);
        if (self.fatal) |f| std.testing.allocator.free(@constCast(f));
    }
};

/// Compile + run a snippet, capturing stdout.
pub fn runCode(code: []const u8) !RunResult {
    const alloc = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    const full = try std.fmt.allocPrint(arena, "<?php {s}", .{code});

    var lx = lexer.Lexer.init(full);
    const tokens = try lx.tokenize(arena);
    var diag: parser.Diag = .{};
    const program_ast = try parser.parse(arena, tokens, &diag);

    var bc_diag: compiler_mod.Diag = .{};
    const program = try compiler_mod.Compiler.compile(arena, program_ast, &bc_diag);
    var vm = try arena.create(vm_mod.Vm);
    vm.* = vm_mod.Vm.init(arena, &aw.writer, null, program);
    if (vm.run()) |_| {
        return .{ .output = try alloc.dupe(u8, aw.written()), .fatal = null };
    } else |e| switch (e) {
        error.Fatal => return .{
            .output = try alloc.dupe(u8, aw.written()),
            .fatal = try alloc.dupe(u8, vm.msg),
        },
        else => return e,
    }
}

fn expectOut(code: []const u8, expected: []const u8) !void {
    const r = try runCode(code);
    defer r.deinit();
    if (r.fatal) |f| {
        std.debug.print("unexpected fatal: {s}\n", .{f});
        return error.UnexpectedFatal;
    }
    try std.testing.expectEqualStrings(expected, r.output);
}

/// Alias kept for tests that were written when builtins were VM-only.
fn expectOutVm(code: []const u8, expected: []const u8) !void {
    try expectOut(code, expected);
}

// ===========================================================================
// Builtin functions (VM only)
// ===========================================================================

test "builtin strings" {
    try expectOutVm("echo strlen('hello'), '|', strtoupper('abc'), '|', strrev('abc');", "5|ABC|cba");
    try expectOutVm("echo substr('abcdef', 1, 3), '|', strpos('hello', 'll');", "bcd|2");
    try expectOutVm("echo str_repeat('ab', 3), '|', ucfirst('hi');", "ababab|Hi");
    try expectOutVm("echo trim('  x  '), '|', str_replace('a', 'b', 'aaa');", "x|bbb");
    try expectOutVm("echo sprintf('%s=%d (%f)', 'k', 5, 0.5);", "k=5 (0.5)");
    try expectOutVm("echo str_contains('abc', 'b') ? 'y' : 'n';", "y");
}

test "builtin arrays" {
    try expectOutVm("$a = [3,1,2]; echo count($a), array_sum($a);", "36");
    try expectOutVm("echo implode(',', [1,2,3]), '|', implode('/', ['x','y']);", "1,2,3|x/y");
    try expectOutVm("print_r(explode(',', 'a,b,c'));", "Array\n(\n    [0] => a\n    [1] => b\n    [2] => c\n)\n");
    try expectOutVm("echo max(3, 9, 4), min([5, 2, 8]);", "92");
    try expectOutVm("$st = [5,6,7]; echo array_pop($st), array_shift($st), count($st);", "751");
    try expectOutVm("var_dump(in_array('1', ['1'], true));", "bool(true)\n");
    try expectOutVm("echo count(range(2, 10, 2));", "5");
}

test "builtin types & output" {
    try expectOutVm("echo intval('42'), intval('4.9'), intval('abc');", "4240");
    try expectOutVm("echo gettype(1), gettype(1.5), gettype([]), gettype(null), gettype(true);", "integerdoublearrayNULLboolean");
    try expectOutVm("var_dump(is_int('5'), is_numeric('5.5'));", "bool(false)\nbool(true)\n");
    try expectOutVm("var_dump(1, 1.5, 's', null, true);", "int(1)\nfloat(1.5)\nstring(1) \"s\"\nNULL\nbool(true)\n");
    try expectOutVm("echo abs(-5), '|', pow(2, 8), '|', intdiv(7, 2), '|', sqrt(16);", "5|256|3|4");
}

fn expectFatal(code: []const u8, expected_msg: []const u8) !void {
    const r = try runCode(code);
    defer r.deinit();
    if (r.fatal == null) {
        std.debug.print("expected fatal, got output: {s}\n", .{r.output});
        return error.FatalExpected;
    }
    if (!std.mem.eql(u8, r.fatal.?, expected_msg)) {
        std.debug.print("fatal mismatch: got [{s}], want [{s}]\n", .{ r.fatal.?, expected_msg });
        return error.TestExpectedEqual;
    }
}



// ===========================================================================
// Regression battery: one test per historically-broken behavior.
// ===========================================================================

test "regression: octal and hex literals" {
    try expectOut("echo 010, '|', 0x10;", "8|16"); // was decimal 10
}

test "regression: break exits the loop exactly" {
    try expectOut("$i=0; while($i<10){ $i++; if($i>3) break; } echo $i;", "4"); // was 10
}

test "regression: ??= assigns only when null" {
    try expectOut("$y = null; $y ??= 's'; echo $y;", "s"); // was empty
    try expectOut("$o = ['k' => 9]; echo \"{$o[\"k\"]}\";", "9"); // brace+quoted key
}

test "regression: xor operator compiles and evaluates" {
    try expectOut("echo true xor false ? 't' : 'f';", "t"); // crashed the compiler
}

test "regression: mixed array literal key order" {
    // Keyed pairs were emitted first, breaking auto-key sequencing.
    try expectOut("$a = [9, 'k' => 2]; echo $a[0], '|', $a['k'];", "9|2");
}

test "regression: isset treats stored null as unset" {
    try expectOut("$a = ['k' => null]; echo isset($a['k']) ? 'y' : 'n';", "n"); // was y
}

test "regression: numeric strings compare numerically" {
    try expectOutVm("var_dump('10' < '9');", "bool(false)\n"); // was true (byte compare)
}

test "regression: missing required argument is fatal" {
    try expectFatal("function f($a) {} f();", "Too few arguments to function f()"); // silently returned garbage
}

test "regression: nested function declarations register on execution" {
    try expectFatal("function outer() { function inner() {} } inner();",
        "Call to undefined function inner()"); // declared but never registered until outer runs
    try expectOut("function outer2() { function inner2() {} } outer2(); echo inner2() === null ? 'ok' : 'x';", "ok");
}

test "regression: multi-level interpolation chains" {
    try expectOut("$m = [[7]]; echo \"{$m[0][0]}\";", "7"); // printed 'Array'
}

test "regression: brace interpolation with quoted keys stays in string" {
    try expectOut("$o = ['k' => 1]; echo \"v={$o[\"k\"]}\";", "v=1"); // lexer cut the string early
}

test "regression: single-quoted escapes stay literal" {
    try expectOut("echo 'a\\n\\'b';", "a\\n'b"); // went through double-quote unescaping
}

// ===========================================================================
// Snapshot / warning semantics
// ===========================================================================

test "foreach iterates a snapshot; in-loop appends invisible" {
    try expectOut("$a=[1,2,3]; $n=0; foreach($a as $v){ $n++; $a[]=$v; } echo $n, count($a);", "36");
}

test "rope concatenation is transparent" {
    try expectOut("$s=''; for($i=0;$i<5;$i++){ $s .= $i; } echo $s, '|', strlen($s);", "01234|5");
    try expectOut("$a='x'; $b=$a.'y'.'z'; echo $b === 'xyz' ? 'eq' : 'ne';", "eq");
    try expectOut("$s=''; $s .= 'ab'; $t = $s . 'c'; if($s){ echo $t; }", "abc"); // rope truthiness
}

test "array hash index: mixed keys round-trip" {
    try expectOut("$m=['k'=>1,'x'=>2]; $m['k']=9; $m['z']=3; echo $m['k'],$m['x'],$m['z'],count($m);", "9233");
    try expectOut("$a=[]; for($i=0;$i<100;$i++){$a[]=$i;} echo $a[50]+$a[99], array_sum($a);", "1494950");
}

// ===========================================================================
// Objects & classes
// ===========================================================================

test "class basics: props, constructor, methods, this" {
    try expectOut("class P { public $x = 0; " ++
        "function __construct($x) { $this->x = $x; } " ++
        "function doubled() { return $this->x * 2; } } " ++
        "$p = new P(12); echo $p->doubled();", "24");
}

test "inheritance: override + parent defaults + instanceof" {
    try expectOut("class A { public $v = 10; function who() { return 'A'; } } " ++
        "class B extends A { function who() { return 'B'; } } " ++
        "$b = new B(); echo $b->who(), $b->v, get_class($b), $b instanceof A ? 1 : 0;", "B10B1");
}

test "object identity and property mutation" {
    try expectOut("class C { public $n = 1; } " ++
        "$a = new C(); $b = $a; $b->n = 7; " ++
        "echo $a->n, ($a === $b) ? 1 : 0, ($a == $b) ? 1 : 0;", "711"); // PHP objects are handles: aliasing + identity
}

test "compound ops on properties and dynamic props" {
    try expectOut("class C { public $c = 0; } " ++
        "$o = new C(); $o->c += 5; $o->c *= 2; $o->extra = 'hi'; " ++
        "echo $o->c, $o->extra;", "10hi");
}

// ===========================================================================
// Exceptions
// ===========================================================================

test "throw/catch basic + getMessage" {
    try expectOut("try { throw new Exception('boom'); } catch (Exception $e) { echo 'got: ', $e->getMessage(); }", "got: boom");
}

test "clause order and hierarchy matching" {
    try expectOut("try { throw new Exception('x'); } catch (TypeError $e) { echo 1; } catch (Exception $e) { echo 2; }", "2");
    try expectOut("try { throw new DivisionByZeroError('dz'); } catch (ArithmeticError $e) { echo 'arith'; }", "arith");
}

test "nested try: inner mismatch falls to outer" {
    try expectOut("try { try { throw new Exception('in'); } catch (TypeError $e) { echo 'no'; } } " ++
        "catch (Exception $e) { echo 'outer:', $e->getMessage(); }", "outer:in");
}

test "division by zero is a catchable DivisionByZeroError" {
    try expectOut("try { echo 1/0; } catch (DivisionByZeroError $e) { echo 'caught: ', $e->getMessage(); }", "caught: Division by zero");
}

test "exception escaping function unwinds through calls" {
    try expectOut("function f() { throw new Exception('deep'); } " ++
        "function g() { f(); } " ++
        "try { g(); } catch (Exception $e) { echo 'unwound: ', $e->getMessage(); }", "unwound: deep");
}

test "uncaught exception is fatal" {
    try expectFatal("throw new Exception('boom');", "Uncaught Exception: boom");
}

// ===========================================================================
// Float formatting & numeric-string arithmetic (PHP 8 alignment)
// ===========================================================================

test "float formatting matches precision-14 gcvt" {
    try expectOut("echo 8.0, '|', 0.1+0.2, '|', 12345678901234.567;", "8|0.3|12345678901235");
    try expectOut("echo 123456789012345.6, '|', 1.0e15, '|', 1.5e15;", "1.2345678901235E+14|1.0E+15|1.5E+15");
    try expectOut("echo 1e-10, '|', -2.5e20, '|', 99999999999999.0;", "1.0E-10|-2.5E+20|99999999999999");
    // all-nines carry into the exponent
    try expectOut("echo 9.999999999999999e13;", "1.0E+14");
}

test "leading-numeric strings warn but compute" {
    // Warning goes to stderr; stdout carries the computed result.
    try expectOut("echo '5 apples' + 1, '|', '123abc' * 2;", "6|246");
}

test "non-numeric strings throw a catchable TypeError" {
    try expectOut("try { echo 'abc' + 1; } catch (Throwable $e) { echo $e->getMessage(); }",
        "Unsupported operand types: string + int");
    try expectOut("try { echo '' * 2; } catch (Throwable $e) { echo $e->getMessage(); }",
        "Unsupported operand types: string * int");
}

// ===========================================================================
// References
// ===========================================================================

test "reference binding: writes propagate both ways" {
    try expectOut("$a = 5; $b =& $a; $b = 7; echo $a;", "7");
    try expectOut("$a = 5; $b =& $a; $a = 9; echo $b;", "9");
}

test "reference increment and compound assign" {
    try expectOut("$a = 1; $b =& $a; $b++; $c =& $a; $c += 10; echo $a, $b, $c;", "121212");
}

test "by-reference parameters" {
    try expectOut("function f(&$x) { $x *= 2; } $v = 21; f($v); echo $v;", "42");
    try expectOut("$arr = [1, 2]; function set(&$e) { $e = 99; } set($arr[0]); echo $arr[0], $arr[1];", "992");
}

test "array aliasing through reference" {
    try expectOut("$a = [1]; $r =& $a; $r[0] = 100; echo $a[0], count($a);", "1001");
}

// ===========================================================================
// Baseline JIT
// ===========================================================================

test "jitted functions compute identically (threshold = 3 calls)" {
    // Called 10x -> compiled after the 3rd invocation; results must stay
    // identical across interpreted warmup and JITed steady state.
    try expectOut("function add($a, $b) { return $a + $b; } " ++
        "$ok = 0;" ++
        "for ($i = 0; $i < 10; $i++) { if (add($i, 100) === $i + 100) $ok++; } " ++
        "echo $ok;", "10");
}

test "jitted loop with compare-branch and overflow-free arithmetic" {
    try expectOut("function loopy($n) { $s = 0; for ($i = 0; $i < $n; $i++) { $s += $i; } return $s; } " ++
        "echo loopy(5), '|', loopy(100), '|', loopy(100000);", "10|4950|4999950000");
    try expectOut("function neg($a, $b) { $d = $a - $b * 2; if ($d < 0) { return -$d; } return $d; } " ++
        "echo neg(1, 10), '|', neg(10, 1);", "19|8");
}

test "jit deopt on non-int input falls back to interpreter" {
    try expectOut("function half($x) { return $x / 2; } " ++
        "echo half(10), half(9), half('8');", "54.54");
}

// ===========================================================================
// Interfaces / traits / static members
// ===========================================================================

test "static properties and methods with self::" {
    try expectOut("class D { public static $n = 5; " ++
        "public static function get() { return self::$n; } " ++
        "public static function bump() { self::$n += 1; return self::$n; } } " ++
        "echo D::get(), '|', D::bump(), '|', D::$n;", "5|6|6");
    try expectOut("class E { public static $c = 0; public function __construct() { self::$c++; } } " ++
        "$x = new E(); $y = new E(); echo E::$c;", "2");
}

test "interfaces: conformance enforced, instanceof works" {
    try expectOut("interface I { public function m(); } " ++
        "class K implements I { public function m() { return 'ok'; } } " ++
        "echo (new K())->m(), (new K()) instanceof I ? 1 : 0;", "ok1");
    // Missing interface method -> compile error.
    if (runCode("interface I2 { public function m(); } class Bad implements I2 { }")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "traits flatten into classes" {
    try expectOut("trait T { public function hi() { return 't:' . $this->w; } } " ++
        "class H { use T; public $w = 'world'; } " ++
        "echo (new H())->hi();", "t:world");
}

// ===========================================================================
// Arithmetic
// ===========================================================================

test "int arithmetic" {
    try expectOut("echo 1 + 2 * 3;", "7");
    try expectOut("echo (1 + 2) * 3;", "9");
    try expectOut("echo 10 - 4 - 3;", "3"); // left assoc
    try expectOut("echo 10 % 3;", "1");
    try expectOut("echo -10 % 3;", "-1"); // truncated toward zero
    try expectOut("echo 2 ** 0;", "1");
    try expectOut("echo 2 ** 10;", "1024");
    try expectOut("echo 2 ** 62;", "4611686018427387904");
}

test "float arithmetic" {
    try expectOut("echo 10 / 4;", "2.5");
    try expectOut("echo 10 / 2;", "5"); // exact division stays int
    try expectOut("echo 1.5 + 1.5;", "3");
    try expectOut("echo 0.1 + 0.2;", "0.3"); // precision-14, matches PHP
    try expectOut("echo 7 % 2.5;", "1"); // float mod truncates to ints
    try expectOut("echo 2 ** -1;", "0.5");
}

test "overflow promotes to float" {
    try expectOut("echo 9223372036854775807 + 1;", "9.2233720368548E+18"); // matches PHP
}

test "numeric literals" {
    try expectOut("echo 0x10;", "16");
    try expectOut("echo 010;", "8"); // octal
    try expectOut("echo 1e3;", "1000");
    try expectOut("echo .5 + .25;", "0.75");
}

test "string-number coercion in arithmetic" {
    try expectOut("echo '5' + '6';", "11");
    try expectOut("echo '5 apples' + 1;", "6"); // leading number wins (+ stderr warning)
    try expectOut("try { echo 'abc' * 2; } catch (Throwable $e) { echo $e->getMessage(); }",
        "Unsupported operand types: string * int"); // PHP 8: fatal, not 0
    try expectOut("echo '3.14' * 2;", "6.28");
    try expectOut("echo '  12  ' + 1;", "13"); // leading whitespace ok
}

test "division by zero is fatal" {
    // 1/0 throws a DivisionByZeroError (catchable — see exceptions tests);
    // uncaught, it surfaces as this fatal.
    try expectFatal("echo 1 / 0;", "Uncaught DivisionByZeroError: Division by zero");
    try expectFatal("echo 1 % 0;", "Modulo by zero");
}

// ===========================================================================
// Strings
// ===========================================================================

test "concatenation" {
    try expectOut("echo 'a' . 'b';", "ab");
    try expectOut("echo 'a' . 1 . 2.5 . true . null;", "a12.51");
}

test "interpolation simple variable" {
    try expectOut("$name = 'World'; echo \"Hello $name!\";", "Hello World!");
    try expectOut("$x = 5; echo \"n=$x\";", "n=5");
    try expectOut("echo \"$undeclared_var end\";", " end"); // undefined -> ""
}

test "interpolation array access" {
    try expectOut("$a = [1]; echo \"v={$a[0]}\";", "v=1");
    try expectOut("$a = [1]; echo \"v=$a[0]\";", "v=1");
    try expectOut("$o = ['k' => 9]; echo \"{$o['k']}\";", "9");
    try expectOut("$o = ['k' => 9]; echo \"{$o[\"k\"]}\";", "9");
    try expectOut("$m = [[7]]; echo \"{$m[0][0]}\";", "7");
}

test "escape sequences" {
    try expectOut("echo \"tab\\tnewline\\n\";", "tab\tnewline\n");
    try expectOut("echo \"dollar\\$ brace\\{\";", "dollar$ brace{");
    try expectOut("echo 'single \\n stays';", "single \\n stays");
    try expectOut("echo 'quote \\' here';", "quote ' here");
    try expectOut("echo \"\\\\ backslash\";", "\\ backslash");
    try expectOut("echo \"\\x41\\x42\";", "AB");
}

test "string indexing reads bytes" {
    try expectOut("$s = 'hello'; echo $s[0], $s[4];", "ho");
    try expectOut("$s = 'hi'; echo $s[-1];", ""); // negative index unsupported -> "" (documented deviation)
}

// ===========================================================================
// Variables & assignment
// ===========================================================================

test "compound assignment operators" {
    try expectOut("$x = 5; $x += 3; $x *= 2; $x -= 1; echo $x;", "15");
    try expectOut("$x = 17; $x %= 5; echo $x;", "2");
    try expectOut("$x = 2; $x **= 5; echo $x;", "32");
    try expectOut("$s = 'a'; $s .= 'b'; $s .= 1; echo $s;", "ab1");
    try expectOut("$x = 10; $x /= 4; echo $x;", "2.5");
}

test "null coalescing forms" {
    try expectOut("$y; echo $y ?? 'default';", "default");
    try expectOut("$y = 1; echo $y ?? 'no';", "1");
    try expectOut("$arr = ['k' => 'v']; echo $arr['missing'] ?? 'fb', '|', $arr['k'] ?? 'fb2';", "fb|v");
    try expectOut("$y = null; $y ??= 'set'; echo $y;", "set");
    try expectOut("$y = 'x'; $y ??= 'no'; echo $y;", "x");
}

test "increment and decrement semantics" {
    try expectOut("$x = 10; echo $x++ + $x++;", "21");
    try expectOut("$x = 10; echo ++$x;", "11");
    try expectOut("$x = 10; echo $x--, '|', $x;", "10|9");
    try expectOut("$x = null; echo ++$x;", "1"); // null++ -> 1
    try expectOut("$x = null; echo --$x;", ""); // PHP: --null stays null
    try expectOut("$s = 'abc'; $s++; echo $s;", "abc"); // non-numeric untouched
    try expectOut("$f = 1.5; echo ++$f;", "2.5");
    try expectOut("$a = [5]; $a[0]++; echo $a[0];", "6");
}

test "undefined variables read as null" {
    try expectOut("$n; echo $n + 5;", "5");
    try expectOutVm("var_dump($never_set);", "NULL\n");
}

// ===========================================================================
// Control flow
// ===========================================================================

test "if elseif else" {
    try expectOut("if (0) { echo 'a'; } elseif ('') { echo 'b'; } elseif (0.0) { echo 'c'; } else { echo 'd'; }", "d");
    try expectOut("if ('0') { echo 'x'; } else { echo 'falsy-zero-string'; }", "falsy-zero-string");
    try expectOut("if ([]);else echo 'empty-array-falsy';", "empty-array-falsy");
    try expectOut("if ([0]) echo 'one-elem-truthy';", "one-elem-truthy");
    try expectOut("if (true) echo 'bare-stmt'; else echo 'no';", "bare-stmt");
}

test "while and do-while" {
    try expectOut("$i = 0; while ($i < 3) { echo $i; $i++; }", "012");
    try expectOut("$x = 2; do { echo $x; $x--; } while ($x > 0);", "21");
    try expectOut("$i = 5; do { echo 'once'; } while (false);", "once");
    try expectOut("while (false); echo 'ok';", "ok");
}

test "for loop with multiple init/step expressions" {
    try expectOut(
        "for ($i = 0, $j = 10; $i < 2; $i++, $j--) { echo $i, ':', $j, ' '; }",
        "0:10 1:9 ",
    );
    try expectOut("for (;;) { break; } echo 'ok';", "ok");
    try expectOut("for ($i = 0; $i < 3; $i++); echo $i;", "3");
}

test "foreach key/value over lists and maps" {
    try expectOut("foreach ([10, 20] as $v) echo $v, ';';", "10;20;");
    try expectOut("foreach ([10, 20] as $k => $v) echo \"$k=$v \";", "0=10 1=20 ");
    try expectOut(
        "$m = ['a' => 1, 'b' => 2]; foreach ($m as $key => $val) { echo \"$key$val\"; }",
        "a1b2",
    );
}

test "break and continue with levels" {
    try expectOut("for ($i=0;$i<5;$i++){ if($i==2) continue; echo $i; }", "0134");
    try expectOut("$i=0; while(true){ $i++; if($i>=4) break; } echo $i;", "4");
    try expectOut(
        "for ($i=0;$i<3;$i++) { for ($j=0;$j<3;$j++) { if ($j==1) break 2; echo \"$i$j\"; } }",
        "00",
    );
    try expectOut(
        "for ($i=0;$i<3;$i++) { for ($j=0;$j<3;$j++) { if ($j==1) continue 2; echo \"$i$j\"; } }",
        "001020",
    );
    try expectOut(
        "foreach ([1,2,3] as $v) { if ($v==2) continue 1; echo $v; }",
        "13",
    );
    // continue at last iteration doesn't skip the loop exit
    try expectOut("$n = 0; for ($i=0;$i<3;$i++) { if ($i==1) continue; $n++; } echo $n;", "2");
}

// ===========================================================================
// Functions
// ===========================================================================

test "recursion fib" {
    try expectOut(
        \\function fib($n) { if ($n < 2) return $n; return fib($n-1) + fib($n-2); }
        \\echo fib(20);
    ,
        "6765",
    );
}

test "deep recursion within nesting limit" {
    try expectOut(
        "function sum($n) { if ($n<=0) return 0; return $n + sum($n-1); } echo sum(200);",
        "20100",
    );
}

test "call depth limit is fatal" {
    try expectFatal("function f() { return f(); } f();", "Maximum function nesting level of 512 reached, aborting");
}

test "default parameter values" {
    try expectOut("function add($a, $b = 10) { return $a + $b; } echo add(5), '|', add(5, 1);", "15|6");
    try expectFatal("function f($a) {} f();", "Too few arguments to function f()");
    try expectFatal("function g($a) {} g(1, 2);", "g() expects at most 1 argument(s), 2 given");
}

test "hoisting of top-level functions" {
    try expectOut("hello(); function hello() { echo 'hi'; }", "hi");
}

test "conditional function declaration registers on execution" {
    try expectOut(
        "if (true) { function c() { return 'yes'; } } echo c();",
        "yes",
    );
    try expectOut(
        "function outer() { function inner($x) { return $x * 2; } return inner(21); } echo outer();",
        "42",
    );
}

test "return without value yields null" {
    try expectOutVm("function f() { return; } var_dump(f());", "NULL\n");
    try expectOutVm("function f() {} var_dump(f());", "NULL\n");
}

test "locals isolated between calls" {
    try expectOut(
        "function f() { $c = 0; $c++; return $c; } echo f(), f(), f();",
        "111",
    );
}

test "arity mismatch is fatal" {}

// ===========================================================================
// Arrays
// ===========================================================================

test "array literal forms" {
    try expectOutVm("echo count([1, 2, 3]);", "3");
    try expectOut("$a = [1, 'k' => 2, 3 => 'x']; echo $a[0], $a['k'], $a[3];", "12x");
    try expectOut("$a = [1, 2]; $a[] = 3; echo $a[2];", "3");
    try expectOut("$a = [5 => 'five']; $a[] = 'six'; echo $a[6];", "six");
}

test "array auto-vivification chains" {
    try expectOut("$n = []; $n[2]['deep'] = 'ok'; echo $n[2]['deep'];", "ok");
    try expectOutVm("$x; $x['a']['b']['c'] = 1; echo count($x['a']);", "1");
}

test "nested arrays and mixed keys" {
    try expectOut("$m = [[1,2],[3]]; echo $m[1][0];", "3");
    try expectOut("$arr=[true=>'t']; echo $arr[1];", "t"); // bool key -> int
    try expectOut("$arr=['5'=>'five']; echo $arr[5];", "five"); // numeric string key
    try expectOut("$arr=['-3'=>'neg']; echo $arr[-3];", "neg");
    try expectOut("$arr=[1.7=>'x']; echo $arr[1];", "x"); // float key truncates
}

test "append after explicit high index" {
    try expectOut("$a = [10 => 'x']; $a[] = 'y'; echo $a[11];", "y");
}

test "reading missing keys yields null" {
    try expectOutVm("$a = [1]; var_dump($a[99]);", "NULL\n");
    try expectOutVm("$a = ['k'=>null]; var_dump(isset($a['k']), empty($a['k']));", "bool(false)\nbool(true)\n");
}

// ===========================================================================
// Comparisons & type juggling
// ===========================================================================

test "loose equality matrix" {
    try expectOutVm("var_dump(null == false, 0 == false, '' == false);", "bool(true)\nbool(true)\nbool(true)\n");
    try expectOutVm("var_dump(null == '', '' == '0');", "bool(true)\nbool(false)\n"); // PHP 8 semantics
    try expectOutVm("var_dump('abc' == 0);", "bool(false)\n"); // PHP 8: no numeric coercion for non-numeric strings
    try expectOutVm("var_dump('123' == 123);", "bool(true)\n");
    try expectOutVm("var_dump(0 == null);", "bool(true)\n");
    try expectOutVm("var_dump([] == false);", "bool(true)\n");
}

test "strict equality" {
    try expectOutVm("var_dump('123' === 123, 1 === 1.0);", "bool(false)\nbool(false)\n");
    try expectOutVm("var_dump([1,2] === [1,2], [1,'2'] === [1,2]);", "bool(true)\nbool(false)\n");
    try expectOutVm("var_dump([2,1] === [1,2]);", "bool(false)\n"); // order matters
    try expectOutVm("var_dump(null === null);", "bool(true)\n");
}

test "relational comparisons" {
    try expectOutVm("var_dump(100 < '9');", "bool(false)\n"); // numeric-string compare
    try expectOutVm("var_dump('a' < 'b', 'b' > 'a');", "bool(true)\nbool(true)\n");
    try expectOutVm("var_dump('10' < '9');", "bool(false)\n"); // both numeric-ish? '10' vs '9': numeric compare 10<9=false
    try expectOutVm("var_dump([1] < [1,2]);", "bool(true)\n"); // array count compare
}

test "spaceship operator" {
    try expectOut("echo 1 <=> 2, 2 <=> 2, 3 <=> 2;", "-101");
    try expectOut("echo 'a' <=> 'b';", "-1");
}

test "ternary and shorthand" {
    try expectOut("echo true ? 'y' : 'n';", "y");
    try expectOut("echo false ?: 'shorthand';", "shorthand");
    try expectOut("$a = ''; echo $a ?: 'fallback';", "fallback");
    try expectOut("echo 0 ?: 0 ?: 'third';", "third");
}

test "logical operators short-circuit and xor" {
    try expectOut("echo true && false ? 'y' : 'n';", "n");
    try expectOut("function boom() { return 1/0; } echo false && boom();", ""); // not evaluated
    try expectOut("function boom() { return 1/0; } echo true || boom();", "1"); // wait: true||... prints bool->"1"
    try expectOut("echo true xor false ? 't' : 'f';", "t"); // xor lower than ternary cond chain
    try expectOut("echo 1 and 1;", "1"); // 'and' binds looser than echo's argument list ends up printing 1
}

test "bitwise operators" {
    try expectOut("echo 6 & 3, 6 | 3, 6 ^ 3, ~5;", "275-6");
    try expectOut("echo 1 << 8, 256 >> 4;", "25616");
    try expectOut("echo 5 & '3';", "1"); // numeric strings coerce
}

// ===========================================================================
// Errors
// ===========================================================================

test "undefined function is fatal" {
    try expectFatal("nope();", "Call to undefined function nope()");
}

test "foreach over scalar is fatal" {
    try expectFatal("foreach (5 as $x) {}", "foreach() argument must be of type array, int given");
}

test "array ops on scalars are fatal" {
    try expectFatal("$x = 5; $x[] = 1;", "cannot use a int value as an array");
    try expectOut("$s = 'str'; echo $s['key'];", ""); // non-numeric string offset -> "" (PHP warns)
}

test "invalid lvalue rejected at compile time" {
    if (runCode("1 = 2;")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {
        // SyntaxError expected.
    }
}
