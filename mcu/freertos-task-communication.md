# FreeRTOS 任务间通信机制总结

FreeRTOS 中任务之间不仅需要“传数据”，还经常需要解决另外两类问题：

- 一个任务怎么通知另一个任务“有事情发生了”；
- 多个任务同时访问同一个外设或共享资源时，怎么避免冲突。

所以严格来说，FreeRTOS 里的这些机制可以分成三类：

```text
任务间通信 / 同步
│
├── 数据传递
│   ├── Queue
│   ├── Stream Buffer
│   └── Message Buffer
│
├── 事件与同步
│   ├── Binary Semaphore
│   ├── Counting Semaphore
│   ├── Event Group / Event Flag
│   └── Task Notification
│
└── 资源互斥
    ├── Mutex
    └── Recursive Mutex
```

真正使用时，不应该单纯记 API，而应该先想清楚：

> 我要传的是“数据”、一个“事件”，还是我要保护一个“共享资源”？

---

# 1. Queue：最通用的数据传递方式

Queue 是 FreeRTOS 最典型的任务间通信机制。

官方文档将 Queue 称为：

> primary form of inter-task communication

它最适合解决的问题是：

```text
生产者产生一条数据
        ↓
      Queue
        ↓
消费者取出并处理
```

例如：

```text
SensorTask
    │
    │ SensorData
    ↓
  Queue
    ↓
StorageTask
```

## 1.1 Queue 的基本原理

创建一个队列：

```c
QueueHandle_t sensor_queue;

sensor_queue = xQueueCreate(
    10,
    sizeof(SensorData_t)
);
```

这里的含义是：

```text
最多保存 10 个 SensorData_t
```

发送：

```c
xQueueSend(
    sensor_queue,
    &data,
    portMAX_DELAY
);
```

接收：

```c
xQueueReceive(
    sensor_queue,
    &data,
    portMAX_DELAY
);
```

如果 Queue 为空，接收任务可以进入 Blocked 状态。

等到生产者发送数据后：

```text
Blocked
   ↓
Queue 有数据
   ↓
Ready
   ↓
等待调度
```

因此不需要自己循环查询：

```c
while (queue_empty)
{
}
```

这一点很重要，因为 RTOS 很大一部分意义就在于：

> 没有事情做的任务应该阻塞，而不是占着 CPU 空转。

---

## 1.2 Queue 默认传的是数据副本

比如：

```c
int value = 100;

xQueueSend(queue, &value, 0);
```

Queue 内部会保存 `value` 的副本。

可以简单理解成：

```text
value
  │
  │ copy
  ↓
Queue 内部存储空间
```

所以发送完成以后，即使：

```c
value = 200;
```

Queue 里面原来的 `100` 不会受影响。

这也是 Queue 使用起来比较安全、直观的原因。

---

## 1.3 大数据不要直接塞 Queue

假设：

```c
typedef struct
{
    uint8_t image[4096];
} Frame_t;
```

如果直接：

```c
xQueueSend(queue, &frame, ...);
```

每次都需要复制几 KB 数据。

这种方式效率很差。

工程里通常会改成：

```c
typedef struct
{
    uint8_t *buffer;
    uint32_t len;
} FrameMsg_t;
```

Queue 中只传：

```text
buffer 指针
长度
状态信息
```

而真正的大块数据放在另外的 Buffer 中。

不过这样做以后，必须自己保证：

- Buffer 生命周期；
- 什么时候可以复用；
- 谁负责释放；
- 生产者不能在消费者使用期间修改数据。

所以：

> Queue 传值简单安全；Queue 传指针效率高，但内存所有权需要自己设计。

---

## 1.4 Queue 的优点

- 可以真正传递数据；
- 支持阻塞等待；
- 支持 FIFO；
- 支持多个生产者；
- 支持多个消费者；
- 支持 ISR 通过 `FromISR` API 向 Queue 发数据；
- 很适合生产者—消费者模型。

---

## 1.5 Queue 的缺点

主要是两个：

### 数据拷贝

```text
Producer
   ↓ copy
Queue
   ↓ copy
Consumer
```

数据越大，成本越明显。

### RAM 占用

例如：

```text
Queue 深度 = 100
每个元素 = 64 Byte
```

单纯数据区就需要：

```text
100 × 64 = 6400 Byte
```

所以在 MCU 上，Queue 长度和 item 大小都不能随便定。

---

## 1.6 适合什么场景

典型：

```text
SensorTask → Queue → StorageTask
```

或者：

```text
GuiTask ─────┐
SensorTask ──┼──→ StorageQueue → StorageTask
SysTask ─────┘
```

后者就是典型的：

```text
MPSC
Multiple Producer
Single Consumer
```

例如日志、Flash 写入、文件系统操作，经常会这么设计。

---

# 2. Binary Semaphore：告诉任务“发生了一件事”

Binary Semaphore 和 Queue 最大的区别是：

```text
Queue：
“有数据来了，而且数据是 XXX”

Binary Semaphore：
“有事情发生了”
```

它不负责保存具体数据。

Binary Semaphore 只有两个状态：

```text
0
1
```

可以把它理解成一个只有“有 / 无”状态的信号。

---

## 2.1 一个典型场景

例如 DMA 完成：

```text
ADC DMA
   ↓
DMA Complete ISR
   ↓ Give
Binary Semaphore
   ↓ Take
SensorTask
```

ISR：

```c
xSemaphoreGiveFromISR(
    sem,
    &xHigherPriorityTaskWoken
);
```

任务：

```c
xSemaphoreTake(
    sem,
    portMAX_DELAY
);
```

意思是：

> DMA 已经完成，现在可以开始处理 Buffer 了。

真正的数据并不放在 Semaphore 里，通常已经在 DMA Buffer 中。

---

## 2.2 Binary Semaphore 的一个重要特点

假设中断连续发生：

```text
Give
Give
Give
Give
```

任务一直没来得及处理。

Binary Semaphore 最终仍然只是：

```text
1
```

它只能告诉任务：

> 这个事件至少发生过一次。

但不能告诉任务：

> 这个事件发生了四次。

如果需要保留次数，就应该考虑 Counting Semaphore。

---

## 2.3 优点

- 使用简单；
- 很适合事件同步；
- 支持 ISR → Task；
- 可以让任务阻塞等待事件。

## 2.4 缺点

- 不携带数据；
- 不保存事件发生次数；
- 如果只是通知一个固定任务，很多情况下 Task Notification 更轻量。

---

# 3. Counting Semaphore：Binary Semaphore 加上计数能力

Counting Semaphore 和 Binary Semaphore 的区别，可以简单理解成：

```text
Binary Semaphore：

count = 0 / 1
```

而：

```text
Counting Semaphore：

count = 0 ~ N
```

---

# 3.1 用法一：统计事件次数

例如一个中断发生三次：

```text
第一次 Give → count = 1
第二次 Give → count = 2
第三次 Give → count = 3
```

任务处理一次：

```text
Take → count = 2
```

因此 Counting Semaphore 可以记录：

> 有多少个事件还没有被处理。

---

# 3.2 用法二：管理有限资源

假设系统只有 4 个 Buffer：

```text
count = 4
```

一个任务申请：

```text
Take
```

变成：

```text
3
```

又一个任务申请：

```text
2
```

释放一个：

```text
Give
```

恢复成：

```text
3
```

所以 Counting Semaphore 也可以表示：

> 当前还有多少份相同资源可以使用。

---

## 3.3 优缺点

优点：

- 能统计事件；
- 能管理固定数量的资源；
- 支持多个任务或 ISR 产生事件。

缺点：

- 还是不能携带具体数据；
- 只能知道“有几个”，不知道“分别是什么”。

如果只是：

```text
ISR → 固定一个 Task
```

并且只是需要计数，Task Notification 的计数模式往往更加轻量。

---

# 4. Mutex：保护共享资源

Mutex 和 Semaphore 虽然 API 看起来很像，但使用目的完全不同。

Mutex 解决的问题是：

> 多个任务同时访问一个共享资源怎么办？

例如：

```text
SensorTask ─┐
            ├── I2C
GuiTask ────┘
```

假设两个任务同时操作 I2C：

```text
Task A: START
Task B: START
Task A: ADDRESS
Task B: DATA
```

总线状态就可能被破坏。

所以：

```text
SensorTask ─┐
            ↓
          Mutex
            ↓
           I2C
            ↑
GuiTask ────┘
```

---

## 4.1 使用方式

```c
xSemaphoreTake(i2c_mutex, portMAX_DELAY);

I2C_Transfer();

xSemaphoreGive(i2c_mutex);
```

只有拿到 Mutex 的任务才能进入临界区域。

---

# 4.2 Mutex 最重要的特性：优先级继承

这是 Mutex 和 Binary Semaphore 一个非常重要的区别。

假设：

```text
High Task      优先级 5
Medium Task    优先级 3
Low Task       优先级 1
```

Low 先获得 Mutex。

随后 High 也需要这个 Mutex：

```text
High
 ↓
等待 Low
```

这时如果 Medium 一直抢占 Low：

```text
Medium
Medium
Medium
Medium
```

就会出现：

```text
High 等 Low
Low 又一直被 Medium 抢占
```

最终变成：

> 高优先级任务被一个中优先级任务间接阻塞。

这就是：

```text
Priority Inversion
优先级反转
```

Mutex 会进行优先级继承：

```text
Low 原优先级 = 1

High 等待 Low 持有的 Mutex

↓

Low 临时继承 High 的优先级

Low = 5
```

这样 Low 就能尽快运行，把 Mutex 释放。

释放以后，再恢复原来的优先级。

---

# 4.3 为什么不能用 Binary Semaphore 代替 Mutex

有些代码确实会这么写：

```text
Binary Semaphore
      ↓
保护 I2C
```

从“同一时刻只能一个任务进入”的角度看，好像也能工作。

但 Binary Semaphore 没有 Mutex 的：

```text
Priority Inheritance
```

所以如果是：

> Task 和 Task 之间保护共享资源

应该优先使用 Mutex。

---

# 4.4 为什么 ISR 不能拿 Mutex

ISR 不能阻塞。

而 Mutex 的典型逻辑是：

```text
Mutex 被别人占用
      ↓
当前 Task Blocked
      ↓
等待释放
```

ISR 显然不能这么做。

另外，优先级继承针对的是任务优先级，不是 NVIC 中断优先级。

所以 Mutex 应该用于：

```text
Task ↔ Task
```

而不是：

```text
ISR ↔ Task
```

---

# 5. Recursive Mutex：允许同一个任务重复加锁

普通 Mutex 在多层函数调用中可能出现：

```c
funcA()
{
    TakeMutex();

    funcB();

    GiveMutex();
}

funcB()
{
    TakeMutex();

    ...

    GiveMutex();
}
```

如果 `funcA()` 已经拿到了 Mutex，进入 `funcB()` 后又尝试获取同一个 Mutex，就可能把自己堵住。

Recursive Mutex 允许同一个任务：

```text
Take
Take
Take
```

但相应地也必须：

```text
Give
Give
Give
```

直到 Take 和 Give 次数匹配，Mutex 才真正释放。

这种机制适合：

- 多层库调用；
- 文件系统；
- 复杂驱动；
- API 内部可能再次进入同一个受保护模块。

不过如果代码大量依赖 Recursive Mutex，通常也应该检查一下软件架构是不是已经过于复杂。

---

# 6. Event Group / Event Flag：一个任务同时等待多个事件

这一组概念很容易被术语搞乱。

在原生 FreeRTOS 中：

```text
Event Group
```

是一组事件位。

其中每一个 bit 可以称为：

```text
Event Bit
Event Flag
```

比如：

```text
Event Group

bit0    bit1    bit2    bit3

Touch   RTC     USB    Sensor
```

所以 Event Flag 并不是 FreeRTOS 中另外一套独立于 Event Group 的机制。

更准确地说：

> Event Group 是对象，Event Flag 是里面的某一个事件位。

---

# 6.1 为什么需要 Event Group

假设一个 SysTask 同时关心：

```text
Touch
RTC Alarm
USB
Charger
```

如果给每一个事件单独创建一个 Binary Semaphore：

```text
Touch   → Sem1
RTC     → Sem2
USB     → Sem3
Charger → Sem4
```

就会出现一个问题：

> 一个任务怎么同时阻塞等待这四个 Semaphore？

Event Group 就适合这种需求。

```c
#define EVT_TOUCH      (1 << 0)
#define EVT_RTC        (1 << 1)
#define EVT_USB        (1 << 2)
#define EVT_CHARGER    (1 << 3)
```

然后：

```c
bits = xEventGroupWaitBits(
    event_group,
    EVT_TOUCH |
    EVT_RTC |
    EVT_USB |
    EVT_CHARGER,
    pdTRUE,
    pdFALSE,
    portMAX_DELAY
);
```

唤醒之后：

```c
if (bits & EVT_TOUCH)
{
    HandleTouch();
}

if (bits & EVT_RTC)
{
    HandleRTC();
}
```

---

# 6.2 Event Group 最核心的能力：Wait Any / Wait All

### 等任意一个

```text
Touch
 OR
RTC
 OR
USB
```

任何一个发生，任务都可以继续运行。

对应：

```text
xWaitForAllBits = pdFALSE
```

---

### 等所有条件

比如系统启动时：

```text
Sensor Ready
AND
Storage Ready
AND
Display Ready
```

全部准备好以后：

```text
MainTask
    ↓
继续启动系统
```

对应：

```text
xWaitForAllBits = pdTRUE
```

---

# 6.3 Event Group 很适合表示系统状态

例如：

```text
WIFI_CONNECTED
NETWORK_READY
SENSOR_READY
STORAGE_READY
```

多个任务都可以查看同一个 Event Group。

因此它也适合：

```text
一个状态
 ↓
多个 Task 都关心
```

例如：

```text
       WIFI_CONNECTED
              │
       Event Group
       ┌──────┼──────┐
       ↓      ↓      ↓
   CloudTask GuiTask OTA Task
```

---

# 6.4 Event Group 的不足

它仍然不适合传数据。

它只能告诉你：

```text
UART_RX 事件发生了
```

不能告诉你：

```text
收到的数据是 "Hello"
```

另外它也不保存事件发生次数。

例如：

```text
Set bit0
Set bit0
Set bit0
```

最终：

```text
bit0 = 1
```

所以它表达的是：

> 某个事件已经发生 / 某个状态当前成立。

而不是：

> 这个事件发生了三次。

---

# 6.5 CMSIS-RTOS2 里的 Event Flags

STM32 工程中经常能看到：

```c
osEventFlagsNew()
osEventFlagsSet()
osEventFlagsWait()
```

这是 CMSIS-RTOS2 的接口。

如果底层是 FreeRTOS，大致可以理解为：

```text
CMSIS-RTOS2               FreeRTOS

osEventFlagsNew()      →  Event Group
osEventFlagsSet()      →  xEventGroupSetBits()
osEventFlagsWait()     →  xEventGroupWaitBits()
```

所以看到 Event Flags 不要以为 FreeRTOS 又多了一种完全不同的 IPC。

本质仍然是：

```text
多个 bit
表示多个事件
```

---

# 7. Task Notification：直接通知某一个任务

Task Notification 是 FreeRTOS 中一个非常实用，而且容易被低估的机制。

它最大的特点是：

> 不需要额外创建 Queue、Semaphore 或 Event Group 对象，而是直接修改目标 Task 自己的 Notification 状态。

可以理解成每一个 Task 自带一个“小邮箱”。

```text
                Task TCB

            ┌──────────────┐
ISR ───────→│ Notification │
Task A ────→│ Value        │
            └──────────────┘
```

---

# 7.1 Task Notification 能干什么

它非常灵活，可以模拟很多其他机制。

## 当 Binary Semaphore 用

```text
ISR
 ↓ Notify
Task Wakeup
```

常见：

```c
vTaskNotifyGiveFromISR();
ulTaskNotifyTake();
```

---

## 当 Counting Semaphore 用

每通知一次：

```text
Notification Value++
```

任务处理一次再减掉。

---

## 当 Event Flags 用

可以：

```c
xTaskNotify(
    task,
    EVENT_DMA_DONE,
    eSetBits
);
```

例如：

```text
bit0 → DMA Done
bit1 → Timeout
bit2 → Error
```

此时它就有点像一个属于单独 Task 的轻量 Event Group。

---

## 当 32-bit 数据使用

Notification Value 本身还可以携带一个 32-bit 值。

所以一些很简单的数据通知也可以直接完成。

---

# 7.2 为什么 Task Notification 很快

传统 Semaphore：

```text
Sender
   ↓
Semaphore Object
   ↓
Receiver
```

Task Notification：

```text
Sender
   ↓
Target Task
```

中间没有单独的 IPC 对象。

因此通常：

- RAM 更少；
- 操作更快；
- API 路径更短。

---

# 7.3 Task Notification 最大的限制

它绑定具体 Task。

例如：

```text
DMA ISR
   ↓
SensorTask
```

非常合适。

但如果是：

```text
Message
   ↓
Task A / Task B 谁有空谁处理
```

Task Notification 就不合适。

因为 Notification 是：

```text
这个 Task 自己的 Notification
```

不像 Queue 是一个独立 IPC 对象。

所以可以简单记：

```text
固定通知一个任务
        ↓
Task Notification

消息属于一个公共队列
        ↓
Queue
```

---

# 8. Stream Buffer：连续字节流

Stream Buffer 适合：

> 连续的数据流，而不是一条一条消息。

例如 UART：

```text
UART RX

48 65 6C 6C 6F 0D 0A
          ↓
    Stream Buffer
          ↓
      ParserTask
```

它看到的只是：

```text
连续 Byte
```

并不知道：

```text
哪里是一条消息的开始
哪里是一条消息的结束
```

消息边界需要上层协议自己解析。

---

# 8.1 为什么 UART 很适合 Stream Buffer

如果 UART 每收到一个 Byte 就放一个 Queue：

```text
Byte
 ↓
Queue Item
```

大量数据下 Queue 的管理开销会比较大。

Stream Buffer 更像一个专门用于连续数据流的环形缓冲区：

```text
Producer
   ↓
[ A B C D E F G H ... ]
   ↓
Consumer
```

很适合：

- UART；
- TCP 数据流；
- Audio PCM；
- 连续传感器数据；
- SPI 数据流。

---

# 8.2 Stream Buffer 的一个关键限制

FreeRTOS 默认假设：

```text
Single Writer
Single Reader
```

也就是：

```text
SPSC
```

例如：

```text
UART ISR
   ↓
Stream Buffer
   ↓
UART Task
```

非常自然。

但：

```text
Task A ─┐
Task B ─┼→ Stream Buffer
Task C ─┘
```

就不是它最适合的使用方式。

如果一定要多个 Writer，需要自己增加同步。

---

# 9. Message Buffer：保留消息边界的变长数据

Message Buffer 和 Stream Buffer 看起来比较像。

区别可以直接记：

```text
Stream Buffer
    ↓
连续字节流

Message Buffer
    ↓
一条一条完整消息
```

例如：

Stream Buffer：

```text
ABCDEFG123456XYZ
```

至于：

```text
ABC
DEFG123
456XYZ
```

怎么划分，需要协议层自己判断。

Message Buffer 则可以保存：

```text
[ABC]

[DEFG123]

[456XYZ]
```

每次读取能够拿到一条完整消息。

---

# 9.1 Queue 和 Message Buffer 的区别

Queue：

```text
固定大小元素

[16 Byte]
[16 Byte]
[16 Byte]
```

Message Buffer：

```text
变长消息

[5 Byte]
[30 Byte]
[100 Byte]
```

所以如果协议消息长度变化比较大，Message Buffer 会更加方便。

---

# 9.2 Message Buffer 的限制

Message Buffer 底层基于 Stream Buffer。

所以同样默认：

```text
Single Writer
Single Reader
```

即 SPSC。

因此：

```text
Task A
  ↓
Message Buffer
  ↓
Task B
```

是很适合的。

如果很多 Task 同时写，就需要额外考虑同步。

---

# 10. 几种机制放在一起怎么理解

| 机制                 | 核心作用          | 是否传数据 | 是否记录次数 | 典型场景          |
| ------------------ | ------------- | -----: | -----: | ------------- |
| Queue              | 消息传递          |      是 |      是 | 生产者—消费者       |
| Binary Semaphore   | 事件同步          |      否 |      否 | DMA 完成通知      |
| Counting Semaphore | 事件计数 / 资源计数   |      否 |      是 | N 次事件、N 个资源   |
| Mutex              | 共享资源互斥        |      否 |      - | I2C、SPI、共享对象  |
| Recursive Mutex    | 可重复加锁的 Mutex  |      否 |      - | 多层 API        |
| Event Group        | 多事件状态 / 组合等待  |    bit |      否 | 多事件、系统状态      |
| Task Notification  | 固定 Task 的轻量通知 | 32-bit |      可 | ISR → 固定 Task |
| Stream Buffer      | 连续字节流         |      是 |      - | UART、Audio    |
| Message Buffer     | 可变长度消息        |      是 |      是 | 变长协议消息        |

---

# 11. 实际开发时怎么选

我现在更习惯先问几个问题。

---

## 11.1 我要不要传数据？

### 要

继续看数据类型。

#### 固定结构体 / 一条条消息

```text
Queue
```

例如：

```c
typedef struct
{
    uint32_t timestamp;
    float temperature;
} SensorData_t;
```

---

#### 连续 Byte Stream

```text
Stream Buffer
```

例如：

```text
UART RX
Audio PCM
TCP Stream
```

---

#### 长度不固定，但有明确消息边界

```text
Message Buffer
```

---

## 11.2 不传数据，只通知事件？

### 只通知固定 Task

优先考虑：

```text
Task Notification
```

例如：

```text
ADC DMA Complete ISR
        ↓
   SensorTask
```

---

### 普通的一次性同步

可以用：

```text
Binary Semaphore
```

---

### 需要记住发生多少次

```text
Counting Semaphore
```

---

### 一个任务同时等待多个事件

```text
Event Group
```

比如：

```text
Touch
RTC
USB
Charger
```

---

## 11.3 我要保护一个共享资源？

```text
Mutex
```

例如：

```text
多个 Task
    ↓
  Mutex
    ↓
I2C / SPI / File System
```

而不是 Binary Semaphore。

---

# 12. 几个典型 MCU 场景

## DMA 完成

```text
DMA ISR
   ↓
SensorTask
```

如果只需要唤醒固定一个 SensorTask：

```text
Task Notification
```

通常比专门创建一个 Binary Semaphore 更直接。

---

## UART 接收

```text
UART ISR
   ↓
Stream Buffer
   ↓
ParserTask
```

如果协议是连续字节流，这是很自然的结构。

---

## SensorTask 向 StorageTask 保存数据

```text
SensorTask
    ↓
Queue
    ↓
StorageTask
```

Queue 中直接放：

```text
SensorData
```

---

## 多个 Task 请求写 Flash

比较推荐：

```text
GuiTask ─────┐
SensorTask ──┼→ Storage Queue → StorageTask → Flash
SysTask ─────┘
```

而不是：

```text
所有 Task
   ↓
抢 Flash Mutex
```

前一种本质上是：

```text
MPSC
```

所有 Flash 写操作集中到 StorageTask，整体结构通常更干净。

---

## 多个任务访问 I2C

```text
GuiTask ─────┐
             ↓
           Mutex
             ↓
            I2C
             ↑
SensorTask ──┘
```

这种情况才是 Mutex 的典型用途。

---

## 一个 SysTask 同时处理多个系统事件

例如：

```text
Touch
RTC Alarm
USB
Power Event
```

可以：

```text
Touch ────────┐
RTC ──────────┤
USB ──────────┼→ Event Group → SysTask
Power ────────┘
```

如果这些事件最终都只给 SysTask 一个任务处理，也可以进一步考虑：

```text
Task Notification + eSetBits
```

会更轻量。

---

# 13. 几个容易混淆的点

## Queue 和 Semaphore

Queue：

> 重点是“消息是什么”。

Semaphore：

> 重点是“某件事发生了”。

---

## Binary Semaphore 和 Mutex

Binary Semaphore：

> 事件同步。

Mutex：

> 共享资源互斥。

Mutex 还有：

```text
Priority Inheritance
```

所以保护 Task 间共享资源应该优先使用 Mutex。

---

## Event Flag 和 Event Group

FreeRTOS 原生概念：

```text
Event Group
    ├── Event Flag / Event Bit
    ├── Event Flag / Event Bit
    └── Event Flag / Event Bit
```

Event Flag 是其中的某一个 bit。

CMSIS-RTOS2 则直接把 API 叫做：

```text
Event Flags
```

不要把它们当成两套完全不同的机制。

---

## Event Group 和 Task Notification

两者都可以使用 bit 表示事件。

区别主要是：

```text
Event Group
    ↓
独立对象
多个 Task 可以共同使用
适合广播、共享系统状态
```

而：

```text
Task Notification
    ↓
属于某一个 Task
只能由该 Task 接收
更轻量
```

---

## Queue 和 Stream Buffer

Queue：

```text
Item
Item
Item
```

有明确元素。

Stream Buffer：

```text
Byte Byte Byte Byte Byte ...
```

只是一条连续字节流。

---

## Stream Buffer 和 Message Buffer

Stream Buffer：

```text
ABCDEFG123456
```

不保留消息边界。

Message Buffer：

```text
[ABC]
[DEFG]
[123456]
```

保留消息边界。

---

# 14. 最后总结

FreeRTOS 这些通信机制看起来很多，其实只要抓住使用目的就不难。

如果需要真正传数据：

```text
普通消息          → Queue
连续 Byte Stream → Stream Buffer
可变长度消息      → Message Buffer
```

如果只是同步或者通知：

```text
单次事件             → Binary Semaphore
事件次数             → Counting Semaphore
多个事件组合          → Event Group
通知固定的某一个 Task → Task Notification
```

如果是多个 Task 争用共享资源：

```text
Mutex
```

如果存在同一 Task 多层重复加锁：

```text
Recursive Mutex
```

我觉得实际开发中最值得建立的一个习惯是：

> 不要一看到“任务之间需要交互”就直接上 Queue，也不要一看到“需要锁”就随手用 Semaphore。

先判断自己真正需要的是：

```text
数据传递？
事件同步？
状态通知？
资源互斥？
```

再选择机制。

很多 FreeRTOS 的设计问题，本质上并不是“哪个 API 会用”，而是通信模型有没有设计清楚。

---

# 参考资料

主要参考 FreeRTOS 官方文档与《Mastering the FreeRTOS Real Time Kernel》中的相关章节：

- FreeRTOS Queues
- Binary Semaphores
- Counting Semaphores
- Mutexes
- Recursive Mutexes
- Event Groups / Event Flags
- Direct-to-Task Notifications
- Stream Buffers
- Message Buffers

官方文档：

```text
https://www.freertos.org/Documentation/
```

FreeRTOS Kernel：

```text
https://github.com/FreeRTOS/FreeRTOS-Kernel
```
