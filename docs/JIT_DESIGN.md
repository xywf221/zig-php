# Baseline JIT 设计（待实施）

状态：**已实施**（src/jit.zig，tier-1 指令集）。

实际实现与设计的差异：
- 触发阈值：函数被调用 3 次后编译（设计中的 ≥3 ✓）
- echo 未进入第一档：含 echo/调用/foreach 的函数整体放弃 JIT，
  留在解释器（保守全有或全无策略按设计执行）
- 去优化协议简化为：rax = 恢复 ip（>0 即 deopt），正常完成 rax = 0、
  结果通过 out 指针写回

## 目标

把热点函数的字节码 1:1 翻译成 x86-64 机器码（baseline/template 档），
带类型守卫，守卫失败回退解释器。不做 SSA/寄存器分配/优化。

## 为什么现在是合适的时机

1. 值表示已定型：16 字节 `{payload(8), tag(8)}`（Zig tagged union，
   payload ≤ 8B）。标量（int/float/bool/null/指针变体）payload 即值本身。
2. 寄存器式字节码：操作数就是槽位号，翻译成 `reg + slot*16` 的内存寻址
   是机械映射。
3. 调用约定、帧布局、异常回溯全部稳定。

## 编码方案

```
Rax/Rcx/Rdx       : 暂存
Rbx               = regs 基址（Frame.regs.ptr）
R14               = consts 基址
R15               = arena 分配器指针（concat 等慢路径调用用）
Rsp               = 原生栈（慢路径 call 进 Zig helper）

Value 内存布局（需 comptime 断言）:
  [0..8)  payload
  [8..16) tag (u8 有效)

int 加载:   mov rax, [rbx+slot*16]     ; payload
            cmp qword [rbx+slot*8+8], TAG_INT
            jne  deopt
```

## 支持的指令集（第一档）

| 字节码 | 机器码 |
|---|---|
| ld_const(int) | mov rax, imm; store |
| mov | 2×mov |
| add/sub/mul (int) | tag 守卫 + 运算 + 溢出检查（jo deopt→float 慢路径）|
| lt/gt/eq (int) | 守卫 + cmp + setcc |
| jmp / jmp_if_false(local const) | 守卫 + 条件跳转 |
| return_int / return_null | epilogue |

其余指令不进入 JIT 函数：编译函数时遇到不支持的指令即放弃整个函数
（保守全有或全无，避免部分解释混合的状态管理）。

## 触发策略

- 函数被调用 ≥ 3 次且字节数 < 4096 → 尝试 JIT
- 编译失败（不支持的指令）→ 永久标记 interpreted

## 去优化

所有守卫失败跳到同一个 per-function trampoline：
保存机器码寄存器 → 恢复 Frame.ip 为当前字节码位置 → 返回解释器继续。

## Windows 可执行内存

VirtualAlloc(PAGE_EXECUTE_READWRITE)；Zig 下 std.os.windows.VirtualAlloc。
（后续可改 W^X 双映射。）

## 预期收益

loop/fib 这类纯标量循环 1.7x/0.9x → 预计 0.5-0.8x（反超 PHP）。
strings/arrays 无收益（内置函数主导）。

## 工作量估计

emitter ~600 行 + 编译器 ~500 行 + 触发/去优化 ~300 行 + 测试 ~300 行。
需要一整个专注会话；汇编错误表现为静默数值错误，必须配差分对照逐条验。
