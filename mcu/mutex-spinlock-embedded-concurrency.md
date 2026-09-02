# Mutex、Spinlock 与嵌入式并发控制

在嵌入式和操作系统里，“锁”本质上都是为了防止多个执行上下文同时访问共享资源。不同锁的区别，主要不在“能不能互斥”，而在于：

* 谁在竞争；
* 拿不到锁之后怎么办；
* 是否允许当前执行上下文睡眠；
* 系统是单核还是多核。

最常见的两个概念就是 Mutex（Mutual Exclusion，互斥锁）和 Spinlock（自旋锁）。

可以先记住一句最直观的话：

```text
Mutex：拿不到就睡
Spinlock：拿不到就在原地转
```

---

## Mutex 的基本原理

假设两个 FreeRTOS Task（任务）都需要访问同一块共享资源：

```c
xSemaphoreTake(xMutex, portMAX_DELAY);

/* 访问共享资源 */

xSemaphoreGive(xMutex);
```

如果 Mutex 当前空闲，那么任务直接获得锁并进入临界区域。

如果 Mutex 已经被其他任务持有，例如：

```text
Task A 持有 Mutex

Task B 尝试获取 Mutex
```

Task B 不会一直检查锁有没有释放，而是进入 Blocked（阻塞）状态。

整个过程可以理解为：

```text
Task B 尝试获取 Mutex
        ↓
发现 Mutex 被占用
        ↓
Task B: Running → Blocked
        ↓
调度器运行其他任务
        ↓
Task A 释放 Mutex
        ↓
Task B: Blocked → Ready
        ↓
等待调度
        ↓
Task B 获得 Mutex
```

所以 Mutex 的等待过程并不消耗 CPU。

任务拿不到锁之后会睡眠，CPU 可以去运行其他任务。

这也是为什么 Mutex 很适合：

```text
Task ↔ Task
```

之间的资源保护。

---

## Mutex 不只是一个 0/1 变量

最简单的锁似乎可以写成：

```c
if (lock == 0)
{
    lock = 1;

    /* 临界区 */

    lock = 0;
}
```

但真正的 Mutex 远比这个复杂。

它通常至少需要维护：

```text
锁当前是否被占用
锁由哪个 Task 持有
哪些 Task 正在等待
等待 Task 的优先级
```

例如：

```text
Mutex
│
├── Owner: Task A
│
└── Waiting:
      Task B
      Task C
```

这样，当 Task A 释放 Mutex 时，操作系统才能知道应该唤醒哪个任务。

因此 Mutex 和 Scheduler（调度器）是紧密绑定的。

---

## Mutex 为什么要有 Owner

Mutex 与普通 Binary Semaphore（二值信号量）一个很重要的区别，就是 Mutex 存在明确的 Owner（所有者）。

谁拿到 Mutex，谁就应该释放。

原因之一就是操作系统需要处理 Priority Inversion（优先级反转）。

假设：

```text
Task H：高优先级
Task M：中优先级
Task L：低优先级
```

Task L 先获得 Mutex：

```text
Task L
   ↓
Mutex
```

之后 Task H 运行，也需要这个 Mutex：

```text
Task H
   ↓
Mutex 被 L 持有
   ↓
Blocked
```

现在 H 虽然优先级最高，却不得不等待 L。

如果这时候 Task M 进入 Ready：

```text
H > M > L
```

因为 H 已经阻塞，所以调度器会运行 M。

于是可能出现：

```text
Task H 等待 Task L

但 Task L 优先级低
一直被 Task M 抢占

↓

Task H 间接被 Task M 阻塞
```

这就是优先级反转。

---

## Mutex 的优先级继承

为了解决这个问题，FreeRTOS 的 Mutex 支持 Priority Inheritance（优先级继承）。

当高优先级 Task H 等待低优先级 Task L 所持有的 Mutex 时：

```text
H：高优先级
L：低优先级
```

FreeRTOS 会暂时提高 L 的有效优先级。

例如：

```text
Task H
    ↓
等待 Mutex
    ↓
Mutex Owner = Task L
    ↓
Task L 暂时继承 H 的优先级
    ↓
Task L 尽快运行完临界区
    ↓
释放 Mutex
    ↓
Task H 被唤醒
```

释放 Mutex 后，Task L 再恢复原来的优先级。

所以从用途来看：

```text
Mutex
    ↓
主要用于资源互斥
    ↓
有 Owner
    ↓
支持优先级继承
```

而 Binary Semaphore 更多是在表达：

```text
一个事件是否发生
或者
某个资源是否可用
```

两者虽然在 FreeRTOS 内部实现上都和 Queue（队列）机制有关，但语义不同。

---

# Spinlock 的基本原理

Spinlock（自旋锁）的做法完全不同。

假设锁已经被占用：

```text
CPU0 获得 Spinlock
```

CPU1 也想获得：

```text
CPU1 尝试
 ↓
失败
 ↓
再试
 ↓
失败
 ↓
再试
 ↓
……
```

也就是一直循环检查：

```c
while (!try_lock())
{
    ;
}
```

这个过程称为 Spin（自旋）。

所以 Spinlock 的特点是：

```text
拿不到锁
    ↓
不睡眠
    ↓
不进行任务切换
    ↓
一直占着 CPU 等
```

---

## Spinlock 为什么必须依赖原子操作

Spinlock 不能简单地写成：

```c
if (lock == 0)
{
    lock = 1;
}
```

因为两个 CPU 可能同时执行：

```text
CPU0 读取 lock = 0
CPU1 读取 lock = 0

CPU0 写 lock = 1
CPU1 写 lock = 1
```

最后两个 CPU 都认为自己拿到了锁。

所以 Spinlock 必须依赖 Atomic Operation（原子操作）。

在 ARM 架构里可能使用：

```text
LDREX / STREX
```

或者其他：

```text
CAS
SWP
LSE Atomic
```

等原子指令。

这些硬件指令可以保证：

```text
检查 lock
+
修改 lock
```

这一整个过程不可被另一个 CPU 插入。

Spinlock 的逻辑可以理解为：

```c
while (!atomic_try_lock(&lock))
{
    /* 自旋等待 */
}
```

---

# 为什么 Spinlock 看起来浪费 CPU，却仍然存在

Mutex 拿不到锁之后会阻塞：

```text
Running
   ↓
Blocked
   ↓
Scheduler
   ↓
Context Switch
```

这意味着操作系统需要：

```text
修改任务状态
加入等待队列
保存任务上下文
进行任务切换
以后再唤醒任务
恢复任务上下文
```

这一整套流程也是有开销的。

如果临界区非常短，例如：

```c
counter++;
```

或者只是修改几个链表指针，那么持锁时间可能只有几十个 CPU cycle。

这时候：

```text
阻塞 + 调度 + 上下文切换
```

可能比：

```text
原地等几十个 cycle
```

还要贵。

所以 Spinlock 的思想是：

> 如果我知道这个锁马上就会释放，那我就在这里等一会儿，不值得为了这么短的时间去睡眠和重新调度。

---

# 为什么 Spinlock 主要出现在多核系统

Spinlock 真正适合的环境是 SMP（Symmetric Multiprocessing，对称多处理）系统。

例如：

```text
CPU0                      CPU1

Task A                    Task B
```

CPU0：

```text
拿 Spinlock
    ↓
进入临界区
```

与此同时 CPU1：

```text
尝试获得 Spinlock
    ↓
失败
    ↓
Spin
```

虽然 CPU1 在原地等待，但：

```text
CPU0 仍然可以继续运行
```

所以 CPU0 很快完成：

```text
unlock()
```

之后 CPU1 就可以继续。

也就是：

```text
CPU0                         CPU1

lock
 |
critical section           spin
 |                          spin
unlock
                             |
                           lock 成功
```

这就是 Spinlock 能工作的前提：

> 锁的持有者和锁的等待者可以运行在不同 CPU 上。

---

# 为什么单核系统里不适合普通 Spinlock

假设只有一个 Cortex-M CPU。

低优先级 Task L 拿到了 Spinlock：

```text
Task L
    ↓
lock
```

这时高优先级 Task H 抢占了 L：

```text
Task H
    ↓
尝试 lock
    ↓
失败
    ↓
开始 Spin
```

问题马上出现：

```text
H 在等 L 释放锁
```

但现在 H 优先级更高，又一直占着 CPU 自旋。

所以：

```text
L 永远运行不到
```

自然也就：

```text
永远无法 unlock
```

最终变成：

```text
H 等 L
L 等 CPU
CPU 被 H 占着

↓

死锁
```

因此在典型的：

```text
单核 Cortex-M + FreeRTOS
```

系统里，Task 与 Task 之间一般不会使用 Spinlock。

更常见的是：

```text
Mutex
```

因为高优先级任务拿不到 Mutex 后会进入 Blocked，让低优先级持锁任务重新得到 CPU：

```text
Task H 获取 Mutex 失败
    ↓
Blocked
    ↓
Task L 得到 CPU
    ↓
Task L 释放 Mutex
    ↓
Task H 被唤醒
```

这才符合单核调度系统的运行逻辑。

---

# Spinlock 和关闭中断解决的问题也不同

Spinlock 主要解决：

```text
CPU ↔ CPU
```

之间的并发。

但如果共享资源同时会被：

```text
Task ↔ ISR
```

访问，仅仅使用 Spinlock 可能会出问题。

例如 Task 获得锁：

```text
Task
  ↓
spin_lock()
```

随后 ISR 抢占 Task：

```text
ISR
 ↓
也调用 spin_lock()
 ↓
发现锁被 Task 持有
 ↓
Spin
```

这时：

```text
ISR 等 Task unlock
```

但是：

```text
Task 要等 ISR 返回之后才能继续运行
```

于是：

```text
Task 等 ISR 退出
ISR 等 Task 解锁

↓

死锁
```

因此 Linux 内核经常可以看到：

```c
spin_lock_irqsave(&lock, flags);

/* 临界区 */

spin_unlock_irqrestore(&lock, flags);
```

这里其实做了两件事：

```text
关闭当前 CPU 的相关中断
+
获取 Spinlock
```

两者针对不同的竞争来源。

可以理解成：

```text
              共享资源

CPU0  ------------------- CPU1
          Spinlock

防止：
CPU0 ↔ CPU1
```

同时 CPU0 内部还有：

```text
Task
 ↑
ISR
```

所以还需要：

```text
IRQ Disable
```

防止当前 CPU 的 ISR 在 Task 持锁期间再次访问同一个资源。

因此：

```text
Spinlock
    ↓
解决 CPU 之间的并发

IRQ Disable
    ↓
解决当前 CPU 上 Task / ISR 的并发
```

---

# 和 FreeRTOS 临界区放在一起理解

到这里，FreeRTOS 里常见的几种机制就可以放在一张图里理解。

```text
                  共享资源竞争
                       │
         ┌─────────────┼─────────────┐
         │             │             │
      Task ↔ Task   Task ↔ ISR    CPU ↔ CPU
         │             │             │
       Mutex       Critical       Spinlock
                     Section
                       │
                    BASEPRI
```

在典型的单核 Cortex-M + FreeRTOS 中：

```text
Task ↔ Task
```

通常使用：

```text
Mutex
```

或者在一些很短的操作中暂停 Scheduler（调度器）。

如果是：

```text
Task ↔ ISR
```

通常使用：

```text
Critical Section（临界区）
Atomic（原子操作）
Queue
Task Notification
Stream Buffer
```

其中 Cortex-M3/M4/M7 上的 FreeRTOS 临界区通常会利用：

```text
BASEPRI
```

屏蔽能够调用 FreeRTOS API 的那部分中断。

而到了 Linux SMP 多核环境：

```text
CPU ↔ CPU
```

是真正同时执行的，所以 Spinlock 就变得非常重要。

---

# Mutex 和 Spinlock 的区别

可以用下面这张表快速判断：

| 特性                     | Mutex        | Spinlock     |
| ---------------------- | ------------ | ------------ |
| 中文                     | 互斥锁          | 自旋锁          |
| 获取失败后                  | 睡眠 / Blocked | 原地循环         |
| 是否消耗 CPU 等待            | 否            | 是            |
| 是否涉及调度                 | 是            | 通常不需要        |
| 是否允许睡眠                 | 是            | 否            |
| 典型临界区                  | 可以相对长一些      | 必须非常短        |
| 典型环境                   | Task ↔ Task  | 多核 CPU ↔ CPU |
| 单核 FreeRTOS Task 间是否常用 | 是            | 通常不用         |
| Linux 内核是否常见           | 是            | 非常常见         |
| ISR 中是否可以直接使用普通版本      | 不可以          | 取决于实现和中断处理方式 |

本质上：

```text
Mutex：
用调度换等待
```

而：

```text
Spinlock：
用 CPU 时间换上下文切换成本
```

---

# 一个比较实用的判断方法

以后遇到一个共享资源，不必先纠结“该用什么锁”，先问两个问题。

第一：

```text
竞争双方是否能够真正同时执行？
```

单核 FreeRTOS：

```text
Task A
Task B
```

并不会真正同时运行，只是通过上下文切换交替执行。

这时候 Mutex 很适合。

多核 Linux：

```text
CPU0: Task A
CPU1: Task B
```

两个执行流确实可能同时运行。

这时候就需要 Spinlock 等跨 CPU 同步机制。

第二：

```text
等待锁的时候，当前执行上下文能不能睡？
```

如果当前是普通 Task：

```text
可以睡
```

那么优先考虑：

```text
Mutex
```

如果当前处于：

```text
ISR
Atomic Context
某些 Linux 内核非睡眠上下文
```

不能进行调度和睡眠，就只能考虑：

```text
Spinlock
Atomic
Critical Section
```

这类非阻塞机制。

---

# 总结

Mutex 和 Spinlock 都用于互斥，但使用场景不同。

Mutex 的核心逻辑是：

```text
拿不到锁
    ↓
任务 Blocked
    ↓
让出 CPU
    ↓
锁释放后再被唤醒
```

所以 Mutex 很适合 RTOS 中 Task 与 Task 之间的共享资源保护。FreeRTOS Mutex 还具有 Owner 和 Priority Inheritance（优先级继承）机制，可以缓解优先级反转。

Spinlock 的核心逻辑则是：

```text
拿不到锁
    ↓
不停尝试
    ↓
一直占用 CPU
    ↓
直到锁释放
```

它省去了任务阻塞、唤醒和上下文切换的成本，因此适合多核系统中非常短的临界区。

对于典型的单核 Cortex-M + FreeRTOS，可以先建立这样的直觉：

```text
Task ↔ Task
    → Mutex

Task ↔ ISR
    → Critical Section / BASEPRI / Atomic / RTOS通信机制

CPU ↔ CPU
    → Spinlock
```

而到了 Linux 驱动和 Linux Kernel 中，经常会遇到：

```c
mutex_lock();

spin_lock();

spin_lock_irqsave();
```

这三类接口背后的区别，其实就是当前代码面对的并发来源不同，以及当前执行上下文是否允许睡眠。