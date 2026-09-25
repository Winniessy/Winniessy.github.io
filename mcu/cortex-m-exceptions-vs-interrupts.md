# Cortex-M 异常与中断的区别

在 Cortex-M 的代码里，`UART_IRQHandler`、`SVC_Handler` 和 `HardFault_Handler` 看起来都像“硬件回调”：硬件发生某件事后，CPU 跳到向量表对应的函数里执行。

但它们在硬件层面的分类并不一样。区别主要在于触发源、触发时机、和当前指令的关系、异常返回方式，以及由哪个硬件模块管理。

## 1. 中断是异常的一部分

在 ARM Cortex-M 的术语中，**Exception（异常）** 是一个总称，指所有能够打断正常指令流、让 CPU 进入异常处理流程的事件。

**Interrupt（中断）** 通常特指外部设备或外部引脚产生的 IRQ，也就是异常中的一部分。

因此可以这样理解：

```text
Exception
├── Reset
├── NMI
├── HardFault
├── MemManage / BusFault / UsageFault
├── SVC
├── DebugMonitor
├── PendSV
├── SysTick
└── 外部 IRQ
    ├── UART
    ├── GPIO
    ├── Timer
    └── DMA
```

严格来说，最后一类外部 IRQ 才是通常所说的“中断”。所以：

> 所有中断都是异常，但不是所有异常都是中断。

## 2. 触发源和同步性

### 2.1 同步异常

同步异常由 CPU 执行当前指令时产生，发生位置与当前指令流直接相关。例如：

- 执行 `SVC #imm`，触发 SVC 异常；
- 执行除零或非法指令，可能触发 UsageFault；
- 访问无效地址或违反访问权限，可能触发 MemManage、BusFault 或 HardFault；
- 执行 `BKPT`，触发调试相关异常。

这类异常通常可以定位到某条具体指令。程序执行到这里时，异常就会发生，因此称为同步异常。

### 2.2 异步中断

外部中断通常与 CPU 当前执行哪条指令没有直接关系，例如：

- UART 接收到数据；
- GPIO 检测到边沿；
- 定时器计数溢出；
- DMA 传输完成。

CPU 可能正在执行任意代码，外设事件发生后都会请求中断。只要中断没有被屏蔽，并且优先级满足抢占条件，CPU 就会在合适的边界进入中断处理函数。

可以简单记成：

```text
同步异常：当前指令导致异常
异步中断：外部事件请求处理
```

## 3. 异常入口不是普通函数调用

从 C 代码看，处理函数确实长得像普通函数：

```c
void SVC_Handler(void)
{
    /* ... */
}

void UART_IRQHandler(void)
{
    /* ... */
}
```

但硬件进入它们的方式和执行 `BL` 调用普通函数完全不同。

### 普通函数调用

```asm
BL  function
```

CPU 把下一条指令的地址保存到 LR，函数执行完后通过返回指令回到调用点。

### 异常进入

发生异常时，Cortex-M 硬件会自动完成一部分现场保存：

```text
R0、R1、R2、R3、R12、LR、PC、xPSR
```

然后根据异常号查找向量表，切换到 Handler 模式，并跳转到对应的异常入口。异常入口使用的 LR 不是普通函数调用意义上的返回地址，而是一个 `EXC_RETURN` 标记，处理器据此决定从 MSP 还是 PSP 恢复，以及返回 Thread 模式还是继续留在 Handler 模式。

因此，异常处理函数虽然表现为一个 C 函数，但它的进入和退出由 Cortex-M 的异常机制管理。

## 4. 返回行为也不完全相同

普通中断处理完成后，CPU 通常恢复被打断的现场，继续执行原来暂停的位置。

同步异常的返回要看具体类型：

- SVC 处理完成后，通常返回到 SVC 指令之后继续执行；
- 可恢复的 Fault 可能修正问题后重新执行或继续运行；
- 严重 Fault 如果无法恢复，可能进入 HardFault 或最终停在错误处理流程中；
- Reset 不属于一次普通的“打断后返回”，它会重新开始系统启动流程。

异常处理函数通常通过 `BX LR` 触发异常返回，编译器或汇编移植层会根据 `EXC_RETURN` 完成现场恢复。不能把异常返回简单理解成普通函数的 `return`。

## 5. 屏蔽方式和管理单元

### 外部 IRQ

外部 IRQ 主要由 NVIC 管理，包括使能、挂起、清除 pending 和优先级配置。根据系统配置，可以使用 `PRIMASK`、`BASEPRI` 或 `FAULTMASK` 影响部分中断的响应。

### 系统异常

SVC、PendSV、SysTick 等系统异常的可配置优先级通常由 SCB 的系统处理器优先级寄存器管理：

- SVC 的优先级位于 `SHPR2`；
- PendSV 和 SysTick 的优先级位于 `SHPR3`。

NMI 和 HardFault 的优先级固定且高于普通可配置异常：

- NMI 的优先级为 -2，不能被普通屏蔽方式屏蔽；
- HardFault 的优先级为 -1，通常也不能通过普通关中断方式屏蔽。

Reset 则是复位流程，不是可以通过 NVIC 使能或关闭的外部中断。

如果把所有事件都叫“中断”，就容易产生一些具体问题：HardFault 能不能关掉？SVC 的优先级是不是配置在 NVIC 里？PendSV 为什么总是设得很低？区分术语，实际是在区分对应的硬件路径。

## 6. 向量表和处理函数

启动文件中的向量表会把异常号映射到处理函数，例如：

```asm
DCD  Reset_Handler
DCD  NMI_Handler
DCD  HardFault_Handler
...
DCD  SVC_Handler          ; 系统异常号 11
DCD  DebugMon_Handler
DCD  0
DCD  PendSV_Handler       ; 系统异常号 14
DCD  SysTick_Handler      ; 系统异常号 15
```

外部 IRQ 则通常位于系统异常之后：

```asm
DCD  WWDG_IRQHandler
DCD  PVD_IRQHandler
DCD  UART_IRQHandler
DCD  DMA_IRQHandler
```

不同芯片的外部 IRQ 数量和名称不同，但整体方式一致：硬件根据异常号取得向量表中的入口地址，再进入对应的 Handler。

## 7. 典型例子

### SVC

任务执行：

```asm
SVC #1
```

这是软件主动发起的同步异常。SVC 处理函数可以从异常栈帧里的 PC 找到这条指令，并读取立即数 `1`，再根据约定执行对应的内核服务。

### UART 中断

UART 接收到一个字节后，外设把中断请求送给 NVIC。CPU 在满足优先级条件时进入 `UART_IRQHandler`，读取状态寄存器和数据寄存器，处理接收数据，最后异常返回到原来的执行位置。

### HardFault

程序访问了无效地址，或者发生了无法处理的总线错误，CPU 进入 `HardFault_Handler`。这不是外部设备“打进来”的中断，而是 CPU 或总线访问过程报告的异常。

### Reset

复位后，CPU 从复位向量取出初始栈指针和 `Reset_Handler` 地址，开始执行启动代码。它会重新建立运行环境，因此不能把 Reset 当成普通可返回的中断。

## 8. 一个简单的类比

- **SVC**：主动联系内核，请求办理一项系统服务。
- **UART 中断**：外设突然通知 CPU 有数据到达，CPU 暂停当前工作进行处理。
- **HardFault**：当前代码访问出错，CPU 进入故障处理流程。
- **Reset**：系统重新启动，重新执行初始化流程。

它们最后都可能由一个 Handler 处理，但触发原因、进入方式和返回语义并不相同。

## 9. 总结

异常是 Cortex-M 对这类控制流切换事件的总称，中断通常特指外部设备或外部引脚产生的 IRQ。SVC、Fault、PendSV、SysTick 属于系统异常，UART、GPIO、定时器和 DMA 产生的是外部中断。

两者都会使用向量表，也都会进入一个处理函数，所以从软件表面看很像回调。但硬件真正执行的是异常进入和异常返回流程，区别体现在触发源、同步性、现场保存、返回位置、屏蔽方式以及 NVIC/SCB 的管理范围上。
