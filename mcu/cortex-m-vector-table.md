# Cortex-M 中断向量表：从启动文件到 VTOR 重定位

在 Cortex-M 工程中，启动文件里经常会看到 `Reset_Handler`、`SVC_Handler`、`PendSV_Handler` 和各种 `IRQHandler`。这些函数为什么会被硬件找到？答案就在中断向量表里。

中断向量表本质上是一段连续的地址数据。表中的大部分条目是异常或中断处理函数的入口地址，第一个条目比较特殊，保存的是复位后的初始主栈指针 MSP，而不是函数地址。

## 1. 向量表的基本结构

从内存布局看，可以把它抽象成一个 32 位数组：

```c
uint32_t vector_table[] = {
    &__initial_sp,              // 索引 0：初始 MSP，不是函数指针
    (uint32_t)Reset_Handler,    // 索引 1
    (uint32_t)NMI_Handler,      // 索引 2
    (uint32_t)HardFault_Handler,// 索引 3
    /* ... */
    (uint32_t)SVC_Handler,      // 索引 11
    /* ... */
    (uint32_t)PendSV_Handler,   // 索引 14
    (uint32_t)SysTick_Handler,  // 索引 15
    (uint32_t)IRQ0_Handler,     // 索引 16
    /* ... */
};
```

每个条目占 4 字节。对于 Cortex-M，向量表中某个异常号对应的条目地址可以理解为：

```text
条目地址 = 向量表基地址 + 异常号 × 4
```

CPU 取出条目中的 32 位值，把它作为异常入口地址使用。

## 2. 第 0 项为什么不是函数地址

向量表的第 0 项保存的是复位时使用的初始 MSP 值。复位后，CPU 先从这个位置读取栈顶地址，设置主栈指针，然后再读取第 1 项的地址，跳转到 `Reset_Handler`。

因此，向量表不能简单看成“函数指针数组”：

| 索引 | 内容 | 是否为函数入口 |
| ---: | --- | --- |
| 0 | 初始 MSP 值 | 否，是栈顶地址 |
| 1 | `Reset_Handler` | 是 |
| 2 | `NMI_Handler` | 是 |
| 3 | `HardFault_Handler` | 是 |
| 4 及以后 | 其他异常或 IRQ 入口 | 通常是 |
| 保留条目 | 通常填 0 | 否 |

更准确地说，向量表是一个按异常号索引的 32 位地址表。只有第 0 项和保留项的含义不是函数入口地址。

## 3. 启动文件中的向量表

以 GCC 启动文件为例，向量表通常写在 `.isr_vector` 段中：

```asm
.section .isr_vector,"a",%progbits
.type g_pfnVectors, %object
g_pfnVectors:
    .word  _estack
    .word  Reset_Handler
    .word  NMI_Handler
    .word  HardFault_Handler
    .word  MemManage_Handler
    .word  BusFault_Handler
    .word  UsageFault_Handler
    .word  0
    .word  0
    .word  0
    .word  0
    .word  SVC_Handler
    .word  DebugMon_Handler
    .word  0
    .word  PendSV_Handler
    .word  SysTick_Handler
    .word  WWDG_IRQHandler
    .word  PVD_IRQHandler
    /* ... */
```

这里的几个关键点是：

- `.word` 定义一个 32 位数据；
- `_estack` 通常由链接脚本提供，表示 RAM 顶端的栈地址；
- `Reset_Handler` 等符号会被汇编器和链接器解析成函数入口地址；
- `0` 表示保留的异常条目，或者表示当前芯片没有实现对应的异常。

## 4. 链接脚本把向量表放到哪里

启动文件只定义了向量表内容，最终放在 Flash 的哪个位置由链接脚本决定。例如：

```ld
MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 512K
}

SECTIONS
{
    .isr_vector :
    {
        KEEP(*(.isr_vector))
    } > FLASH

    /* 其他代码和数据段 */
}
```

链接完成后，`.isr_vector` 段通常位于 Flash 起始地址 `0x08000000`。具体地址取决于芯片的存储器映射和工程配置，并不是所有 Cortex-M 工程都使用这个地址。

可以通过生成的 `.map` 文件或反汇编结果确认向量表实际被放到了哪里。

## 5. CPU 如何使用向量表

### 5.1 复位时

复位后，CPU 会完成类似下面的操作：

```text
读取向量表第 0 项 → 设置 MSP
读取向量表第 1 项 → 跳转到 Reset_Handler
```

### 5.2 发生异常时

假设当前向量表基地址为 `VTOR`，异常号为 `n`，CPU 会根据下面的地址找到对应条目：

```text
条目地址 = VTOR + n × 4
```

例如，外部 IRQ3 的异常号通常是 16 + 3 = 19，那么对应条目地址为：

```text
VTOR + (16 + 3) × 4
= VTOR + 0x4C
```

CPU 从这个位置取出 IRQ3 的处理入口地址，然后进入对应的 Handler。

## 6. 异常号与向量表索引

Cortex-M 的系统异常在向量表中的索引通常如下：

| 向量表索引 | 异常 |
| ---: | --- |
| 0 | 初始 MSP |
| 1 | Reset |
| 2 | NMI |
| 3 | HardFault |
| 4 | MemManage |
| 5 | BusFault |
| 6 | UsageFault |
| 11 | SVC |
| 12 | DebugMonitor |
| 14 | PendSV |
| 15 | SysTick |
| 16 及以后 | 外部 IRQ |

外部 IRQ 的向量表索引通常是：

```text
向量表索引 = 16 + IRQ 编号
```

不同芯片的 IRQ 数量、命名和外设分配不同，需要以对应芯片的参考手册和启动文件为准。

## 7. 函数地址最低位为什么是 1

Cortex-M 只执行 Thumb 指令集，因此异常入口地址的最低位需要为 1，用来表示 Thumb 状态。向量表中的函数地址通常会表现为：

```text
实际代码地址 | 1
```

例如：

```text
实际代码位置：0x080001A0
向量表中的值：0x080001A1
```

在 C、汇编和链接过程中，这个状态位通常由工具链和硬件约定自动处理。分析 `.bin`、`.hex` 或内存转储时，如果看到函数入口地址最低位为 1，不要把它误认为是地址没有对齐。

## 8. VTOR 与向量表重定位

支持 VTOR 的 Cortex-M 内核可以通过系统控制块中的 `SCB->VTOR` 指定向量表基地址：

```c
SCB->VTOR = 0x08004000U;
__DSB();
__ISB();
```

设置后，CPU 会从新的基地址查找异常入口。向量表基地址需要满足处理器规定的对齐要求，不能任意写入一个地址。

Bootloader 跳转到 App 时，通常要完成这些工作：

1. 关闭或清理 Bootloader 中仍然打开的中断和外设。
2. 从 App 起始地址读取第 0 项，设置 MSP。
3. 将 `SCB->VTOR` 设置为 App 的向量表地址。
4. 清理 pending 状态，并根据需要执行数据和指令同步屏障。
5. 读取 App 向量表第 1 项，跳转到 App 的 `Reset_Handler`。

如果只跳转到 App 的复位入口，却没有切换 `VTOR`，后续中断仍可能按照 Bootloader 的向量表处理，表现为中断跑错函数或直接进入 HardFault。

## 9. 内存中的实际样子

假设向量表被链接到 `0x08000000`，前几项可能类似这样：

| 地址 | 值（示例） | 含义 |
| --- | --- | --- |
| `0x08000000` | `0x20020000` | 初始 MSP，指向 RAM 顶部 |
| `0x08000004` | `0x080001A1` | `Reset_Handler` 入口 |
| `0x08000008` | `0x080002B5` | `NMI_Handler` 入口 |
| `0x0800000C` | `0x080002C1` | `HardFault_Handler` 入口 |
| `0x0800002C` | `0x0800030D` | `SVC_Handler` 入口 |
| `0x08000038` | `0x08000345` | `PendSV_Handler` 入口 |
| `0x0800003C` | `0x08000351` | `SysTick_Handler` 入口 |

这里的地址只是示例，实际数值由链接结果决定。`0x08000345` 这类最低位为 1 的值表示 Thumb 状态，实际代码地址可以理解为去掉最低位后的对齐地址。

## 10. 排查向量表问题

遇到“中断没有进入预期函数”时，可以按下面的顺序检查：

1. 查看启动文件中的 Handler 名称，确认 C 文件里的函数名完全一致。
2. 确认中断函数没有被写成 `static`，也没有被错误的宏替换。
3. 检查链接脚本是否保留了 `.isr_vector` 段，避免被链接器垃圾回收。
4. 查看 `.map` 文件，确认向量表和 Handler 的实际地址。
5. 在调试器中读取 `SCB->VTOR`，确认它指向当前正在运行的镜像。
6. 确认 NVIC 中断已经使能，外设本身的中断源也已经打开。
7. 检查 pending、优先级、清除标志和中断入口参数。
8. 如果使用 Bootloader，确认跳转前后 MSP、VTOR、MSP/PSP 和中断状态都已正确处理。

## 11. 总结

| 问题 | 答案 |
| --- | --- |
| 向量表是什么 | 一段连续排列的 32 位地址数据 |
| 第 0 项是什么 | 复位后的初始 MSP 值 |
| 其他条目是什么 | 异常或外部 IRQ 的入口地址，保留项通常为 0 |
| 向量表放在哪里 | 通常在 Flash 的固定区域，也可以通过 VTOR 重定位 |
| 如何查找条目 | `VTOR + 异常号 × 4` |
| 谁负责生成 | 启动文件和链接脚本共同完成 |
| 谁负责使用 | Cortex-M 内核在异常发生时自动查表 |

中断向量表不是高级语言里的“回调注册表”，而是一段固化在内存中的地址表。CPU 根据异常号计算偏移，取出对应入口地址，再进入相应的异常或中断处理函数。把启动文件、链接脚本、VTOR 和异常号放在一起看，向量表的工作方式就很直观了。
