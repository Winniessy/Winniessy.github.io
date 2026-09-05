# FreeRTOS Message Queue 学习笔记

在 STM32 + FreeRTOS 的工程里，经常会看到 `Message Queue` 这个名字。这里很容易产生一个误解：Message Queue 是不是 FreeRTOS Queue 之外的另一种通信机制？

其实大多数情况下不是。

如果工程使用的是 CMSIS-RTOS2，那么：

```text
CMSIS-RTOS2                   FreeRTOS 原生接口

Message Queue                 Queue

osMessageQueueNew()      ≈    xQueueCreate()

osMessageQueuePut()      ≈    xQueueSend()

osMessageQueueGet()      ≈    xQueueReceive()
```

也就是说，CMSIS-RTOS2 把它叫做 **Message Queue（消息队列）**，FreeRTOS 原生 API 里通常直接叫 **Queue（队列）**。

从使用思想上看，它们解决的是同一个问题：

```text
生产者
   │
   │ Message
   ↓
 Queue
   ↓
消费者
```

也就是把一条条消息暂存在队列中，让发送任务和接收任务解耦。

---

## Queue Length 到底是什么意思？

创建一个 FreeRTOS Queue 时，最关键的是两个参数：

```c
xQueueCreate(
    QueueLength,
    ItemSize
);
```

例如：

```c
xQueueCreate(8, sizeof(uint32_t));
```

这里的 `8` 并不是：

```text
8 bit
```

而是：

```text
Queue 最多可以存 8 条消息
```

第二个参数：

```c
sizeof(uint32_t)
```

才决定：

```text
每条消息有多大
```

所以：

```c
xQueueCreate(8, sizeof(uint32_t));
```

可以简单理解成：

```text
Queue Length = 8
每条消息大小 = 4 Byte
```

逻辑上类似于：

```c
uint32_t buffer[8];
```

也就是：

```text
┌────────────┐
│ uint32_t   │  第 1 条消息
├────────────┤
│ uint32_t   │  第 2 条消息
├────────────┤
│ uint32_t   │
├────────────┤
│ uint32_t   │
├────────────┤
│ uint32_t   │
├────────────┤
│ uint32_t   │
├────────────┤
│ uint32_t   │
├────────────┤
│ uint32_t   │  第 8 条消息
└────────────┘
```

所以以后看到：

```text
Queue Length = 8
```

应该理解成：

> 这个 Queue 有 8 个消息槽位。

而不是：

> 这个 Queue 是 8 位的。

---

## Message Size 又是什么？

假设定义：

```c
typedef struct
{
    uint32_t id;
    uint32_t value;
} SensorMsg_t;
```

这个结构体通常占：

```text
id       4 Byte
value    4 Byte
----------------
总共     8 Byte
```

然后：

```c
xQueueCreate(8, sizeof(SensorMsg_t));
```

含义就是：

```text
最多保存 8 条消息

每条消息大小为 sizeof(SensorMsg_t)
大约 8 Byte
```

所以 Queue 的数据存储区大致需要：

```text
8 × 8 Byte = 64 Byte
```

当然这只是消息数据本身。

FreeRTOS Queue 对象还需要保存一些管理信息，例如：

```text
当前有多少条消息
读位置
写位置
等待发送的任务
等待接收的任务
```

所以实际 RAM 占用会比 `QueueLength × ItemSize` 更大。

---

## Queue 本质上存的是什么？

FreeRTOS Queue 默认采用的是：

> **Copy by value，也就是复制数据。**

例如：

```c
uint32_t value = 100;

xQueueSend(queue, &value, 0);
```

虽然传进去的是：

```c
&value
```

但是 FreeRTOS 并不是把这个地址存在 Queue 里面。

实际上更接近：

```text
value = 100
    │
    │ copy
    ↓
Queue 内部存储区域
```

发送成功以后，即使马上：

```c
value = 200;
```

Queue 中原来的那条消息仍然是：

```text
100
```

这也是 Queue 比较好用的地方：

> 发送者和接收者不需要共享同一个变量。

---

## 为什么大数据通常不直接放 Queue？

假设有：

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

每发送一次，就需要复制几 KB 数据。

这种情况下 Queue 本身没错，但是效率会比较差。

工程里更常见的是：

```c
typedef struct
{
    uint8_t *buffer;
    uint32_t len;
} FrameMsg_t;
```

Queue 中只放：

```text
Buffer 指针
+
长度
+
其他描述信息
```

例如：

```text
Queue

┌────────────────────┐
│ buffer = 0x20001000 │
│ len    = 4096       │
└────────────────────┘
```

真正的数据仍然放在另外一块 Buffer 中。

这样 Queue 每次只需要复制几个字节。

不过这样做以后，就需要自己处理一个问题：

> 这个 Buffer 到底归谁？

例如生产者发送了：

```text
buffer A
```

消费者还没处理完，生产者就又把 `buffer A` 改掉了，那数据就可能出问题。

所以可以简单记：

```text
Queue 传结构体
    ↓
简单、安全，但会复制数据

Queue 传指针
    ↓
效率高，但需要管理 Buffer 生命周期
```

---

## Queue 满了会发生什么？

假设：

```text
Queue Length = 8
```

当前已经有：

```text
[Msg1]
[Msg2]
[Msg3]
[Msg4]
[Msg5]
[Msg6]
[Msg7]
[Msg8]
```

此时 Queue 已满。

如果：

```c
xQueueSend(queue, &msg, 0);
```

因为等待时间是：

```text
0
```

所以发送会立即失败。

但如果：

```c
xQueueSend(
    queue,
    &msg,
    portMAX_DELAY
);
```

那么当前发送任务可以进入：

```text
Blocked
```

等待 Queue 出现空位。

当消费者执行：

```c
xQueueReceive();
```

取走一条数据：

```text
[Msg2]
[Msg3]
...
[Msg8]
[Empty]
```

FreeRTOS 就可以重新唤醒等待发送的任务。

---

## Queue 为空时也是一样

如果 Queue 当前：

```text
Empty
```

消费者调用：

```c
xQueueReceive(
    queue,
    &msg,
    portMAX_DELAY
);
```

任务不会一直运行：

```c
while (queue_empty)
{
}
```

而是直接：

```text
Running
   ↓
Blocked
```

等到有人：

```c
xQueueSend();
```

发送消息以后：

```text
Blocked
   ↓
Ready
   ↓
等待调度
```

这也是 RTOS Queue 很重要的地方。

它除了负责保存消息，还顺便完成了：

```text
任务同步
+
阻塞 / 唤醒
```

---

## Message Queue 为什么适合生产者—消费者模型？

假设：

```text
SensorTask
```

每隔一段时间采集一次数据。

另外一个：

```text
StorageTask
```

负责写 Flash。

如果直接：

```text
SensorTask
   ↓
写 Flash
```

那么 Flash 写入如果很慢，SensorTask 就会被卡住。

更合理的是：

```text
SensorTask
    │
    │ SensorMsg
    ↓
   Queue
    ↓
StorageTask
    ↓
  Flash
```

SensorTask 只负责：

```text
采集
打包
入队
```

StorageTask 再慢慢写 Flash。

这样两个任务之间就被 Queue 解耦了。

这就是典型的：

```text
Producer
   ↓
 Queue
   ↓
Consumer
```

也就是生产者—消费者模型。

---

## Queue Length 为什么不能随便设置？

例如：

```text
Queue Length = 1
```

意味着生产者最多只能比消费者领先一条消息。

如果消费者稍微慢一点：

```text
Producer
Producer
Producer
```

Queue 很快就满。

但如果：

```text
Queue Length = 1000
```

虽然不容易满，但在 MCU 上可能浪费大量 RAM。

因此 Queue Length 本质上是在做一个权衡：

```text
Queue 太短
    ↓
抗突发能力差
容易 Queue Full

Queue 太长
    ↓
RAM 占用大
消息可能积压很久
```

所以 Queue Length 应该根据：

```text
生产速度
消费速度
允许的突发量
RAM 大小
消息大小
```

共同决定。

并不存在一个固定的“8 比较好”或者“16 比较好”。

---

## CMSIS-RTOS2 中也是同样的概念

例如：

```c
osMessageQueueNew(
    8,
    sizeof(SensorMsg_t),
    NULL
);
```

两个参数仍然分别表示：

```text
8
↓
最多 8 条消息

sizeof(SensorMsg_t)
↓
每一条消息的大小
```

所以它和：

```c
xQueueCreate(
    8,
    sizeof(SensorMsg_t)
);
```

在理解方式上完全一致。

---

# 最后总结

Message Queue 和 FreeRTOS Queue 本质上可以理解成同一种通信模型。

区别主要在 API 层：

```text
CMSIS-RTOS2
    ↓
Message Queue

FreeRTOS Native API
    ↓
Queue
```

使用 Queue 时最容易混淆的是两个概念：

```text
Queue Length
    ↓
能保存多少条消息

Message / Item Size
    ↓
每条消息多大
```

所以：

```c
xQueueCreate(8, sizeof(uint32_t));
```

应该读成：

> 创建一个最多可以存放 8 个 `uint32_t` 消息的 Queue。

而不是：

> 创建一个 8 bit 的 Queue。

如果是：

```c
xQueueCreate(8, sizeof(MyMessage_t));
```

就表示：

```text
8 个消息槽位
×
每个槽位 sizeof(MyMessage_t)
```

Queue 默认采用数据复制的方式，发送时把消息复制到 Queue 内部，接收时再复制给消费者。

所以普通的小型结构体非常适合直接使用 Queue。

如果数据量非常大，则更常见的方式是：

```text
大块 Buffer
    +
Queue 传 Buffer 指针 / 描述符
```

最后可以把 Queue 记成一句话：

> **FreeRTOS Queue 就是一块由 RTOS 管理的、有固定槽位数量和固定单条消息大小的消息缓冲区，同时还负责发送者和接收者之间的阻塞与唤醒。**