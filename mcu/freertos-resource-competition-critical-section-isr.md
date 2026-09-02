# FreeRTOS 资源竞争、临界区与 ISR 中断安全机制

在 FreeRTOS 中，只要多个执行上下文可能同时访问同一份数据，就可能产生资源竞争（Resource Competition / Race Condition，资源竞争 / 竞态条件）。

这里的“多个执行上下文”主要有两种：

```text
Task ↔ Task
任务 ↔ 任务

Task ↔ ISR
任务 ↔ 中断服务程序
```

这两类竞争看起来很像，但处理方法并不完全一样。理解这一点之后，`vTaskSuspendAll()`、`taskENTER_CRITICAL()`、`xxxFromISR()` 和 `BASEPRI` 之间的关系就比较清楚了。

---

## 任务之间的资源竞争

假设两个任务都要修改一个全局变量：

```c
int count = 0;

void TaskA(void *arg)
{
    count++;
}

void TaskB(void *arg)
{
    count++;
}
```

`count++` 并不是一条不可分割的操作，它实际上可以理解成：

```text
读取 count
    ↓
加 1
    ↓
写回 count
```

如果 TaskA 执行到一半被 TaskB 抢占，就可能出现两个任务都读到相同旧值，最后丢失一次更新。

因此需要保证这一小段操作执行期间，其他任务不能插进来。

如果这个资源**只会被任务访问，不会被 ISR 访问**，一种方法就是挂起调度器（Suspend Scheduler）：

```c
vTaskSuspendAll();

count++;

/* 恢复调度 */
xTaskResumeAll();
```

`vTaskSuspendAll()` 的作用不是关闭中断，而是：

> FreeRTOS 暂时不进行任务调度。

因此当前任务不会被另一个任务切走。

但是中断仍然可以正常响应。

可以简单理解成：

```text
vTaskSuspendAll()

Task A
  |
  |------ 不会切换到 Task B
  |
  |------ ISR 仍然可能进来
  |
Task A
```

所以挂起调度器只能解决：

```text
Task ↔ Task
```

之间的竞争。

如果 ISR 也会访问这份数据，那么仅仅挂起调度器是不够的。

---

## 为什么任务和 ISR 共享数据时需要临界区

假设任务和 UART ISR（串口中断服务程序）共享一个变量：

```c
volatile int count;
```

任务：

```c
void TaskA(void *arg)
{
    vTaskSuspendAll();

    count++;

    xTaskResumeAll();
}
```

ISR：

```c
void USART_IRQHandler(void)
{
    count++;
}
```

即使任务已经调用：

```c
vTaskSuspendAll();
```

UART 中断仍然可能发生：

```text
TaskA 读取 count
        ↓
       UART ISR
        ↓
      count++
        ↓
      ISR 返回
        ↓
TaskA 写回旧值 + 1
```

结果仍然可能出错。

所以，如果共享资源会被：

```text
Task + ISR
```

共同访问，就必须进一步限制中断。

FreeRTOS 中通常使用：

```c
taskENTER_CRITICAL();

/* 临界区 */

taskEXIT_CRITICAL();
```

所谓临界区（Critical Section），本质就是：

> 这段代码执行期间，不允许能够与它产生竞争的执行上下文进入。

这里有一个容易误解的地方：

> FreeRTOS 的 `taskENTER_CRITICAL()` 并不一定意味着“关闭所有中断”。

在 Cortex-M3/M4/M7 等处理器上，FreeRTOS 通常通过 `BASEPRI` 实现临界区，只屏蔽一部分中断。

---

# BASEPRI 是什么

`BASEPRI` 是 ARM Cortex-M 内核中的一个特殊寄存器，可以理解为：

> 中断优先级屏蔽门槛（Interrupt Priority Mask Threshold，中断优先级屏蔽阈值）。

Cortex-M 的中断优先级有一个很重要的规则：

```text
数字越小，优先级越高。
```

例如：

```text
0    最高
1
2
3
4
5
...
15   最低
```

假设：

```text
BASEPRI = 5
```

那么可以粗略理解为：

```text
0    可以响应
1    可以响应
2    可以响应
3    可以响应
4    可以响应
---------------- BASEPRI = 5
5    被屏蔽
6    被屏蔽
7    被屏蔽
...
15   被屏蔽
```

也就是说：

> `BASEPRI` 不会把所有中断都关闭，而是只屏蔽优先级低于某个门槛的中断。

这和 `PRIMASK` 不一样。

`PRIMASK` 更接近我们平时所说的：

```c
__disable_irq();
```

也就是全局关闭大部分普通可屏蔽中断。

而 `BASEPRI` 更灵活：

```text
特别紧急的高优先级中断
        ↓
      仍然运行

----------------

普通中断 / RTOS相关中断
        ↓
      暂时屏蔽
```

所以 FreeRTOS 可以在保护内核数据结构的同时，仍然保证真正紧急的硬实时中断得到响应。

---

# BASEPRI 和 FreeRTOS 中断优先级的关系

FreeRTOS 中经常会看到：

```c
configMAX_SYSCALL_INTERRUPT_PRIORITY
```

它定义了一个中断优先级边界。

假设逻辑中断优先级范围是：

```text
0 ~ 15
```

并配置：

```c
configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY = 5;
```

那么大致可以划分为：

```text
0
1
2
3
4
--------------------------
5
6
7
...
15
```

其中：

```text
0 ~ 4
```

属于非常高优先级的中断。

这些中断不会被 FreeRTOS 的 `BASEPRI` 临界区屏蔽，因此即使 FreeRTOS 正在操作任务列表、Queue（队列）等内部结构，它们仍然可以抢占 CPU。

所以这些中断有一个重要限制：

> 不能调用 FreeRTOS API。

因为 FreeRTOS 可能正在修改自己的内核数据结构，这时候如果一个高优先级 ISR 也进去修改队列、任务列表等内容，就可能破坏内核状态。

而：

```text
5 ~ 15
```

这些中断会受到 FreeRTOS 临界区的保护。

所以它们可以调用：

```c
xQueueSendFromISR()
xSemaphoreGiveFromISR()
vTaskNotifyGiveFromISR()
```

这一类 ISR 专用 API。

因此可以记成：

```text
高优先级 ISR
    ↓
FreeRTOS 管不了它
    ↓
不能调用 FreeRTOS API


普通 ISR
    ↓
会被 BASEPRI 临界区保护
    ↓
可以调用 xxxFromISR()
```

---

# 为什么 ISR 要使用 FromISR 版本

FreeRTOS 很多 API 都有两套：

```c
xQueueSend()
xQueueSendFromISR()

xSemaphoreGive()
xSemaphoreGiveFromISR()

xTaskNotify()
xTaskNotifyFromISR()
```

`FromISR` 的意思就是：

```text
From Interrupt Service Routine
供中断服务程序调用
```

之所以需要单独设计 ISR 版本，最核心的原因是：

> ISR 和 Task 的运行规则不同。

---

## ISR 不能阻塞

普通任务可以这样发送 Queue：

```c
xQueueSend(queue, &data, portMAX_DELAY);
```

如果 Queue 满了，这个任务可以进入：

```text
Running
   ↓
Blocked
```

等其他任务把 Queue 中的数据取走之后，再恢复执行。

但 ISR 不可以这样做。

假设：

```c
void USART_IRQHandler(void)
{
    xQueueSend(queue, &data, portMAX_DELAY);
}
```

Queue 满了以后怎么办？

ISR 不可能说：

```text
我先睡一会儿，
等 Queue 有位置了再继续处理中断。
```

因为 ISR 本身就是一次硬件中断处理流程，它必须执行结束，然后退出异常现场。

所以：

```c
xQueueSendFromISR()
```

一定是非阻塞的。

如果 Queue 满了：

```text
直接返回失败
```

而不是让 ISR 等待。

这也是 `FromISR` API 最重要的设计原则之一：

> ISR API 不能阻塞。

---

# ISR 唤醒高优先级任务之后怎么办

假设：

```text
Task A：优先级 2，正在运行
Task B：优先级 5，正在等待 Queue
```

现在 UART 中断发生：

```text
Task A
   ↓
UART ISR
```

ISR 收到数据以后：

```c
xQueueSendFromISR();
```

于是正在等待 Queue 的 Task B 被唤醒：

```text
Task B:
Blocked → Ready
```

由于：

```text
Task B 优先级 5
Task A 优先级 2
```

正常情况下，Task B 应该立即抢占 Task A。

但现在有一个问题：

> 此刻 CPU 还在 ISR 里面。

不能直接从 `xQueueSendFromISR()` 内部跳到 Task B。

所以 FreeRTOS 使用：

```c
BaseType_t xHigherPriorityTaskWoken = pdFALSE;
```

例如：

```c
void USART_IRQHandler(void)
{
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;

    xQueueSendFromISR(
        queue,
        &data,
        &xHigherPriorityTaskWoken
    );

    portYIELD_FROM_ISR(xHigherPriorityTaskWoken);
}
```

如果这次 Queue 操作唤醒了一个更高优先级任务：

```c
xHigherPriorityTaskWoken = pdTRUE;
```

那么：

```c
portYIELD_FROM_ISR();
```

会请求一次任务切换。

在 Cortex-M 中，通常就是 PendSV：

```text
UART ISR
    ↓
xQueueSendFromISR()
    ↓
Task B: Blocked → Ready
    ↓
xHigherPriorityTaskWoken = pdTRUE
    ↓
PendSV 被设置为 Pending
    ↓
UART ISR 退出
    ↓
PendSV 执行
    ↓
上下文切换
    ↓
Task B Running
```

因此 `FromISR` API 并不会直接进行普通任务上下文下的调度，而是：

> 告诉系统：“中断结束之后应该重新调度了。”

---

# 为什么 ISR 的临界区也有 FromISR 版本

FreeRTOS 还有：

```c
taskENTER_CRITICAL_FROM_ISR()
taskEXIT_CRITICAL_FROM_ISR()
```

典型写法：

```c
UBaseType_t uxSavedInterruptStatus;

uxSavedInterruptStatus = taskENTER_CRITICAL_FROM_ISR();

/* ISR 临界区 */

taskEXIT_CRITICAL_FROM_ISR(uxSavedInterruptStatus);
```

这里和任务版本的一个重要区别是：

> ISR 需要保存进入临界区之前的中断屏蔽状态。

因为当前 ISR 运行的时候，`BASEPRI` 有可能已经不是默认值。

例如进入 ISR 时：

```text
BASEPRI = 某个值
```

ISR 又临时设置了新的屏蔽级别。

退出临界区的时候，正确做法是：

```text
恢复原来的 BASEPRI
```

而不是简单粗暴地：

```text
BASEPRI = 0
```

否则就可能把原来已经屏蔽的中断错误地重新打开。

所以 ISR 临界区通常是这样的思路：

```text
保存当前 BASEPRI
        ↓
设置新的 BASEPRI
        ↓
执行临界区
        ↓
恢复原来的 BASEPRI
```

这也是为什么 ISR 中需要专门的 `FromISR` 临界区接口。

---

# 挂起调度器、临界区和互斥锁怎么选

理解完上面的内容之后，可以用一个非常简单的判断方式。

如果共享资源只存在于：

```text
Task ↔ Task
```

之间，可以考虑：

```text
Mutex（互斥锁）
```

或者在一些很短、不允许切换任务的内部操作中使用：

```text
vTaskSuspendAll()
```

其中 Mutex 更适合一般的任务间资源保护，因为一个任务拿不到 Mutex 时可以阻塞，让 CPU 去运行其他任务。

如果共享资源存在于：

```text
Task ↔ ISR
```

之间，就不能使用普通 Mutex，因为 ISR 不能阻塞。

这时通常考虑：

```text
Critical Section（临界区）
Atomic（原子操作）
Queue（队列）
Stream Buffer（流缓冲区）
Task Notification（任务通知）
```

具体选择取决于数据类型和业务场景。

可以粗略总结成：

| 场景                  | 常见方式                                      |
| ------------------- | ----------------------------------------- |
| Task ↔ Task         | Mutex / Semaphore                         |
| 只想暂时禁止任务调度          | `vTaskSuspendAll()`                       |
| Task ↔ ISR 共享简单数据   | Critical Section / Atomic                 |
| ISR 向 Task 发送数据     | Queue / Stream Buffer / Task Notification |
| ISR 调用 FreeRTOS API | `xxxFromISR()`                            |

---

# 整体关系

把这些机制串起来，其实逻辑很简单：

```text
资源竞争
   │
   ├── Task ↔ Task
   │       │
   │       ├── Mutex
   │       └── Suspend Scheduler
   │
   └── Task ↔ ISR
           │
           ├── Critical Section
           │       │
           │       └── Cortex-M 中常通过 BASEPRI 实现
           │
           └── FreeRTOS 通信 API
                   │
                   └── 使用 xxxFromISR()
```

而 `BASEPRI` 又把 ISR 分成两类：

```text
高优先级 ISR
    │
    ├── 不被 FreeRTOS 临界区屏蔽
    └── 不能调用 FreeRTOS API


普通 ISR
    │
    ├── 会被 BASEPRI 临界区屏蔽
    └── 可以调用 xxxFromISR()
```

所以 FreeRTOS 的设计并不是简单地：

```text
进入临界区 = 关闭所有中断
```

而更接近：

```text
进入临界区
    ↓
禁止任务调度相关的并发
    ↓
屏蔽可能访问 FreeRTOS 内核的中断
    ↓
仍然允许真正紧急的高优先级中断响应
```

这也是 `BASEPRI` 存在的意义。

---

## 最后记忆

可以把这一整套机制浓缩成几句话：

> `vTaskSuspendAll()` 只是暂停任务调度，中断仍然可以运行，所以主要解决任务与任务之间的竞争。

> `taskENTER_CRITICAL()` 用于临界区保护，在 Cortex-M3/M4/M7 等平台上通常通过 `BASEPRI` 屏蔽一定优先级范围内的中断，而不是简单关闭所有中断。

> `BASEPRI` 本质上是一条中断优先级门槛。FreeRTOS 利用它保护内核数据，同时允许更高优先级的紧急中断继续运行。

> ISR 不能阻塞，也不能按照普通任务的方式直接调度，因此调用 FreeRTOS 时要使用 `xxxFromISR()`。如果 ISR 唤醒了更高优先级任务，通过 `xHigherPriorityTaskWoken` 和 `portYIELD_FROM_ISR()` 请求在中断退出后完成上下文切换。

> 能调用 FreeRTOS API 的 ISR 必须处于 FreeRTOS 可以通过 `BASEPRI` 管理的优先级范围内；那些优先级特别高、不会被 FreeRTOS 临界区屏蔽的 ISR，则不能调用 FreeRTOS API。