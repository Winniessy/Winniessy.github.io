# Linux 中断体系：从 MCU 的 NVIC 和 ISR 理解 GIC、irqchip 与上下半部

从 MCU 转到嵌入式 Linux 时，中断其实不算完全陌生。

在 MCU / FreeRTOS 里，我们通常已经会这样做：

```text
硬件产生中断
    ↓
NVIC
    ↓
ISR
    ↓
清中断 / 取必要数据
    ↓
Queue / Notify / Semaphore
    ↓
唤醒 Task
    ↓
Task 做协议解析、计算等耗时工作
```

这里已经有一个很重要的思想：

> **ISR（Interrupt Service Routine，中断服务程序）里不要做太多事情，时间敏感的工作立即处理，耗时工作延后。**

Linux 仍然遵循这个原则。

不同的是，Linux 是多核、支持大量设备，而且中断控制器的拓扑也更复杂，所以把这套机制进一步标准化成了：

```text
硬件 IRQ
    ↓
Interrupt Controller
    ↓
Linux IRQ Core
    ↓
Hard IRQ Handler
    ↓
Threaded IRQ / Workqueue / Softirq
```

所以学 Linux 中断，不需要把 MCU 那套推翻重学，更像是在原来的基础上增加几层抽象。

---

# 一、从 NVIC 到 GIC

在 STM32 这类 Cortex-M MCU 中，一般是：

```text
UART
  ↓
IRQ
  ↓
NVIC
  ↓
Cortex-M
  ↓
USART_IRQHandler()
```

NVIC：

```text
Nested Vectored Interrupt Controller
嵌套向量中断控制器
```

主要负责：

```text
中断 Enable / Disable
中断优先级
Pending 状态
CPU 响应中断
```

到了 RK3588 这种 Cortex-A 多核 SoC，常见的是：

```text
GIC
Generic Interrupt Controller
通用中断控制器
```

可以暂时理解成：

```text
Cortex-M：
NVIC

Cortex-A：
GIC
```

这个类比虽然不是严格一一对应，但对于理解 Linux 中断已经非常够用。

---

# 二、为什么 GIC 比 NVIC 复杂

STM32F4 很多时候只有一个 CPU Core：

```text
UART
SPI
TIM
GPIO
 ↓
NVIC
 ↓
CPU
```

但 RK3588 有多个 CPU Core。

例如：

```text
CPU0
CPU1
CPU2
CPU3
CPU4
CPU5
CPU6
CPU7
```

这时候外设中断来了，就多了一个问题：

> **这个 IRQ 到底交给哪个 CPU？**

例如网卡产生中断：

```text
Ethernet
    ↓
IRQ
    ↓
GIC
    ↓
CPU?
```

GIC 除了管理：

```text
Enable
Priority
Pending
Mask
```

还需要负责：

```text
Interrupt Routing
中断路由

CPU Target
目标 CPU
```

这就是 Linux 多核系统里中断明显比 MCU 复杂的主要原因之一。

---

# 三、Mask、Pending、Active 到底是什么意思

这些名字看着陌生，其实 MCU 里都有类似概念。

## Mask：屏蔽

Mask（屏蔽）就是：

> 暂时不允许 CPU 响应这个 IRQ。

MCU 中：

```c
HAL_NVIC_DisableIRQ(USART1_IRQn);
```

其实就属于类似操作。

可以理解成：

```text
UART 产生 IRQ
     ↓
中断控制器
     ↓
被 Mask
     ×
CPU 暂时不响应
```

所以：

```text
mask
→ 屏蔽中断

unmask
→ 允许中断
```

注意，屏蔽不一定意味着硬件事件不存在。

有可能：

```text
硬件已经产生中断
但暂时没有交给 CPU
```

---

## Pending：等待处理

Pending（挂起 / 待处理）表示：

> 中断已经来了，但 CPU 还没有开始处理。

例如：

```text
UART IRQ 到来
    ↓
Pending = 1
    ↓
CPU 此时正在处理更高优先级中断
    ↓
UART IRQ 等待
    ↓
之后 CPU 再处理
```

可以把 Pending 理解成：

> **这个中断已经排队了。**

---

## Active：正在处理

Active（活动状态）表示：

> CPU 已经开始处理这个中断。

大概就是：

```text
Inactive
    ↓
中断到来
    ↓
Pending
    ↓
CPU 接受中断
    ↓
Active
    ↓
执行 Handler
    ↓
EOI
    ↓
Inactive
```

EOI：

```text
End Of Interrupt
中断结束
```

可以理解成 CPU 告诉中断控制器：

> 这个 IRQ 我处理完了。

---

# 四、GIC 中常见的 SGI、PPI、SPI

GIC 会把中断大致分成几类。

刚开始不需要了解寄存器细节，只需要知道它们分别来自哪里。

```text
                 GIC Interrupt
                       │
          ┌────────────┼────────────┐
          ↓            ↓            ↓
         SGI          PPI          SPI
```

---

## SGI：软件产生中断

SGI：

```text
Software Generated Interrupt
软件产生中断
```

主要由软件主动产生。

在多核 Linux 中，经常用来实现：

```text
IPI
Inter-Processor Interrupt
处理器间中断
```

例如：

```text
CPU0
 ↓
通过 GIC 产生 SGI
 ↓
CPU4 收到中断
```

用途可能包括：

```text
让另一个 CPU 重新调度
通知另一个 CPU
TLB Shootdown
让其他 CPU 执行某个动作
```

所以可以简单记：

```text
IPI
→ CPU 给 CPU 发中断这个概念

SGI
→ ARM GIC 用来实现它的一种硬件机制
```

---

## PPI：每个 CPU 私有的中断

PPI：

```text
Private Peripheral Interrupt
私有外设中断
```

典型情况是：

```text
Per-CPU Timer
每个 CPU 自己的定时器
```

例如：

```text
CPU0 ← 自己的 Timer
CPU1 ← 自己的 Timer
CPU2 ← 自己的 Timer
```

这种中断天然属于某个 CPU，不需要像普通外设 IRQ 那样到处路由。

可以记成：

> **PPI = 每个 CPU 自己的。**

---

## SPI：共享外设中断

这里最容易和 SPI 总线搞混。

GIC 里的 SPI：

```text
Shared Peripheral Interrupt
共享外设中断
```

和：

```text
Serial Peripheral Interface
串行外设接口
```

没有关系。

GIC SPI 一般来自：

```text
UART
I2C Controller
SPI Controller
DMA
USB
Ethernet
GPU
```

这类 SoC 外设。

这些 IRQ 可以根据系统配置路由到不同 CPU，所以叫 Shared Peripheral Interrupt。

可以简单记：

```text
SGI：CPU 叫 CPU

PPI：CPU 自己的

SPI：普通共享外设
```

---

# 五、CPU Affinity 是什么

因为 Linux 是多核系统，所以普通外设 IRQ 不一定固定由某一个 CPU 处理。

这就有：

```text
IRQ Affinity
中断亲和性
```

例如：

```text
Ethernet IRQ
      ↓
GIC
      ↓
CPU2
```

也可能调整成：

```text
Ethernet IRQ
      ↓
CPU4
```

Linux 可以查看：

```bash
cat /proc/interrupts
```

可能看到：

```text
           CPU0   CPU1   CPU2   CPU3
42:        1000      0      0      0   uart
85:           0   8000      0      0   eth0
```

说明：

```text
UART 中断主要由 CPU0 处理
Ethernet 中断主要由 CPU1 处理
```

这在单核 MCU 上基本不需要考虑。

---

# 六、GIC 和 irqchip 不是同一个东西

这一点很容易混。

可以这样区分：

```text
GIC
→ 硬件 Interrupt Controller

irqchip
→ Linux 对 Interrupt Controller 的软件抽象
```

Linux 不只支持 ARM GIC，还可能支持：

```text
RISC-V PLIC
GPIO Interrupt Controller
各种厂商自己的 Interrupt Controller
```

这些硬件寄存器完全不同。

Linux 不希望整个内核都知道：

```text
GIC 怎么 mask
PLIC 怎么 mask
GPIO IRQ 怎么 ack
```

所以抽象出：

```c
struct irq_chip
```

概念上包含：

```c
irq_mask();
irq_unmask();
irq_ack();
irq_eoi();
irq_set_type();
irq_set_affinity();
```

于是：

```text
GIC Driver
   ↓
实现 irq_chip

GPIO Interrupt Controller Driver
   ↓
实现 irq_chip
```

上层 Linux IRQ Core 就可以用一套统一接口管理不同中断控制器。

因此和 MCU 类比时：

```text
NVIC
≈ GIC
```

而：

```text
irqchip
```

更像 Linux 为 NVIC、GIC、GPIO 中断控制器这一类硬件定义的一套统一 Driver Interface（驱动接口）。

---

# 七、Linux 为什么还需要 IRQ Core

Linux Driver 并不会直接去操作 GIC。

普通设备驱动通常只会：

```c
request_irq();
```

或者：

```c
devm_request_irq();
```

例如：

```c
irq = platform_get_irq(pdev, 0);

ret = devm_request_irq(dev,
                       irq,
                       my_irq_handler,
                       0,
                       "my-device",
                       data);
```

Driver 实现：

```c
static irqreturn_t my_irq_handler(int irq, void *data)
{
    ...
    return IRQ_HANDLED;
}
```

这时候 Driver 并不需要知道：

```text
底层是 GICv3
具体硬件中断号是多少
GIC 哪个寄存器负责 mask
这个 IRQ 当前路由到哪个 CPU
```

这些都由：

```text
IRQ Core
+
irqchip
+
GIC Driver
```

处理。

所以可以理解成：

```text
设备 Driver
     ↓
request_irq()
     ↓
Linux IRQ Core
     ↓
irqchip
     ↓
GIC Driver
     ↓
GIC Hardware
```

---

# 八、Device Tree 中的 interrupt 在做什么

很多 SoC 外设的中断来源会写在 Device Tree（设备树）中。

例如概念上：

```dts
device@xxx {
    interrupts = <...>;
};
```

对于普通 Driver 来说，它不会自己把：

```text
GIC 硬件 IRQ 号
```

写死在代码里。

Driver 更常见的是：

```c
irq = platform_get_irq(pdev, 0);
```

意思可以理解成：

> 给我这个设备描述里的第 0 个中断资源。

然后：

```c
request_irq(irq, ...);
```

注册自己的 Handler。

因此：

```text
Device Tree
    ↓
描述硬件 IRQ 连接
    ↓
Linux IRQ Framework
    ↓
转换成 Linux IRQ
    ↓
Driver 获取 IRQ
    ↓
request_irq()
```

这和 MCU 里直接使用：

```c
USART1_IRQn
```

的方式差别比较大。

---

# 九、为什么 Linux 里会出现“Linux IRQ Number”

在 MCU 中：

```text
硬件 IRQ Number
```

通常和你代码里使用的 IRQn 联系非常直接。

Linux 中间又增加了一层软件管理。

概念上：

```text
Hardware IRQ
硬件中断号
    ↓
irq_domain
    ↓
Linux IRQ Number
Linux 虚拟中断号
```

Driver 最终通常操作的是：

```text
Linux IRQ
```

而不是直接把某个 GIC Hardware IRQ 写死。

这样做的原因是 Linux 可能面对：

```text
GIC
GPIO IRQ Controller
PCIe MSI
其他级联中断控制器
```

硬件中断拓扑可能不止一层。

---

# 十、中断控制器甚至可以级联

在 MCU 里，我们通常想象：

```text
GPIO
 ↓
NVIC
 ↓
CPU
```

Linux SoC 上可能是：

```text
Sensor
   ↓
GPIO3_5
   ↓
GPIO Interrupt Controller
   ↓
GIC
   ↓
CPU
```

也就是说：

```text
GPIO Controller
```

自己也可能是一个 Interrupt Controller（中断控制器）。

这时候就会出现：

```text
GPIO irqchip
     ↓
parent irqchip
     ↓
GIC irqchip
```

所以 Linux 才需要：

```text
irq_chip
irq_domain
IRQ Core
```

这些抽象。

否则只靠一个固定 Vector Table（中断向量表）很难描述如此复杂的硬件拓扑。

---

# 十一、Hard IRQ 是什么

Hard IRQ（硬中断）就是最接近 MCU ISR 的部分。

例如：

```c
static irqreturn_t my_irq_handler(int irq, void *data)
{
    ...
    return IRQ_HANDLED;
}
```

基本原则和 MCU 一样：

```text
尽可能快
只做必须立即做的事情
不要执行很耗时的操作
```

但 Linux 还有一条非常重要的规则：

> **Hard IRQ Context（硬中断上下文）不能睡眠。**

所以一般不能在里面调用可能导致当前执行流睡眠的 API。

例如很多：

```text
mutex_lock()
I2C Transaction
某些内存分配
等待事件
```

都不能随便在 Hard IRQ 里做。

---

# 十二、为什么 Hard IRQ 不能睡眠

因为 Hard IRQ 不是普通 Task / Process（任务 / 进程）。

它是：

```text
CPU 正在执行原来的代码
      ↓
硬件 IRQ
      ↓
CPU 被打断
      ↓
进入 Hard IRQ Handler
```

它没有一个正常的：

```text
“当前这个 IRQ Handler 对应某个可调度进程”
```

可以被 Scheduler（调度器）正常挂起再恢复。

所以 Hard IRQ 不能：

```text
等 Mutex
等 I/O
sleep
阻塞
```

这和 FreeRTOS ISR 中不能调用普通阻塞 API 的思想非常类似。

---

# 十三、Linux 的“上半部 / 下半部”是什么

传统 Linux 中断会把处理拆成：

```text
Top Half
上半部

Bottom Half
下半部
```

上半部就是：

```text
Hard IRQ
```

负责：

```text
最时间敏感的事情
确认中断来源
必要时清中断
保存少量状态
触发后续处理
```

下半部则负责：

```text
耗时工作
协议处理
复杂计算
后续数据处理
```

这和 MCU / FreeRTOS：

```text
ISR
 ↓
通知 Task
 ↓
Task 做后处理
```

本质非常接近。

---

# 十四、Threaded IRQ：线程化中断

Threaded IRQ（线程化中断）是 Linux 中非常好理解的一种机制。

可以写成：

```c
devm_request_threaded_irq(dev,
                          irq,
                          irq_handler,
                          irq_thread,
                          IRQF_ONESHOT,
                          "my-device",
                          data);
```

大概结构：

```text
硬件 IRQ
    ↓
Hard IRQ Handler
    ↓
快速确认中断
    ↓
唤醒 IRQ Thread
    ↓
Thread Handler
    ↓
执行后续工作
```

最大的不同是：

> Thread Handler 运行在线程上下文中，可以做一些可能睡眠的操作。

例如一个 I2C Sensor：

```text
Sensor DRDY IRQ
    ↓
GPIO Interrupt
    ↓
Hard IRQ
    ↓
Threaded IRQ
    ↓
i2c_transfer()
    ↓
读取 Sensor 数据
```

这种模式非常常见。

因为：

```text
i2c_transfer()
```

可能涉及等待硬件传输完成，不能简单放在 Hard IRQ 中。

---

# 十五、Workqueue 是什么

Workqueue（工作队列）也用于把工作从某个当前上下文延迟出去执行。

例如：

```text
Hard IRQ
   ↓
schedule_work()
   ↓
Workqueue
   ↓
Kernel Worker Thread
   ↓
真正处理数据
```

和 FreeRTOS 特别像：

```text
ISR
 ↓
Queue / Notify
 ↓
Task
 ↓
真正处理
```

所以从 MCU 角度可以粗略类比：

```text
FreeRTOS：
ISR → Task

Linux：
Hard IRQ → Workqueue
```

当然它们实现机制不同，但设计思想是一致的。

---

# 十六、Threaded IRQ 和 Workqueue 有什么直觉上的区别

初学时不必把所有细节背下来，可以先这么理解。

如果某段后续处理和这个 IRQ 强绑定：

```text
IRQ 来了
 ↓
这个设备必须完成下一阶段中断处理
```

Threaded IRQ 很自然。

如果只是：

```text
当前发生了一件事
 ↓
安排一个稍后执行的普通工作
```

Workqueue 更通用。

例如：

```text
IRQ
 ↓
读取硬件状态
 ↓
schedule_work()
 ↓
Workqueue
 ↓
更新状态 / 做复杂逻辑
```

---

# 十七、Softirq 又是什么

Softirq：

```text
Software Interrupt
软中断
```

是 Linux 内核内部的一种 Bottom Half（下半部）机制。

它和 Threaded IRQ、Workqueue 最大的直觉区别是：

> Softirq 仍然更接近中断上下文，并不是普通可睡眠的进程上下文。

所以 Softirq 中同样不能随便睡眠。

它经常用于：

```text
Network
Timer
```

等对性能要求很高的内核路径。

普通设备 Driver 开发中，通常不需要自己创建一种新的 Softirq。

因此初学 Driver 时可以先记：

```text
Hard IRQ
→ 不能睡眠

Softirq
→ 仍不能随便睡眠

Threaded IRQ
→ 线程上下文，可睡眠

Workqueue
→ Worker 线程上下文，可睡眠
```

这已经非常够用了。

---

# 十八、Tasklet 是什么

Tasklet 是建立在 Softirq 之上的一种较老 Bottom Half 机制。

很多旧 Driver 或老教材会看到。

可以先知道：

```text
Tasklet
→ 一种传统 Linux 下半部机制
```

现代驱动开发中，如果有更合适的：

```text
Threaded IRQ
Workqueue
```

通常优先使用新的、更清晰的机制。

所以 Tasklet 知道概念即可，不需要把它作为当前学习重点。

---

# 十九、从 MCU / FreeRTOS 映射到 Linux

如果 MCU 中已经习惯：

```c
void UART_IRQHandler(void)
{
    // 清中断
    // 取必要数据
    // 写 Queue
    // 唤醒 Task
}
```

然后：

```text
UART ISR
   ↓
Queue
   ↓
UART Task
   ↓
协议解析
```

那么到 Linux：

```text
Hardware IRQ
   ↓
Hard IRQ
   ↓
Threaded IRQ / Workqueue
   ↓
后续处理
```

设计思想没有变。

所以可以这样对应：

| MCU / FreeRTOS          | Linux                      |
| ----------------------- | -------------------------- |
| NVIC                    | GIC                        |
| NVIC Driver / CMSIS API | irqchip                    |
| IRQn                    | Linux IRQ                  |
| `XXX_IRQHandler()`      | `request_irq()` 注册 Handler |
| ISR                     | Hard IRQ                   |
| ISR → Task Notify       | Hard IRQ → Threaded IRQ    |
| ISR → Queue → Task      | Hard IRQ → Workqueue       |
| ISR 中不能调用普通阻塞 API       | Hard IRQ 中不能睡眠             |
| 中断优先级                   | IRQ Priority               |
| Enable / Disable IRQ    | mask / unmask              |
| Pending Bit             | Pending                    |
| 单核 IRQ                  | SMP IRQ Affinity           |

---

# 二十、一个完整的 Linux 设备中断流程

假设 RK3588 接一个 I2C Sensor：

```text
Sensor
  │
  │ INT Pin
  ↓
GPIO
  ↓
GPIO Interrupt Controller
  ↓
GIC
  ↓
CPU
```

Linux 中可能经历：

```text
Sensor 产生中断
        ↓
GPIO 检测到边沿
        ↓
GPIO Interrupt Controller
        ↓
GIC
        ↓
某个 CPU 收到 IRQ
        ↓
Linux IRQ Core
        ↓
找到对应 irq_desc
        ↓
找到 Driver 注册的 Handler
        ↓
Hard IRQ Handler
        ↓
唤醒 Threaded IRQ
        ↓
Thread Handler
        ↓
i2c_transfer()
        ↓
读取 Sensor 数据
        ↓
交给 IIO / Input 等 Subsystem
```

这条链比 MCU 长很多，但硬件本质还是：

```text
设备发中断
→ CPU 响应
→ 驱动处理
```

Linux 只是把中间的资源管理和执行上下文拆得更加清楚。

---

# 二十一、中断和 Scheduler 是怎么接起来的

Linux 中断不只是“执行一段 Handler”。

它还经常承担：

> **把等待设备事件的 Task 唤醒。**

例如用户程序：

```c
read(fd, buf, len);
```

此时没有数据：

```text
User Process
    ↓
read()
    ↓
Driver
    ↓
Wait Queue
    ↓
Task 进入 Sleeping
```

之后硬件来数据：

```text
Device IRQ
    ↓
GIC
    ↓
IRQ Handler
    ↓
wake_up()
    ↓
Sleeping Task
    ↓
Runnable
```

接下来由：

```text
Scheduler
```

决定这个 Task 什么时候重新获得 CPU。

于是：

```text
Interrupt
Task State
Scheduler
Driver
```

其实是连在一起的。

这也是嵌入式 Linux 面试很喜欢问的一条完整链。

---

# 二十二、Linux 中断真正应该记住的核心

刚开始学习不用陷入 GIC 寄存器细节。

先把这条主线建立起来：

```text
Hardware IRQ
      ↓
Interrupt Controller
      ↓
GIC
      ↓
irqchip
      ↓
Linux IRQ Core
      ↓
request_irq()
      ↓
Driver Hard IRQ Handler
      ↓
Threaded IRQ / Workqueue
      ↓
后续处理
```

其中：

```text
GIC
```

负责实际硬件层面的中断管理和路由。

```text
irqchip
```

把各种 Interrupt Controller 抽象成 Linux 统一接口。

```text
IRQ Core
```

负责管理 Linux IRQ、Handler 和中断执行流程。

```text
Hard IRQ
```

负责必须立即完成的工作，不能睡眠。

```text
Threaded IRQ / Workqueue
```

负责把耗时、可能睡眠的工作延后执行。

---

# 二十三、最后用 MCU 思维重新理解 Linux 中断

MCU / FreeRTOS：

```text
硬件
 ↓
NVIC
 ↓
ISR
 ↓
FromISR API
 ↓
Task
```

Linux：

```text
硬件
 ↓
GIC / 其他 Interrupt Controller
 ↓
irqchip
 ↓
Linux IRQ Core
 ↓
Hard IRQ
 ↓
Threaded IRQ / Workqueue
 ↓
Kernel Thread Context
```

所以 Linux 中断并没有推翻 MCU 的中断模型。

它真正增加的是：

```text
多核 CPU
中断路由
多级中断控制器
统一 IRQ 抽象
严格执行上下文
标准化下半部机制
```

可以把这一篇最后压缩成一句话：

> **MCU 中我们已经会让 ISR 尽量短，并把耗时处理交给 Task；Linux 延续了同样的思想，只是在多核和复杂硬件环境下增加了 GIC、irqchip、IRQ Core 等中断管理层，并进一步把中断处理拆成 Hard IRQ、Threaded IRQ、Workqueue、Softirq 等不同执行上下文。**

对于普通 Embedded Linux Driver（嵌入式 Linux 驱动）开发，现阶段最重要的其实不是把 GIC 所有寄存器背下来，而是知道：

```text
中断从哪里来
↓
Linux 怎么找到 Handler
↓
当前运行在哪种 Context
↓
这个 Context 能不能睡眠
↓
耗时工作应该放到哪里
```

只要这条线真正搞懂，中断这一块就已经有比较扎实的骨架了。