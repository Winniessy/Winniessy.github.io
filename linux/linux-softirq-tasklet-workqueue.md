# Linux 软中断、tasklet、workqueue 与 threaded IRQ

## 1. 软中断是否运行在任务上下文

不是。Linux 内核中的常见执行上下文如下：

| 上下文 | 是否有 `task_struct` | 能否睡眠 | 典型场景 |
| --- | --- | --- | --- |
| 进程上下文 | 有 | 能 | 系统调用、内核线程 |
| 硬中断上下文 | 没有 | 不能 | 硬中断上半部 |
| 软中断上下文 | 没有 | 不能 | tasklet、网络软中断 |
| 中断线程上下文 | 有 | 能 | threaded IRQ |

软中断没有自己的 `task_struct`，不能睡眠，也不能主动调度。它运行在中断上下文中，是硬中断上下文的延伸。

## 2. 软中断上下文的特点

软中断上下文是内核执行软中断处理函数时的运行环境，主要特点如下：

- 没有独立的进程身份。`current` 可能指向被打断的进程，但不能依赖这个身份进行阻塞操作。
- 不能调用 `mutex_lock()`、`msleep()`、`copy_to_user()` 或 `kmalloc(GFP_KERNEL)` 等可能睡眠的接口。
- 不能调用 `schedule()` 主动调度。
- 执行期间仍然可以被硬中断打断。

常见的上下文判断接口：

```c
in_interrupt();  /* 硬中断或软中断上下文 */
in_softirq();    /* 软中断上下文 */
in_task();       /* 进程上下文 */
```

软中断通常在硬中断返回时执行：

```text
硬中断返回
    ↓
检查待处理的软中断
    ↓
执行 do_softirq()
    ↓
处理 tasklet、网络收包等软中断
```

当软中断数量过多时，内核可能交给 `ksoftirqd` 内核线程处理。但 `ksoftirqd` 执行软中断处理函数时，仍然处于软中断上下文，不能睡眠。

## 3. 软中断类型为什么不能动态注册

软中断类型在内核源码中固定定义，驱动模块不能新增软中断类型。软中断编号和处理函数数组在内核编译时就已经确定。

典型的软中断类型包括：

```text
HI_SOFTIRQ
TIMER_SOFTIRQ
NET_TX_SOFTIRQ
NET_RX_SOFTIRQ
BLOCK_SOFTIRQ
TASKLET_SOFTIRQ
SCHED_SOFTIRQ
HRTIMER_SOFTIRQ
RCU_SOFTIRQ
```

内核内部使用类似下面的静态数组保存处理函数：

```c
static struct softirq_action softirq_vec[NR_SOFTIRQS];
```

因此驱动模块不能通过 `open_softirq()` 动态增加新的软中断类型，原因是：

- 软中断枚举已经固定，没有可动态分配的编号。
- `softirq_vec[]` 的大小已经确定。
- 新增软中断类型需要修改内核源码并重新编译内核。

驱动开发中通常不直接增加软中断类型，而是使用 tasklet 或 workqueue。

| 机制 | 能否动态创建 | 说明 |
| --- | --- | --- |
| 软中断 | 不能 | 类型固定，主要由内核核心子系统使用 |
| tasklet | 能 | 使用 `tasklet_init()` 初始化 |
| workqueue | 能 | 使用 `INIT_WORK()` 初始化 |
| threaded IRQ | 能 | 使用 `request_threaded_irq()` 注册 |

## 4. 并发和并行

并发与并行不是同一个概念：

| 概念 | 含义 |
| --- | --- |
| 并发 | 多个任务在同一个 CPU 上交替执行，宏观上像是同时运行，微观上仍然串行 |
| 并行 | 多个任务在多个 CPU 上真正同时执行 |

在软中断和 tasklet 中：

- 软中断可以在多个 CPU 上并行执行。
- 同一个 tasklet 不能在同一时刻并行运行。
- 不同 tasklet 可以在不同 CPU 上并行执行。

软中断使用 per-CPU 数据减少锁竞争；tasklet 则保证同一个 tasklet 不会并行执行，从而简化驱动开发。在单个 CPU 上，软中断和 tasklet 都是串行执行的，只能形成并发，不能形成并行。

## 5. threaded IRQ、tasklet 和 workqueue

| 机制 | 触发方式 | 执行上下文 | 能否睡眠 |
| --- | --- | --- | --- |
| threaded IRQ | 上半部返回 `IRQ_WAKE_THREAD` | 中断线程，即进程上下文 | 能 |
| tasklet | 调用 `tasklet_schedule()` | 软中断上下文 | 不能 |
| workqueue | 调用 `schedule_work()` 或 `queue_work()` | worker 内核线程，即进程上下文 | 能 |

### 5.1 threaded IRQ

```text
硬中断上半部
    ↓
返回 IRQ_WAKE_THREAD
    ↓
内核自动唤醒中断线程
    ↓
thread_fn 执行
```

驱动不需要显式调用调度接口来唤醒这个线程，`thread_fn` 可以睡眠。

### 5.2 tasklet

```c
tasklet_schedule(&my_tasklet);
```

内核会标记 tasklet 待处理，并在硬中断返回时或由 `ksoftirqd` 执行。tasklet 运行在软中断上下文，不能睡眠。

### 5.3 workqueue

```c
schedule_work(&my_work);
/* 或者 */
queue_work(my_wq, &my_work);
```

work 被放入 workqueue，由 worker 内核线程执行。worker 运行在进程上下文，可以睡眠。

## 6. 三种机制的区别

| 项目 | threaded IRQ | tasklet | workqueue |
| --- | --- | --- | --- |
| 驱动是否显式调度 | 不需要，返回 `IRQ_WAKE_THREAD` 即可 | 需要 `tasklet_schedule()` | 需要 `schedule_work()` 或 `queue_work()` |
| 下半部执行者 | 内核自动创建的中断线程 | 软中断处理流程 | workqueue worker 线程 |
| 运行上下文 | 进程上下文 | 软中断上下文 | 进程上下文 |
| 能否睡眠 | 能 | 不能 | 能 |

## 7. 从硬中断到下半部

```text
硬中断发生
  │
  ├── 上半部（硬中断上下文，不能睡眠）
  │     │
  │     ├── 返回 IRQ_WAKE_THREAD
  │     │     → 中断线程执行 thread_fn
  │     │
  │     ├── tasklet_schedule()
  │     │     → 软中断上下文执行
  │     │
  │     └── schedule_work()
  │           → workqueue worker 执行
  │
  └── 硬中断返回
        → 检查并执行待处理软中断
```

## 8. 结论

1. 软中断不运行在任务上下文，而运行在软中断上下文；它没有独立的 `task_struct`，不能睡眠。
2. 软中断可以被硬中断打断，但不能主动调度。
3. 软中断类型由内核源码固定，驱动模块不能动态新增类型。
4. 并发表示同一个 CPU 上交替执行，并行表示多个 CPU 同时执行。
5. 同一个 tasklet 不能并行，不同 tasklet 可以在多个 CPU 上并行。
6. threaded IRQ 通过返回 `IRQ_WAKE_THREAD` 让内核唤醒线程；tasklet 和 workqueue 需要驱动显式调用调度接口。
7. tasklet 运行在不能睡眠的软中断上下文，threaded IRQ 和 workqueue 运行在可以睡眠的进程上下文。
