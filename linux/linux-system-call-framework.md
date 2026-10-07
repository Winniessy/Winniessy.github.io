# Linux 系统调用框架：从 syscall 到内核子系统

最近整理 Linux 用户空间和内核的关系时，我发现系统调用其实可以作为一张很好的“总目录”。用户程序不管是在打开文件、申请内存，还是创建进程，最后都会通过某个系统调用进入内核，再由内核分发到对应的子系统。

先用一张图看整体：

~~~text
                         syscall
                            │
             ┌──────────────┼──────────────┐
             ↓              ↓              ↓
            VFS             MM           Process
             │              │              │
       open/read/write   mmap/brk      fork/exec
             │
             ├──────────────┐
             ↓              ↓
        filesystem        device
             │              │
           ext4           V4L2
                          DRM
                          ALSA


Network   └─ socket / send / recv
Signal    └─ kill / sigaction
Scheduler └─ sched_yield / affinity
IPC       └─ shm / msg / semaphore
Futex     └─ thread synchronization
Time      └─ sleep / timer
Namespace └─ clone / unshare / setns
~~~

## 1. VFS 是最常见的一条主线

用户调用 `open()`、`read()`、`write()` 时，并不是直接操作 ext4，也不是直接操作某个设备驱动，而是先进入 VFS。

VFS 把不同文件系统和设备统一成了相似的文件接口：

~~~text
用户程序
   ↓ open / read / write / ioctl / mmap
VFS
   ├── 文件系统，例如 ext4
   └── 设备文件，例如 /dev/video0、/dev/dri、/dev/snd
~~~

所以打开一个普通文件和打开一个设备节点，表面上都像是在调用 `open()`，但进入内核之后，最终会走到不同的实现。

摄像头、显示和音频设备也可以沿着这条线理解：

- 摄像头通常通过 V4L2 提供用户接口；
- 显示相关功能通常通过 DRM/KMS 提供；
- 音频设备通常通过 ALSA 提供。

驱动真正需要实现的，就是把硬件能力接到这些内核框架上。

## 2. MM 和 Process 负责另外两类核心问题

MM 是 Memory Management，负责进程地址空间和内存管理。`mmap()` 可以把文件、设备 buffer 或匿名内存映射到用户空间，`brk()` 则和传统堆空间扩展有关。

Process 这一支负责进程和程序的生命周期。`fork()` 创建新的进程，`exec()` 用新的程序替换当前进程映像。平时执行一个命令时，Shell 往往就是先 `fork()`，再由子进程调用 `exec()`。

这两条线和 VFS 经常交叉。例如：

- `mmap()` 可以映射普通文件；
- 摄像头驱动可以通过 `mmap()` 把 DMA buffer 交给用户程序；
- 进程启动时需要读取可执行文件，并建立新的地址空间。

## 3. 其他系统调用可以先按功能记

网络相关的 `socket()`、`send()`、`recv()` 进入网络子系统；信号相关的 `kill()`、`sigaction()` 进入信号处理机制；`sched_yield()` 和 CPU affinity 接口属于调度相关功能。

共享内存、消息队列和信号量属于 IPC。线程同步中经常看到的 `futex`，本身是一个比较底层的等待/唤醒机制，很多用户态线程库会用它实现互斥锁和条件变量。

睡眠和定时器属于时间管理。Namespace 相关的 `clone()`、`unshare()`、`setns()` 则是容器隔离的基础之一。

这些接口看起来分散，但思路是一致的：

~~~text
用户空间 API
    ↓
系统调用入口
    ↓
内核子系统
    ↓
具体对象、文件系统、设备或硬件
~~~

## 4. 对驱动学习的帮助

从 MCU 转到 Linux 后，最容易困惑的是：为什么应用程序只调用一个 `read()` 或 `ioctl()`，后面却能控制复杂的硬件。

原因是中间有多层框架：

~~~text
应用程序
   ↓
V4L2 / DRM / ALSA 等用户接口
   ↓
VFS 和内核框架
   ↓
驱动的 file_operations、ioctl、mmap
   ↓
寄存器、DMA、中断和硬件
~~~

以 Camera 为例，应用程序调用 V4L2 接口申请 buffer、启动采集并读取帧数据。V4L2 再通过驱动的 `ioctl`、`mmap` 等回调完成 buffer 管理、硬件配置和数据交付。

所以学习 Linux 驱动时，不需要一开始就把所有系统调用都背下来。先抓住几条常用路径就够了：

~~~text
文件和设备访问 → open / read / write / ioctl / mmap
进程和程序启动 → fork / exec
内存映射       → mmap / brk
设备驱动        → VFS → 内核框架 → driver
~~~

## 5. 总结

系统调用是用户空间进入内核的统一入口。进入内核之后，调用会被分发到 VFS、内存管理、进程管理、网络、调度、IPC 等不同子系统。

对驱动开发来说，最重要的一条链路是：

~~~text
用户 API
  → VFS
  → 内核框架
  → 驱动回调
  → 硬件寄存器、DMA 和中断
~~~

把这条链路理清之后，再去看 `read()`、`ioctl()`、`mmap()` 或 V4L2 的具体代码，就不会只觉得它们是零散的 API 了。
