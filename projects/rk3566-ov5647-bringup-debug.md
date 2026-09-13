# RK3566 + OV5647 Camera Bring-up 问题排查记录

## 1. 硬件与现象

本次环境：

```text
KICKPI K11C（RK3566）
OV5647
I2C 控制 + MIPI CSI-2 图像传输
```

最开始通过 `dmesg` 看到：

```text
ov5647 2-0036: driver version: 00.01.01
ov5647 2-0036: OV5647 power on
ov5647 2-0036: OV5647 power off
```

但是没有出现：

```text
OmniVision OV5647 camera driver probed
```

这说明驱动已经进入 `probe()`，Sensor 也执行了上电，但 `probe()` 中途失败，最终没有完成 bind。

## 2. 确认 Device Tree 是否创建了 I2C Device

查看 I2C 设备：

```bash
ls /sys/bus/i2c/devices/
```

发现：

```text
2-0036
```

其中：

```text
2     = I2C Bus 2
0036  = I2C 地址 0x36
```

对应的设备树节点类似：

```dts
ov5647@36 {
    reg = <0x36>;
};
```

这说明设备树已经被内核解析，并创建出了 `struct i2c_client`。

但 `/sys/bus/i2c/devices/2-0036` 存在，只能说明软件层的 Device 创建成功，不代表物理摄像头已经能够正常进行 I2C 通信。排线接反时，这个目录同样可能存在。

## 3. 检查 Driver 是否成功 Bind

进入设备目录：

```bash
cd /sys/bus/i2c/devices/2-0036
ls
```

当时可以看到：

```text
modalias
name
of_node
power
subsystem
uevent
```

但没有看到：

```text
driver -> ...
```

成功绑定 OV5647 后，通常应该存在类似链接：

```text
driver -> /sys/bus/i2c/drivers/ov5647
```

因此当时的状态是：

```text
Device 存在
Driver 已匹配并进入 probe()
probe() 返回失败
没有 driver symlink
```

需要区分两个概念：

```text
probe = Driver 尝试识别和初始化设备的过程
bind  = probe 成功后，Device 和 Driver 建立正式绑定关系
```

典型过程是：

```text
Device 创建
    ↓
Driver Match
    ↓
probe()
    ↓
return 0
    ↓
Bind 成功
```

## 4. 排除 Deferred Probe / Supplier 问题

当时还看到过：

```text
waiting_for_supplier
supplier:platform:csi2-dphy0
supplier:platform:vcc-camera-regulator
```

检查：

```bash
cat /sys/bus/i2c/devices/2-0036/waiting_for_supplier
```

输出：

```text
0
```

这说明当前并不是因为 D-PHY 或 Regulator 尚未准备好导致的 Deferred Probe，问题范围可以继续缩小到 `ov5647_probe()` 内部。

## 5. 检查实际 I2C 通信

执行：

```bash
i2cdetect -y 2
```

`i2cdetect` 用于扫描指定 I2C 总线上能够返回 ACK 的地址。

常见结果：

```text
36
```

表示 `0x36` 有设备响应。

```text
UU
```

一般表示该地址已经被内核驱动占用。

当时扫描结果为：

```text
0x36 → --
```

说明扫描时 `0x36` 没有响应。但不能立即据此判断 Sensor 损坏，因为 Sensor 当时已经执行了 `power_off`。Sensor 断电或处于 PWDN 状态时，`i2cdetect` 同样可能显示 `--`。

因此，`i2cdetect` 只能作为辅助判断，必须结合 Sensor 的电源、复位和 PWDN 状态分析。

## 6. 根据日志追踪 `probe()` 源码

`ov5647_probe()` 的关键流程可以概括为：

```text
解析 DTS
    ↓
获取 xclk
    ↓
获取 PWDN GPIO
    ↓
初始化 Control
    ↓
初始化 V4L2 Subdev
    ↓
初始化 Media Entity
    ↓
ov5647_power_on()
    ↓
ov5647_detect()
    ↓
注册 V4L2 Subdev
    ↓
Runtime PM
    ↓
probe success
```

由于日志已经出现：

```text
OV5647 power on
```

所以 DTS 解析、Clock、GPIO、Control 和 Media Entity 等前置步骤基本已经通过。问题进一步缩小到：

```c
ret = ov5647_detect(sd);
if (ret < 0)
    goto power_off;
```

## 7. 继续追踪 `ov5647_detect()`

`detect()` 的作用是确认芯片身份，典型流程如下：

```text
I2C Write Software Reset
    ↓
Read CHIPID_H，期望 0x56
    ↓
Read CHIPID_L，期望 0x47
    ↓
得到 0x5647
```

核心逻辑类似：

```c
ov5647_write(...);

ov5647_read(OV5647_REG_CHIPID_H);
/* 期望 0x56 */

ov5647_read(OV5647_REG_CHIPID_L);
/* 期望 0x47 */
```

也就是说，`probe()` 真正访问物理 OV5647，是在这里通过 I2C 读写寄存器。

如果物理通信失败，调用链就是：

```text
ov5647_detect()
    ↓
return error
    ↓
goto power_off
    ↓
probe() 失败
    ↓
Bind 失败
```

## 8. 最终根因与修复

最终发现问题是：

> 摄像头 FPC 排线接反。

实际故障链：

```text
DTS 正常
    ↓
创建 2-0036
    ↓
compatible 匹配 ov5647 driver
    ↓
进入 ov5647_probe()
    ↓
Sensor power_on
    ↓
ov5647_detect()
    ↓
因为排线接反，物理 I2C 通信失败
    ↓
detect 返回失败
    ↓
probe 失败
    ↓
power_off
    ↓
没有 driver symlink
```

重新正确插入排线后：

```text
I2C 通信恢复
    ↓
Chip ID = 0x5647
    ↓
detect 成功
    ↓
V4L2 Subdev 注册成功
    ↓
probe return 0
    ↓
Bind 成功
```

最终日志出现：

```text
OmniVision OV5647 camera driver probed
dphy0 matches m00_b_ov5647 2-0036
```

说明 OV5647 已经完成驱动绑定，并与 CSI2 D-PHY 建立连接。

## 9. 本次排错流程总结

以后遇到 I2C Sensor，可以按照下面顺序排查：

```text
DTS Device 存不存在？
    ↓
Driver 有没有 Match？
    ↓
有没有进入 probe？
    ↓
probe 卡在哪一步？
    ↓
实际 I2C 有没有通信？
    ↓
Clock / GPIO / Regulator / RESET / PWDN 是否正确？
    ↓
最后检查硬件连接和排线方向
```

这次的关键经验是：不要一开始就修改 DTS 或 Driver，先根据设备目录、日志、`waiting_for_supplier`、I2C 响应和 `probe()` 源码逐步缩小问题范围。
