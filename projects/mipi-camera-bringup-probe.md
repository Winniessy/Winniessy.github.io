# MIPI Camera Bring-up 流程与 Sensor `probe()` 框架

## 1. 典型 Camera 结构

常见 MIPI Camera Sensor 通常通过两条路径工作：

```text
I2C：配置和控制 Sensor
MIPI CSI-2：传输图像数据
```

常见 Sensor 包括：

```text
OV5647
IMX219
GC2053
OV13850
```

Camera bring-up 的目标不是只让 I2C 地址出现，而是逐层确认从硬件、Sensor 驱动到 `/dev/videoX` 的整条链路。

## 2. 硬件层检查

首先确认：

```text
Sensor 型号
I2C 地址
MIPI Lane 数
XVCLK
RESET
PWDN
AVDD / DVDD / DOVDD
FPC 排线方向
```

需要结合以下资料：

```text
原理图
    +
Sensor Datasheet
    +
开发板 Camera 接口定义
```

硬件层任何一项不正确，都可能导致后续 I2C 读不到 Chip ID，或者 MIPI 数据无法进入接收端。

## 3. Device Tree 描述

Device Tree 主要描述板级硬件资源，包括：

```text
Sensor 挂载的 I2C Controller
I2C Address
Clock
GPIO
Regulator
MIPI Lane
Endpoint
```

典型节点结构：

```dts
ov5647@36 {
    compatible = "ovti,ov5647";
    reg = <0x36>;

    clocks = <...>;
    pwdn-gpios = <...>;

    port {
        ov5647_out: endpoint {
            data-lanes = <1 2>;
            remote-endpoint = <&dphy_in>;
        };
    };
};
```

其中两个关键概念是：

```text
compatible
    → 用于 Device 和 Driver 匹配

remote-endpoint
    → 用于连接 Camera Pipeline
```

## 4. Sensor Driver 的 `probe()` 大框架

典型 Camera Sensor 的 `probe()` 大致经过以下阶段：

```text
解析 DTS
    ↓
获取 Clock / GPIO / Regulator
    ↓
初始化驱动内部数据
    ↓
初始化 V4L2 Controls
    ↓
初始化 V4L2 Subdev
    ↓
初始化 Media Entity / Pad
    ↓
Sensor Power On
    ↓
I2C Read Chip ID
    ↓
确认 Sensor 型号
    ↓
注册 V4L2 Subdev
    ↓
Runtime PM
    ↓
probe return 0
    ↓
Bind 成功
```

不同 Sensor 的具体顺序可能略有差异，但基本可以分为三部分。

### 4.1 让硬件“活起来”

```text
Clock
Regulator
GPIO
RESET
PWDN
```

这一阶段解决 Sensor 是否正确供电、获得时钟，以及是否处于正确的复位和唤醒状态。

### 4.2 确认“你是谁”

通过 I2C 读取 Chip ID：

```text
I2C
    ↓
Chip ID Register
    ↓
确认实际 Sensor 型号
```

例如：

```text
OV5647 → 0x5647
```

这一阶段同时验证了物理 I2C 通信是否正常。

### 4.3 接入 Linux Camera Framework

驱动通常还需要初始化和注册：

```text
V4L2 Subdev
Media Entity
Media Pad
V4L2 Controls
Async Register
```

最终 Sensor 作为 V4L2 Sub-device 加入 Media Graph。

## 5. `probe()` 成功不等于已经开始传图像

`probe()` 主要解决：

> Linux 能不能识别并管理这个 Camera Sensor。

真正开始输出图像通常发生在 `STREAMON` 之后：

```text
STREAMON
    ↓
Sensor s_stream(1)
    ↓
写入 Sensor Mode Registers
    ↓
打开 MIPI Streaming
    ↓
Sensor 开始输出 CSI-2 数据
```

可以这样区分：

```text
probe()
    = 注册和识别 Sensor

s_stream()
    = 真正开始或停止输出图像
```

## 6. 整条 MIPI Camera Bring-up 链路

以 RK3566 为例，典型数据链路如下：

```text
OV5647
  │
  │ I2C：控制
  │
  ├────────────→ Sensor Driver
  │
  │ MIPI CSI-2：图像数据
  ↓
CSI2 D-PHY
  ↓
CSI-2 Receiver
  ↓
RKCIF
  ↓
DMA
  ↓
DDR
  ↓
Videobuf2
  ↓
V4L2
  ↓
/dev/videoX
  ↓
v4l2-ctl
```

## 7. 推荐的分层检查顺序

```text
① 确认硬件接线、电源、时钟、复位和 PWDN
    ↓
② 确认 Sensor I2C Device 已创建
    ↓
③ 确认 Sensor Driver Match 并进入 probe()
    ↓
④ 确认 Chip ID 读取成功
    ↓
⑤ 确认 V4L2 Subdev 注册成功
    ↓
⑥ 确认 Media Graph 连接正确
    ↓
⑦ 确认 D-PHY / CSI-2 / RKCIF 正常
    ↓
⑧ 确认出现 /dev/videoX
    ↓
⑨ 使用 STREAMON 抓取 RAW Frame
```

这套顺序可以把问题分成硬件、电源、I2C、驱动、媒体拓扑和视频节点几个层次，避免把所有问题都归结为 Device Tree 配置错误。
