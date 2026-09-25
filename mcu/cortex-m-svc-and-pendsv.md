# Cortex-M 中的 SVC 与 PendSV

在 Cortex-M 和 RTOS 中，SVC、PendSV、SysTick 经常一起出现在启动文件和移植层代码里。SVC 负责响应软件主动发起的系统服务请求，PendSV 则通常用来完成任务切换。理解这两个异常的触发方式和执行时机，读 RTOS 的启动代码会容易很多。

## 1. SVC 是什么

SVC 是 **Supervisor Call** 的缩写。在 Cortex-M 中，它既是一条指令，也是一种同步系统异常。

```asm
SVC #imm
```

其中 `imm` 是 8 位立即数，范围为 0 到 255。CPU 执行这条指令后，会触发 SVC 异常，进入 Handler 模式，并跳转到向量表中的 `SVC_Handler`。

Cortex-M 系统异常的编号中：

- SVC 的异常号是 11；
- PendSV 的异常号是 14；
- SysTick 的异常号是 15。

SVC 的异常优先级由系统处理器控制寄存器配置，通常对应 `SHPR2` 中的 SVC 优先级字段。具体优先级要看系统配置，不能简单认为所有 RTOS 都把 SVC 设置为最高优先级。

## 2. 为什么需要 SVC

Cortex-M 有 Thread 模式和 Handler 模式：

| 模式 | 特权情况 | 常见用途 |
| --- | --- | --- |
| Thread 模式 | 可以是特权，也可以是非特权 | 普通程序、RTOS 任务 |
| Handler 模式 | 始终为特权 | 异常和中断处理 |

在启用了 MPU 或其他权限隔离机制的系统里，任务可以运行在非特权 Thread 模式。非特权代码不能直接访问内核数据，也不能执行所有特权操作。任务需要内核服务时，可以执行 `SVC`，通过异常机制进入特权的 Handler 模式，再由内核完成请求。

因此，SVC 可以看作非特权代码进入内核的一个受控入口。SVC 的立即数可以用来表示不同的服务编号，异常处理函数根据这个编号分发到对应的处理逻辑。

需要注意的是，普通 FreeRTOS 端口中，任务通常仍然运行在特权模式，很多内核 API 可以直接调用，并不意味着每个 API 都会经过 SVC。SVC 是否承担系统调用入口，取决于具体的 RTOS 移植层、MPU 配置和权限模型。

## 3. SVC 的处理流程

以任务执行 `SVC #1` 为例，基本过程如下：

```text
任务执行 SVC #1
        ↓
CPU 自动保存基本异常栈帧
        ↓
根据向量表跳转到 SVC_Handler
        ↓
从异常栈帧中取出返回地址 PC
        ↓
读取 PC 前面的 SVC 指令并提取立即数 1
        ↓
根据 SVC 号执行对应的内核服务
        ↓
异常返回，回到原来的 Thread 模式
```

Cortex-M 在进入异常时，通常会自动压入下面这些寄存器：

```text
R0、R1、R2、R3、R12、LR、PC、xPSR
```

SVC 指令本身占用 16 位，因此处理函数通常会从栈帧中的返回地址 `PC` 向前移动 2 个字节，读取 `SVC` 指令的机器码，再取出其中的立即数。

实际代码还要先判断异常返回值 `EXC_RETURN`，确认当前使用的是 MSP 还是 PSP。RTOS 任务通常使用 PSP，异常处理和内核启动阶段通常使用 MSP。启用了浮点单元时，异常栈帧还可能包含额外的浮点寄存器。

伪代码可以写成：

```c
void SVC_Handler(void)
{
    uint32_t *stack_frame = get_active_stack_frame();
    uint16_t *svc_instruction = (uint16_t *)stack_frame[6] - 1;
    uint8_t svc_number = *svc_instruction & 0xffU;

    dispatch_svc(svc_number, stack_frame);
}
```

不同编译器和 RTOS 移植层的写法会不同，很多实现会用汇编代码完成栈指针判断和参数传递。

## 4. SVC 在向量表中的位置

启动文件中的异常向量表通常包含类似内容：

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

具体的符号名可能不同。例如，FreeRTOS 的移植层可能使用 `vPortSVCHandler`、`xPortPendSVHandler` 和 `xPortSysTickHandler`，然后在启动文件或工程配置中把它们映射到对应的异常入口。

## 5. SVC 与 PendSV 的区别

| 特性 | SVC | PendSV |
| --- | --- | --- |
| 触发方式 | 执行 `SVC` 指令 | 设置挂起位，或由内核请求挂起 |
| 触发属性 | 同步异常 | 可延迟处理的异步异常 |
| 执行时机 | 执行指令后进入异常流程 | 等待更高优先级异常处理完成后执行 |
| 典型用途 | 系统调用、启动第一个任务 | RTOS 上下文切换 |
| 异常号 | 11 | 14 |
| 常见优先级 | 根据系统调用需求配置 | 通常设置为较低优先级 |

SVC 是当前代码主动发起的请求。只要没有被更高优先级异常打断，执行到 `SVC` 指令后就会进入 SVC 异常处理。

PendSV 则是先被置为 pending，等处理器有合适的时机再执行。RTOS 通常把 PendSV 设为最低或较低优先级，这样不会打断正在执行的高优先级中断。高优先级中断结束后，PendSV 再完成寄存器保存、任务栈切换和寄存器恢复。

可以把两者简单区分为：

```text
SVC    → 当前任务主动请求内核服务
PendSV → 内核在合适时机执行任务切换
```

## 6. SVC、PendSV 与 SysTick 的配合

一个典型的 RTOS 调度过程大致如下：

```text
SysTick 定时到期
      ↓
更新系统节拍和延时状态
      ↓
发现需要切换任务
      ↓
设置 PendSV pending
      ↓
PendSV 执行上下文切换
      ↓
恢复下一个任务的寄存器和栈
```

而 SVC 更常见于内核启动或系统调用入口：

```text
启动代码或非特权任务
      ↓
执行 SVC 指令
      ↓
SVC_Handler / vPortSVCHandler
      ↓
进入内核服务或启动第一个任务
```

三者的职责可以概括为：

- **SVC**：主动请求内核服务。
- **SysTick**：提供周期性的系统节拍。
- **PendSV**：在合适时机完成上下文切换。

## 7. 读 RTOS 移植层时的关注点

看到 SVC 相关代码时，可以按下面的顺序理解：

1. 向量表中的 SVC 入口最终对应哪个函数。
2. 异常处理使用 MSP 还是 PSP。
3. SVC 号码从哪里读取，是否从栈帧中的 PC 前移 2 字节。
4. 立即数对应哪些系统服务或启动动作。
5. 异常返回时是否切换到 PSP 和 Thread 模式。
6. 是否启用了 MPU、FPU 或其他会改变异常栈帧的功能。

如果是分析 FreeRTOS，还需要继续看 `SVC`、`PendSV` 和 `SysTick` 三个处理函数在具体 `portable` 目录下的实现。不同 Cortex-M 内核、编译器和移植层的汇编细节可能不同，但整体职责通常保持不变。

## 8. 总结

SVC 是 Cortex-M 提供的一条软件触发指令，同时也是一个同步系统异常。它可以让非特权 Thread 模式通过受控入口请求特权内核服务。处理 SVC 时，CPU 会自动保存基本异常栈帧，内核可以从栈帧里的返回地址找到 `SVC` 指令并提取立即数。

PendSV 与 SVC 的定位不同：SVC 是当前代码主动发起的系统服务请求，PendSV 是可以延迟执行的异常，RTOS 通常利用它完成上下文切换。再配合 SysTick 提供的周期节拍，这三个异常共同构成了许多 Cortex-M RTOS 的基础运行机制。
