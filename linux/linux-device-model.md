# Linux 设备模型：字符设备、平台设备、总线与内核子系统

刚开始学 Linux 驱动时，很容易把下面这些东西放在同一个分类里：

```text
字符设备
块设备
网络设备
Platform Device
SPI Device
Framebuffer
V4L2
IIO
```

但其实它们并不是同一层次的概念。

最重要的是先把 Linux 设备驱动拆成几个不同的问题：

```text
这个设备怎么接进 Linux？
        ↓
Bus / Device Model
总线 / 设备模型

这个设备是干什么的？
        ↓
Subsystem / Framework
子系统 / 内核框架

这个设备最终怎么给用户使用？
        ↓
User Interface
用户接口
```

所以 Linux 里的设备不能简单画成：

```text
设备
├── 字符设备
├── 块设备
├── 网络设备
├── Platform Device
├── V4L2
└── Framebuffer
```

这个分类方法是错的。

一个设备完全可能同时具有多个身份。

例如 RK3588 上的 UART：

```text
设备模型：
Platform Device

功能子系统：
TTY Subsystem

用户接口：
Character Device
/dev/ttyS0
```

这三个说法可以同时成立。

---

# 一、字符设备、块设备、网络设备是什么

字符设备、块设备、网络设备，主要描述的是：

> Linux 上层以什么方式使用这个设备。

---

## 1. Character Device：字符设备

Character Device（字符设备）通常以字节流或者一段一段的数据形式访问。

用户态最常见：

```c
open();
read();
write();
ioctl();
close();
```

例如：

```text
/dev/ttyS0
/dev/input/event0
/dev/i2c-3
/dev/video0
```

字符设备驱动里经常会看到：

```c
struct file_operations
```

例如：

```c
static const struct file_operations fops = {
    .open           = xxx_open,
    .read           = xxx_read,
    .write          = xxx_write,
    .unlocked_ioctl = xxx_ioctl,
    .release        = xxx_release,
};
```

用户调用：

```c
write(fd, buf, len);
```

最终通过 VFS（Virtual File System，虚拟文件系统）进入：

```c
xxx_write();
```

所以可以简单理解：

```text
用户态
   ↓
/dev/xxx
   ↓
VFS
   ↓
file_operations
   ↓
Driver
```

字符设备还涉及：

```text
major number：主设备号
minor number：次设备号
```

以及：

```c
alloc_chrdev_region();
cdev_init();
cdev_add();
```

如果再通过：

```c
class_create();
device_create();
```

注册设备，用户态最终通常就会看到：

```text
/dev/xxx
```

不过需要注意：

> 并不是所有 Linux 驱动都应该自己注册字符设备。

很多设备已经有对应的内核子系统，应该优先接入子系统。

---

## 2. Block Device：块设备

Block Device（块设备）主要用于存储设备。

例如：

```text
/dev/sda
/dev/mmcblk0
/dev/nvme0n1
```

它和字符设备最大的区别是：

```text
字符设备：
更像连续的数据流

块设备：
按照 block / sector 组织数据
支持随机访问
```

典型硬件：

```text
eMMC
SD Card
SSD
HDD
```

块设备走 Linux 的 Block Layer（块设备层），通常还会在上面继续挂：

```text
ext4
F2FS
XFS
```

这样的文件系统。

所以：

```text
SSD
 ↓
Block Device Driver
 ↓
Block Layer
 ↓
Filesystem
 ↓
open/read/write
```

和普通字符设备的实现路径不一样。

---

## 3. Network Device：网络设备

Network Device（网络设备）更加特殊。

例如：

```text
eth0
wlan0
```

一般不会：

```c
open("/dev/eth0");
```

因为网络设备主要通过：

```text
socket
 ↓
TCP/IP Protocol Stack
 ↓
Network Device
 ↓
Network Driver
```

访问。

Linux 内核中网络设备的重要结构是：

```c
struct net_device
```

所以网络设备并不是典型的 `/dev/xxx + file_operations` 模型。

可以简单记：

```text
字符设备
→ /dev/xxx

块设备
→ /dev/sda、/dev/mmcblk0

网络设备
→ eth0 / wlan0 + socket
```

---

# 二、Platform Device 到底是什么

Platform Device（平台设备）和字符设备、块设备不是一个维度。

Platform Device 主要解决的是：

> SoC 内部这些不能自己被枚举出来的硬件，Linux 怎么知道它存在，又怎么找到对应驱动？

例如 RK3588 内部有很多真实硬件：

```text
RK3588
│
├── UART Controller
├── SPI Controller
├── I2C Controller
├── GPIO Controller
├── PWM Controller
├── DMA Controller
├── Watchdog
├── USB Controller
├── PCIe Controller
├── VOP
├── ISP
└── ...
```

这些都是真实的硬件电路，只不过已经集成在 SoC（System on Chip，片上系统）内部。

它们不像 USB 和 PCIe 设备那样可以自己被枚举出来。

例如 USB：

```text
插入设备
 ↓
USB Host 枚举
 ↓
读取 Vendor ID / Product ID / Descriptor
```

PCIe：

```text
扫描 Bus
 ↓
Vendor ID
Device ID
BAR
Class Code
```

Linux 可以主动发现这些设备。

但 RK3588 内部的 SPI2 Controller 不会自己告诉 Linux：

```text
我是 SPI2
我的寄存器地址是多少
IRQ 是多少
Clock 是什么
Reset 是什么
```

所以 Linux 需要通过 Device Tree（设备树）提前描述这些信息。

例如：

```dts
spi@xxxx {
    compatible = "rockchip,rk3588-spi";
    reg = <...>;
    interrupts = <...>;
    clocks = <...>;
};
```

Linux 根据 Device Tree 建立：

```c
struct platform_device
```

再与：

```c
struct platform_driver
```

进行匹配。

典型流程：

```text
Device Tree
    ↓
platform_device
    ↓
platform_driver
    ↓
probe()
```

所以 Platform Device 可以理解成：

> Linux 用来描述很多“平台本身固定存在、不能通过总线自动枚举”的硬件设备的一种设备模型。

---

# 三、Platform Device 和字符设备可以同时存在

例如 RK3588 UART。

从硬件接入 Linux 的角度：

```text
UART Controller
      ↓
Platform Device
      ↓
Platform Driver
```

但 UART Driver 初始化完成以后，又会注册到：

```text
TTY Subsystem
```

用户最终看到：

```text
/dev/ttyS0
```

这个 `/dev/ttyS0` 又是 Character Device（字符设备）。

所以一个 UART 可以同时是：

```text
Platform Device
+
TTY Device
+
Character Device
```

这些身份并不冲突。

---

# 四、什么叫 Bus：总线

Linux 中常见的 Bus（总线）包括：

```text
Platform
SPI
I2C
USB
PCI / PCIe
SDIO
MDIO
I3C
```

这里 Platform 比较特殊，它不一定对应一种真正的物理通信总线，但在 Linux Device Model（设备模型）里也以类似 Bus 的方式组织 Device（设备）和 Driver（驱动）。

这些设备模型通常都有对应的数据结构：

```c
struct platform_device;
struct spi_device;
struct i2c_client;
struct usb_device;
struct pci_dev;
```

以及对应 Driver：

```c
struct platform_driver;
struct spi_driver;
struct i2c_driver;
struct usb_driver;
struct pci_driver;
```

所以 Bus 层主要回答：

> 这个设备怎么被 Linux 发现、表示和匹配到 Driver？

---

# 五、SPI Controller 和 SPI Device 是两层东西

这一点很重要。

比如：

```text
RK3588
  │
  └── SPI2 Controller
          │
          └── MPU6000
```

这里实际上存在两个不同设备。

RK3588 内部的：

```text
SPI2 Controller
```

一般属于：

```text
Platform Device
```

因为它是 SoC 内部固定存在的硬件。

流程：

```text
Device Tree
    ↓
platform_device
    ↓
Rockchip SPI Controller Driver
    ↓
注册 spi_controller
    ↓
建立 SPI Bus
```

然后 SPI Bus 上挂着：

```text
MPU6000
```

它属于：

```text
SPI Device
```

Linux 用：

```c
struct spi_device
```

表示。

对应驱动：

```c
struct spi_driver
```

所以完整结构是：

```text
RK3588 SPI Controller
        ↓
Platform Device
        ↓
Rockchip SPI Controller Driver
        ↓
SPI Core
        ↓
SPI Bus
        ↓
MPU6000
        ↓
SPI Device
        ↓
spi_driver
```

因此看到：

```c
struct platform_driver
```

和 SPI 同时出现并不奇怪。

它可能正在驱动：

> SPI Controller 本身。

而不是驱动 SPI 总线下面的从设备。

---

# 六、I2C 也是同样的结构

例如：

```text
RK3588
  │
  └── I2C3 Controller
          │
          └── Sensor
```

I2C3 Controller：

```text
Platform Device
        ↓
Rockchip I2C Controller Driver
        ↓
注册 i2c_adapter
```

Sensor：

```text
I2C Device
        ↓
struct i2c_client
        ↓
struct i2c_driver
```

完整关系：

```text
Platform Device
      ↓
I2C Controller Driver
      ↓
I2C Core
      ↓
I2C Bus
      ↓
i2c_client
      ↓
i2c_driver
```

---

# 七、Framebuffer、V4L2、IIO 又是什么

Framebuffer、V4L2、IIO、ALSA、Input 等，不是在描述设备“挂在哪”。

它们属于：

> Subsystem / Framework（内核子系统 / 内核框架）。

它们回答的问题是：

> 这类功能相似的硬件，Linux 应该怎么统一管理？

---

## 1. Framebuffer

Framebuffer（帧缓冲）是比较传统的 Linux 显示框架。

用户态可能看到：

```text
/dev/fb0
```

设备可以：

```c
open();
mmap();
ioctl();
```

所以 `/dev/fb0` 本身表现成字符设备。

但功能上它属于：

```text
Framebuffer Subsystem
```

底层显示控制器本身又可能是：

```text
Platform Device
```

所以可能同时存在：

```text
Platform Device
        ↓
Framebuffer Subsystem
        ↓
Character Device
        ↓
/dev/fb0
```

现代 Linux 显示更多使用：

```text
DRM
Direct Rendering Manager
直接渲染管理器
```

而不是传统 Framebuffer。

---

## 2. V4L2

V4L2：

```text
Video4Linux2
Linux 视频框架
```

主要用于：

```text
Camera
Video Capture
Video Decoder
Video Encoder
ISP
```

用户可能看到：

```text
/dev/video0
```

虽然 `/dev/video0` 也是一个字符设备节点，但驱动通常不会自己直接：

```c
cdev_add();
```

而是注册进入：

```text
V4L2 / Media Framework
```

V4L2 Framework 再统一提供：

```text
/dev/videoX
```

和对应的 `ioctl()` API。

所以：

```text
Camera
 ↓
I2C / MIPI
 ↓
Camera Driver
 ↓
V4L2 / Media Subsystem
 ↓
/dev/video0
```

---

## 3. IIO

IIO：

```text
Industrial I/O
工业输入输出子系统
```

常见于：

```text
ADC
DAC
IMU
Accelerometer
Gyroscope
某些 Sensor
```

例如一颗 SPI IMU：

```text
SPI Device
    ↓
spi_driver
    ↓
IIO Subsystem
    ↓
/sys/bus/iio/...
/dev/iio:device0
```

所以：

```text
SPI
```

描述的是：

> 怎么连接。

IIO 描述的是：

> 这是什么功能类型。

---

# 八、常见 Linux Subsystem

可以暂时记住这些：

| 硬件                 | 常见 Linux 子系统      |
| ------------------ | ----------------- |
| UART               | TTY               |
| 按键、键盘、鼠标、触摸        | Input             |
| ADC / IMU / Sensor | IIO               |
| 温度、电压、风扇监控         | hwmon             |
| Camera / Video     | V4L2 / Media      |
| Display            | DRM / Framebuffer |
| Audio              | ALSA              |
| NOR / NAND Flash   | MTD               |
| RTC                | RTC               |
| GPIO               | GPIO              |
| PWM                | PWM               |
| Watchdog           | Watchdog          |
| Ethernet / Wi-Fi   | Network           |

这些 Framework 的意义不是简单提供几个 API。

它们真正解决的是：

> 不同厂商、不同型号的同类硬件，在 Linux 上应该表现成一套尽量统一的接口。

例如 Camera：

```text
OV5640
IMX415
GC2053
USB Camera
```

底层硬件完全不同，但用户态都可以尽可能通过 V4L2 API 使用。

这就是 Linux Subsystem 的价值。

---

# 九、Subsystem 和 MCU HAL 不是一回事

MCU 的 HAL：

```text
Hardware Abstraction Layer
硬件抽象层
```

主要回答：

> 这个硬件寄存器怎么操作？

例如：

```c
HAL_SPI_Transmit();
HAL_UART_Receive();
```

Linux 里更接近 HAL 层思维的是：

```text
SPI Controller Driver
I2C Controller Driver
UART Low-level Driver
```

而 Linux Subsystem 更像：

> OS 级的统一功能框架。

比如：

```text
MCU：

Application
    ↓
Sensor Manager
    ↓
MPU6050 Driver
    ↓
HAL I2C
    ↓
I2C Hardware


Linux：

Application
    ↓
IIO Subsystem
    ↓
MPU6050 Driver
    ↓
I2C Core
    ↓
Rockchip I2C Controller Driver
    ↓
I2C Hardware
```

所以可以粗略理解：

```text
MCU HAL：
解决“硬件怎么操作”

Linux Subsystem：
解决“一大类硬件应该怎么统一管理”
```

---

# 十、Linux Driver 最好按三个维度去看

以后拿到任何硬件，都先问三个问题。

## 1. 它怎么接进 Linux？

也就是 Bus / Device Model。

例如：

```text
Platform
SPI
I2C
USB
PCIe
SDIO
```

---

## 2. 它是什么功能？

也就是 Subsystem。

例如：

```text
TTY
Input
IIO
V4L2
DRM
ALSA
MTD
Network
```

---

## 3. 它最终怎么给用户态？

例如：

```text
/dev/ttyS0
/dev/video0
/dev/input/event0
/dev/dri/card0
/dev/iio:device0
/dev/mmcblk0
eth0
sysfs
socket
mmap
```

所以一个设备可以这样描述：

```text
SPI ADC

怎么接：
SPI Device

功能：
IIO

用户接口：
/dev/iio:device0
或者 sysfs
```

另一个设备：

```text
RK3588 UART

怎么接：
Platform Device

功能：
TTY

用户接口：
/dev/ttyS0
```

---

# 十一、一个完整例子：RK3588 + SPI IMU

假设 RK3588 接了一颗 SPI IMU：

```text
RK3588
  │
  └── SPI2 Controller
          │
          └── IMU
```

Linux 可以拆成：

```text
RK3588 SPI2 Controller
        ↓
Platform Device
        ↓
Rockchip SPI Controller Driver
        ↓
SPI Core
        ↓
SPI Bus
        ↓
IMU
        ↓
SPI Device
        ↓
spi_driver
        ↓
IIO Subsystem
        ↓
/dev/iio:deviceX
/sys/bus/iio/...
```

这里包含了三个不同维度：

```text
Platform Device
→ SPI Controller 怎么进入 Linux

SPI Device
→ IMU 怎么挂在 SPI Bus 上

IIO
→ IMU 在 Linux 里属于什么功能类型
```

---

# 十二、一个完整例子：RK3588 Camera

Camera 更能说明这些层次可以同时存在：

```text
Camera Sensor
     │
     ├── I2C
     │     ↓
     │   Sensor Register Control
     │
     └── MIPI CSI
            ↓
         RK3588 CSI
            ↓
            ISP
            ↓
       V4L2 / Media
            ↓
       /dev/video0
```

Camera Sensor 从控制总线角度：

```text
I2C Device
```

从功能角度：

```text
V4L2 Subdevice
```

RK3588 ISP / CSI 这类 SoC 内部硬件：

```text
Platform Device
```

整体 Camera Pipeline（摄像头数据链路）属于：

```text
V4L2 / Media Subsystem
```

最终用户看到：

```text
/dev/video0
```

它又表现为 Character Device。

所以：

```text
Platform Device
I2C Device
V4L2
Character Device
```

完全可能同时出现在一个 Camera 系统中。

---

# 十三、为什么 Linux 要搞这么多层

MCU 开发经常是：

```text
硬件
 ↓
HAL
 ↓
自己写 Driver
 ↓
Application
```

Linux 面对的是成千上万种硬件，而且不同厂商的设备需要共存，所以增加了很多标准层：

```text
Hardware
    ↓
Controller Driver
    ↓
Bus Framework
    ↓
Device Driver
    ↓
Subsystem
    ↓
统一 User API
    ↓
Userspace
```

它的目的不是故意把 Driver 写复杂，而是：

```text
让 Controller Driver 可以复用

让板级配置可以变化

让同类 Device 使用统一接口

让 User Space 不需要知道具体芯片型号
```

---

# 十四、最后建立这张图就够了

以后不要把 Linux 设备理解成一棵简单分类树，而是理解成几个维度：

```text
                         一个硬件设备
                              │
             ┌────────────────┼────────────────┐
             │                │                │
             ↓                ↓                ↓
          怎么接？          是什么？          怎么用？
       Bus / Model        Subsystem         Interface

         Platform            DRM            /dev/dri/*
         SPI                 V4L2           /dev/video*
         I2C                 ALSA           /dev/snd/*
         USB                 Input          /dev/input/*
         PCIe                IIO            /dev/iio*
         SDIO                MTD            /dev/mtd*
                                              │
                                              ↓
                                    Character / Block
                                      socket / sysfs
```

可以把核心结论压缩成一句话：

> **字符设备、块设备、网络设备主要描述 Linux 向上层暴露 I/O 的方式；Platform、SPI、I2C、USB、PCIe 等描述设备如何被 Linux 发现和匹配驱动；V4L2、DRM、IIO、ALSA、Input 等则是按照设备功能划分的内核子系统。一个真实设备往往会同时跨越这几个层次。**

理解这一点以后，再看：

```text
platform_driver
spi_driver
i2c_driver
V4L2
DRM
字符设备
```

就不会觉得它们是一堆互相竞争的“设备分类”，而会知道它们其实分别处在 Linux Driver Model 的不同层次。