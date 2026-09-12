# Ubuntu 系统性能监控常用命令

在 Ubuntu 上排查系统性能、编译 Kernel 或构建 BSP 时，经常需要观察 CPU、内存、磁盘和温度。下面整理几个最常用的命令。

## 1. `free -h`：查看内存使用情况

```bash
free -h
```

示例输出：

```text
               total        used        free      shared  buff/cache   available
Mem:           7.5Gi       2.1Gi       3.8Gi       200Mi       1.6Gi       5.0Gi
Swap:          2.0Gi          0B       2.0Gi
```

主要字段：

- `total`：总内存。
- `used`：已经使用的内存。
- `free`：完全空闲的内存。
- `buff/cache`：Linux 用作缓冲和缓存的内存。
- `available`：当前大致可以继续使用的内存。

Linux 会尽量利用空闲 RAM 做缓存，因此不要只看 `free` 判断内存是否不足，更应该关注 `available`。

参数 `-h` 表示 `human-readable`，会使用 `GiB`、`MiB` 等更容易阅读的单位。

## 2. `df -h`：查看磁盘空间

```bash
df -h
```

示例输出：

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  469G   30G  415G   7% /
```

主要字段：

- `Size`：分区总容量。
- `Used`：已经使用的空间。
- `Avail`：剩余空间。
- `Use%`：使用率。
- `Mounted on`：挂载点。

下载 SDK、编译 Linux Kernel 或构建 BSP 前，建议先检查根分区 `/` 是否有足够空间。

## 3. `top`：实时查看 CPU 和进程

```bash
top
```

进入后会持续刷新，主要关注：

- `%Cpu(s)`：整体 CPU 状态。
- `MiB Mem`：内存状态。
- 进程列表：当前运行的程序。

CPU 状态中常见字段：

- `us`：用户态程序占用的 CPU 比例。
- `sy`：内核态占用的 CPU 比例。
- `id`：CPU 空闲比例。

例如：

```text
id = 90%
```

表示 CPU 大部分时间处于空闲状态。

进程列表中的 `%CPU` 和 `%MEM` 分别表示单个进程的 CPU 和内存占用情况。

退出 `top`：

```text
q
```

## 4. `htop`：更直观的实时监控

`htop` 可以看作更易读的 `top`，会用进度条展示每个 CPU 核心的负载，同时显示内存和 Swap 使用情况。

安装：

```bash
sudo apt update
sudo apt install htop
```

运行：

```bash
htop
```

编译 RK3566 Kernel 时，可以在一个终端运行：

```bash
htop
```

再在另一个终端运行：

```bash
make -j8
```

这样可以直观看到 CPU 是否跑满、内存是否不足，以及具体是哪一个进程占用资源最多。

## 5. `sensors`：查看温度和硬件传感器

安装工具：

```bash
sudo apt install lm-sensors
```

扫描传感器：

```bash
sudo sensors-detect
```

查看传感器数据：

```bash
sensors
```

可能看到类似输出：

```text
Package id 0:  +58.0°C
Core 0:        +52.0°C
Core 1:        +50.0°C
```

长时间编译 BSP 或 Kernel 时，可以用它观察处理器是否持续高温。

## 6. 常用命令速记

```bash
free -h   # 查看内存
df -h     # 查看磁盘
top       # 实时查看 CPU、内存和进程
htop      # 更直观地查看实时性能
sensors   # 查看温度和传感器
```

实际使用中，最常用的组合通常是：

```text
htop + df -h
```

一个观察实时性能，一个确认磁盘空间是否充足。
