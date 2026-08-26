# Baseline JIT — 事后报告（已移除）

状态：**已移除**。曾实现为 `src/jit.zig`（tier-1 指令集：int
const/mov/add/sub/mul、inc、比较跳转、jmp、return），x86-64 手写编码，
类型守卫 + deopt 回退解释器，Windows x64 ABI。git 历史中可找回完整实现。

## 为什么移除

ReleaseFast 构建下，JIT 函数的 deopt 路径执行会非确定地破坏 VM 状态：
操作数变成垃圾类型、远离调用点的段错误。故障随 seemingly 无关的源码改动
出现/消失（布局依赖），同一逻辑语义的构建时好时坏。

## 排查过程中已验证无误的部分

- 生成的机器码：多次逐字节人工反汇编（含脚本化解码器核对全部跳转目标、
  守卫、读写偏移），完全正确。
- 调用 ABI：Win64 rcx/rdx/r8 传参被计算结果反向证明有效；栈对齐、影子空
  间、易失/非易失寄存器使用均符合规范；后改用内联汇编 trampoline 绕开
  LLVM 的间接调用生成，问题依旧。
- 内存管理：执行页 NtAllocateVirtualMemory/mmap 正确；寄存器堆 arena 单
  调分配无复用；金丝雀哨兵检测无越界写。
- probeLayout（Value 布局探测）改为字节级检查后，Debug/ReleaseSafe 也能
  运行 JIT——在带全部安全检查的两个模式下通过 146 项测试、differential
  全量、酷刑用例矩阵（浮点/字符串/递归/方法/静态混合 deopt）×25 次全绿。
- 性能验证过是真实的：sumTo(30M) 约 46ms（解释器 884ms，PHP CLI 412ms）。

## 无法控制的因素

故障只在 ReleaseFast 出现，且与代码布局相关而非任何可指认的逻辑缺陷。
怀疑方向：Zig 0.16-dev / LLVM 对"调用裸可执行内存"周边的优化与我们的场
景存在未知交互。无法定位即无法约束，也无法向用户承诺其不复发。

按项目原则（正确性 > 性能），整个子系统移除。解释器 VM 不受影响。

## 若将来重启此工作

1. 先在最新 Zig 上复现原问题（git 历史有完整实现与失败用例
   /tmp/deopt*.php 形态：先完成一次 JIT 调用，再以非 int 参数触发
   deopt）。
2. 优先排查方向：LLVM 对间接调用裸内存的调用点 lowering；或改用
   asm trampoline + 显式 clobber（历史中有现成实现）。
3. 保留本文件记录的三条编码陷阱（见下）仍然适用：
   - tag 守卫必须字节比较（解释器只写低字节，池化寄存器堆有脏高位）；
   - ADD/SUB/CMP 目的数在 rm 字段、IMUL 相反，REX.B/R 弄反会静默算错；
   - NORMAL 出口不得贯穿进 DEOPT 块（会把所有正常完成当 deopt 双重执行）；
   - invokeUser 推帧后必须 dispatch（外层 dispatch 会继续执行调用者帧）。
