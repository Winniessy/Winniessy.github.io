# RTOS 中的 Thread Flag 与常见同步机制

Thread Flag（线程标志）是 RTOS 里一种比较轻量的**事件通知机制**。严格来说，`osThreadFlagsWait()`、`osThreadFlagsSet()` 这些接口属于 **CMSIS-RTOS2**，并不是 FreeRTOS 原生 API。

如果工程使用的是：

```text
应用代码
   ↓
CMSIS-RTOS2
   ↓
FreeRTOS
```

那么我们虽然写的是：

```c
osThreadFlagsWait();
osThreadFlagsSet();
```

底层实际上还是通过 FreeRTOS 自己的机制完成。

## Thread Flag 是什么

可以把 Thread Flag 理解成：

> 每个线程自己携带的一组事件 bit，其他任务或者中断可以通过设置这些 bit 来通知它发生了某件事。

例如：

```c
#define DMA_DONE     (1U << 0)
#define KEY_EVENT    (1U << 1)
#define REFRESH_REQ  (1U << 2)
```

一个 GUI 任务可以等待其中某个事件：

```c
osThreadFlagsWait(
    DMA_DONE,
    osFlagsWaitAny,
    osWaitForever
);
```

此时如果 DMA 还没完成，GuiTask 会进入 Blocked 状态，不再占用 CPU。

等 DMA 完成后，中断里设置：

```c
osThreadFlagsSet(GuiTaskHandle, DMA_DONE);
```

GuiTask 就会被唤醒。

整个过程大概是：

```text
GuiTask
   ↓
等待 DMA_DONE
   ↓
Blocked

CPU 去执行其他任务

DMA 完成
   ↓
DMA ISR
   ↓
设置 Thread Flag
   ↓
GuiTask → Ready
```

相比一直写：

```c
while (1)
{
    if (dma_done)
        ...
}
```

这种轮询方式，Thread Flag 更符合 RTOS 的事件驱动思想：**没事就阻塞，有事再唤醒。**

---

## Thread Flag 在 FreeRTOS 底层是什么

CMSIS-RTOS2 的 Thread Flag，在 FreeRTOS 中主要是用 **Task Notification（任务通知）**实现的。

最核心的对应关系可以直接记：

```text
CMSIS-RTOS2                   FreeRTOS

osThreadFlagsWait()    →     xTaskNotifyWait()

osThreadFlagsSet()     →     xTaskNotify(..., eSetBits)

中断中 Set Flag        →     xTaskNotifyFromISR(..., eSetBits)
```

例如：

```c
osThreadFlagsSet(
    GuiTaskHandle,
    DMA_DONE
);
```

底层可以近似理解成：

```c
xTaskNotify(
    GuiTaskHandle,
    DMA_DONE,
    eSetBits
);
```

`eSetBits` 表示把 Task Notification 的值当作一个位图来使用。

假设原来：

```text
0000 0000
```

DMA 完成：

```text
0000 0001
```

按键事件又来了：

```text
0000 0011
```

所以同一个任务可以通过不同 bit 区分不同事件。

需要注意的是，Thread Flag 表达的是：

> “这个事件发生了。”

它并不天然记录事件发生了多少次。

例如连续设置三次：

```c
Set(DMA_DONE);
Set(DMA_DONE);
Set(DMA_DONE);
```

最后仍然只是：

```text
DMA_DONE = 1
```

所以如果要求记录事件次数，就应该考虑计数信号量，或者 FreeRTOS Task Notification 的计数模式。

---

## RTOS 里除了 Thread Flag 还有什么

RTOS 中常见的任务同步和通信机制主要还有：

```text
Thread Flag / Task Notification
Event Flag / Event Group
Semaphore
Mutex
Queue
Stream Buffer / Message Buffer
```

它们解决的问题不太一样。

最简单的理解方式是：

| 机制                              | 主要解决的问题         |
| ------------------------------- | --------------- |
| Thread Flag / Task Notification | 通知某个指定任务“有事发生”  |
| Event Flag / Event Group        | 多个事件组合、多个任务之间同步 |
| Semaphore                       | 任务同步或者事件计数      |
| Mutex                           | 保护共享资源          |
| Queue                           | 在任务之间传递数据       |
| Stream / Message Buffer         | 连续数据流或消息传输      |

其中比较容易混的是 Thread Flag、Event Flag 和 Semaphore。

### Thread Flag

Thread Flag 是属于某个具体线程的。

例如：

```text
DMA ISR
   │
   │ DMA_DONE
   ▼
GuiTask
```

意思很明确：

> 告诉 GuiTask：DMA 已经完成了。

所以这种“一个事件通知一个指定任务”的场景，用 Thread Flag 非常合适。

### Event Flag

Event Flag 更像一个独立存在的公共事件集合。

例如：

```text
             Event Flags
          ┌──────────────┐
Task A ──→│ DMA | KEY    │←── Task B
          └──────────────┘
               │
          ┌────┴────┐
          ▼         ▼
       Task C     Task D
```

在 FreeRTOS 里对应的主要就是：

```c
xEventGroupSetBits();
xEventGroupWaitBits();
```

所以可以简单理解成：

```text
Thread Flag
→ 某个任务自己的事件

Event Flag
→ 大家共享的一组事件
```

### Semaphore

Semaphore（信号量）更多用于同步或者计数。

比如生产者产生一次数据：

```text
Producer
   ↓
Give Semaphore
   ↓
Consumer 被唤醒
```

如果使用 Counting Semaphore（计数信号量），还可以记录：

```text
事件发生 3 次
→ count = 3
```

这一点和普通 Thread Flag 不一样。

### Mutex

Mutex（互斥锁）主要不是拿来通知事件，而是保护共享资源。

例如两个任务都要访问 SPI：

```text
Task A ──┐
         ├── Mutex ── SPI
Task B ──┘
```

谁拿到 Mutex，谁访问 SPI，另一个任务等待。

Mutex 解决的是：

> “这个资源现在归谁使用？”

### Queue

Queue（队列）主要用于任务之间真正传数据。

比如：

```c
struct sensor_data {
    float temperature;
    float humidity;
};
```

Producer 产生数据：

```text
Producer
   ↓
{25.3, 60%}
   ↓
Queue
   ↓
Consumer
```

Thread Flag 一般只是告诉你：

```text
“数据来了”
```

Queue 则是直接把：

```text
“数据本身”
```

传过去。

---

## Thread Flag 和超时一起使用

例如：

```c
osThreadFlagsWait(
    GUI_DMA_SERVICE_FLAG,
    osFlagsWaitAny,
    wait_ms
);
```

这里并不是同时执行一个 Delay 和一个 Thread Flag Wait。

实际含义是：

> 最多等待 `wait_ms`，但如果 Thread Flag 提前到来，就立即结束等待。

因此有两条路径：

```text
              osThreadFlagsWait()
                     │
          ┌──────────┴──────────┐
          │                     │
       Flag 到来             wait_ms 到期
          │                     │
          ▼                     ▼
       提前唤醒               超时唤醒
          └──────────┬──────────┘
                     ▼
                 GuiTask运行
```

这也是 GUI 周期任务里很常见的一种写法。

例如 GUI 希望大约每 5 ms 运行一次，但 DMA 完成后又希望立即处理，那么可以：

```text
正常情况
GuiTask ───── 等到 5 ms ─────→ 运行

DMA 提前完成
GuiTask ── DMA Flag ─→ 提前运行
```

这样既保留了周期性，又能及时响应异步事件。

---

## 总结

RTOS 里的这些机制可以先简单记成：

```text
通知某个任务
→ Thread Flag / Task Notification

多个 bit 事件同步
→ Event Flag / Event Group

同步、计数
→ Semaphore

保护共享资源
→ Mutex

传递数据
→ Queue
```

而 CMSIS-RTOS2 中：

```c
osThreadFlagsWait()
```

在 FreeRTOS 底层主要就是：

```c
xTaskNotifyWait()
```

`osThreadFlagsSet()` 则主要对应：

```c
xTaskNotify(..., eSetBits)
```

如果在 ISR 中，则使用：

```c
xTaskNotifyFromISR(..., eSetBits)
```

所以以后看到 Thread Flag，可以先把它理解成：

> **FreeRTOS Task Notification 的 bit 事件模式，只不过 CMSIS-RTOS2 给它套了一层更加统一、直观的 API。**