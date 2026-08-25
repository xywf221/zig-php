# zphp — a minimal PHP interpreter written in Zig

zphp 是一个用 Zig 编写的极简 PHP 解释器，定位类似 QuickJS 之于 JavaScript：
**小、快、零依赖、单二进制**。目标是实现 PHP 8.0+ 的核心语言子集，
用于脚本执行、嵌入与学习研究——不追求完整生产级 PHP 兼容。

```php
<?php
function fib($n) {
    if ($n < 2) return $n;
    return fib($n - 1) + fib($n - 2);
}
echo fib(30), "\n";
```

```console
$ zphp fib.php
832040
```

## 特性

- **字节码编译器 + 栈式虚拟机**（另附树遍历参考引擎，双引擎一致性测试）
- 值系统：null / bool / int / float / string / array（有序字典语义）
- PHP 8 弱类型语义：truthiness、松散比较（含 PHP 8 的字符串-数字比较规则）、
  数值字符串前缀强制转换、数组键规范化（`"5"`→`5`、`true`→`1`…）
- 完整控制流：`if/elseif/else`、`while`、`do-while`、`for`、`foreach`
  （支持 `$k => $v`）、`break N` / `continue N`
- 函数：递归（深度上限 512）、常量默认参数、顶层函数提升、条件函数声明
- 双引号字符串插值：`"$var"`、`$arr[0]`、`{$m["key"]}`
- 运算符：算术、比较、逻辑（短路）、位运算、`??`、`?:`、`<=>`、`**`、
  复合赋值、前后置 `++/--`
- 错误处理：解析/编译错误带行号报告；运行期 Fatal Error 对齐 PHP 行为

## 明确不支持（PHP 8.0+ 目标之外）

- 面向对象（class/interface/trait）、引用（`&$var`）
- 旧语法：`array()` 字面量（用 `[...]`）、未定义常量降级为字符串（PHP 8 中本就是 Error）
- 生成器、闭包、命名参数、属性注解、heredoc/nowdoc
- 标准库内置函数（扩展点已预留于 `src/builtins.zig`）

## 构建

需要 Zig 0.16：

```console
zig build                              # Debug 构建
zig build -Doptimize=ReleaseFast      # 发布构建
zig build test                         # 运行测试套件
zig build run -- script.php            # 构建并运行
```

## 用法

```console
zphp script.php            # 运行脚本文件（字节码 VM）
zphp --tree script.php     # 使用树遍历参考引擎
zphp -r 'echo 1 + 2;'     # 执行内联代码
zphp -v                    # 版本
```

退出码：`0` 正常；`255` PHP Fatal Error / 解析错误；`2` 用法错误。

## 测试

四层测试体系：

| 层 | 文件 | 内容 |
|---|---|---|
| 词法单元测试 | `src/test_lexer.zig` | 全操作符、数字/字符串字面量、注释、行号、错误路径 |
| 语法单元测试 | `src/test_parser.zig` | AST 结构断言：优先级、结合性、节点形状 |
| 解释器集成测试 | `src/tests_impl.zig` | 端到端执行；**每个用例双引擎跑一遍并断言输出一致** |
| 差分对照 | `scripts/differential.sh` | 与真实 PHP 8.x 逐条对比输出（黄金标准） |

```console
zig build test                  # 单元 + 集成（双引擎）
bash scripts/differential.sh    # 需要 php CLI 在 PATH 中
```

## 性能

ReleaseFast 下与 PHP 8.5 (OPcache) 的对比（Windows, min of 5）：

| workload | zphp | php | 比率 |
|---|---|---|---|
| fib(27) 递归 | 101ms | 95ms | **1.1x** |
| 3000 万次循环累加 | 2168ms | 492ms | 4.4x* |
| 50 万次数组追加 + foreach | 94ms | 98ms | **1.0x** |
| 10 万次字符串拼接 | 978ms | 81ms | 12.1x |

\\* 循环剩余差距为逐指令派发开销（栈式机器 vs PHP 的专用 handler），
可通过指令融合（fused get/add/set）继续缩小。顶层变量已提升为主帧
局部 slot，数组操作已与 PHP 持平。详见 [BENCHMARKS.md](BENCHMARKS.md)。

## 架构

```
源码 (.php)
   │
   ▼
lexer.zig          词法分析：<?php 标签、注释、字面量、全操作符（零拷贝 token）
   │ Token[]
   ▼
parser.zig         递归下降 + 优先级爬升，产出 arena 分配的 AST
   │ ast.Stmt
   ├──────────────────────────────────┐
   ▼                                  ▼
compiler.zig                   interp.zig
字节码编译器                     树遍历参考引擎
（循环回边/常量池/slot 分配）      （--tree 启用，用于一致性对照）
   │ chunk.Func
   ▼
vm.zig             栈式字节码虚拟机：共享操作数栈 + 每帧局部 slot 数组，
                   平坦 switch 派发，~60 条指令
   │
   ├── opcode.zig    指令集定义与操作数打包
   ├── chunk.zig     字节块：指令流 / 常量池 / 行号表 / 函数单元
   ├── value.zig     动态值 + PHP 类型语义（truthy / looseCmp / 强制转换）
   └── builtins.zig  内置函数扩展点（当前为空，待填充标准库）
```

内存策略：整次脚本运行使用一个 ArenaAllocator，运行结束统一释放——
无需引用计数或 GC，换取实现简单性（QuickJS 用引用计数达到类似效果）。

## 路线图

- [x] 字节码编译 + 栈式 VM
- [ ] 内置函数标准库（string/array/math）
- [ ] 顶层变量局部提升（缩小循环性能差距）
- [ ] 引用语义 `&`
- [ ] OOP 子集
- [ ] PHP 对齐的 float 格式化与警告系统

## License

MIT
