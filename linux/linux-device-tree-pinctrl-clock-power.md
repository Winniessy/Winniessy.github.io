# Linux Device Tree 与板级资源管理：从 MCU 思维理解 pinctrl、clock 和电源

刚从 MCU 转到嵌入式 Linux 时，Device Tree（设备树）很容易给人一种感觉：

> 为什么 Linux 驱动不直接把 GPIO、Clock、PinMux、电源这些东西配好，非要另外搞一份设备树？

其实这些东西 MCU 里也存在，只是 MCU 项目往往把它们分散在 CubeMX、HAL 初始化代码、BSP 和应用初始化里，而 Linux 把其中大量**板级硬件描述**独立了出来。

可以先记住一句话：

> **Driver 负责“这个硬件 IP 怎么工作”，Device Tree 负责“这块板子具体怎么使用这个硬件”。**

---

# 一、Device Tree 到底在描述什么

Device Tree 不是单纯用来写 `compatible` 的。

它更重要的作用是描述：

```text
这块板上有哪些硬件
硬件之间怎么连接
硬件使用哪些资源
```

例如一个 I2C Sensor：

```dts
sensor@48 {
    compatible = "vendor,sensor";
    reg = <0x48>;

    reset-gpios = <&gpio2 3 GPIO_ACTIVE_LOW>;
    vdd-supply = <&vcc_3v3>;
};
```

这实际上已经描述了：

```text
设备是谁
→ compatible

挂在哪里
→ I2C Address = 0x48

Reset 接到哪里
→ GPIO2_3

电源来自哪里
→ vcc_3v3
```

如果换一块板子：

```text
Reset 改到 GPIO4_7
电源改成 1.8V
```

理论上 Driver 本身不应该因此重写。

主要修改：

```text
Board Device Tree
板级设备树
```

即可。

---

# 二、为什么 MCU 里感觉没有这么明显

因为 MCU 项目通常会写成：

```c
void Sensor_Init(void)
{
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_I2C1_CLK_ENABLE();

    HAL_GPIO_Init(...);
    HAL_I2C_Init(...);

    HAL_GPIO_WritePin(...);
}
```

这里实际上揉在一起了很多东西：

```text
Clock
GPIO
PinMux
电源控制
I2C Controller
Sensor 初始化
```

开发者自己知道：

```text
PB6 / PB7 是 I2C
Sensor 电源接哪个 GPIO
使用 I2C1
```

所以很自然地直接写在初始化代码里。

Linux 的想法不同。

它希望：

```text
硬件连接关系
```

和：

```text
硬件驱动实现
```

尽量分离。

---

# 三、什么叫“SoC 公共驱动”和“板级配置分开”

假设 Rockchip 设计了一颗 RK3588。

RK3588 内部有：

```text
SPI0
SPI1
SPI2
I2C0
I2C1
UART
GPIO
PWM
...
```

SPI Controller（SPI 控制器）的硬件逻辑在芯片设计完成以后基本就是固定的。

例如：

```text
SPI FIFO 怎么操作
SPI 寄存器怎么配置
DMA 怎么启动
Clock 怎么控制
数据长度怎么配置
SPI Mode 怎么设置
```

这些东西和你把 RK3588 焊在哪块 PCB 上没有太大关系。

所以 Linux 可以写一份通用的：

```text
Rockchip SPI Controller Driver
```

负责：

> RK3588 的 SPI 控制器本身怎么工作。

---

但是不同开发板可能完全不同。

例如开发板 A：

```text
SPI2 使用 M0 引脚
CS0 接 LCD
最高频率 20 MHz
LCD 电源 3.3V
```

开发板 B：

```text
SPI2 使用 M2 引脚
CS0 接 ADC
最高频率 10 MHz
ADC 电源 1.8V
```

如果这些东西也硬编码在 SPI Driver 里，就会变成：

```text
Board A 改一次驱动
Board B 再改一次驱动
Board C 再复制一个版本
```

这样公共驱动就完全失去复用意义。

所以 Linux 把它拆成：

```text
SoC / Controller Driver

负责：
“SPI Controller 怎么工作？”
```

和：

```text
Board Device Tree

负责：
“这块 PCB 怎么使用 SPI Controller？”
```

---

# 四、换成 STM32 思维就很好理解

假设 STM32F4：

```c
HAL_SPI_Transmit();
```

这是比较通用的。

你不会因为：

```text
板 A：
SPI1 → PA5 / PA6 / PA7

板 B：
SPI1 → PB3 / PB4 / PB5
```

就重新实现：

```c
HAL_SPI_Transmit();
```

变化的是：

```text
GPIO Alternate Function
GPIO 初始化
板级连线
```

Linux 只是把这层分离得更加彻底：

```text
MCU

HAL Driver
+
CubeMX / MSP / BSP 配置
```

对应：

```text
Linux

Controller Driver
+
Device Tree
```

所以：

> **Device Tree 可以粗略理解为 Linux 中很大一部分 Board Configuration（板级配置）的承载方式。**

---

# 五、PinMux 到底是什么

PinMux：

```text
Pin Multiplexing
引脚复用
```

这个概念 MCU 其实一直都有。

例如 STM32：

```c
GPIO_InitStruct.Alternate = GPIO_AF5_SPI1;
```

本质就是：

```text
PA5
  │
  ├── GPIO
  ├── SPI1_SCK
  ├── TIM
  └── 其他功能
```

配置：

```text
AF5
```

以后：

```text
PA5 → SPI1_SCK
```

这就是 PinMux。

---

# 六、为什么 RK3588 的 PinMux 看起来特别复杂

这主要不是 Linux 的原因，而是 SoC 本身复杂。

STM32F4 可能只有：

```text
几个 SPI
几个 UART
几个 I2C
几十到一百多个 Pin
```

而 RK3588 集成了大量控制器：

```text
UART
SPI
I2C
PWM
I2S
SDMMC
SDIO
PCIe
GMAC
MIPI
HDMI
eDP
...
```

芯片不可能为每一个 Controller 都准备完全独立的 Pin。

因此大量物理引脚都需要复用。

一个 Pin 可能概念上有：

```text
GPIO
UART
SPI
PWM
I2S
其他功能
```

同时一个 Controller 甚至可能有多套输出路线。

例如：

```text
SPI2

├── M0 → A组 Pin
├── M1 → B组 Pin
└── M2 → C组 Pin
```

所以你在 RK3588 Device Tree 中经常会看到：

```text
spi2m0
spi2m1
spi2m2
```

它们可以理解成：

> 同一个 SPI2 Controller 的不同 Pin Route（引脚路由方案）。

---

# 七、并不是“不使用默认引脚才需要 PinMux”

这里很容易产生误解。

不能简单理解成：

```text
芯片有一套默认 SPI 引脚
如果不用默认的才需要 PinMux
```

更准确地说，芯片内部通常存在：

```text
物理 Pin
   ↓
MUX
   ├── GPIO
   ├── SPI
   ├── UART
   └── PWM
```

芯片 Reset（复位）以后，Pin 通常处于某种默认安全状态，例如：

```text
GPIO Input
```

如果你希望它真正承担：

```text
SPI2_SCLK
```

就需要选择对应功能。

Linux 中可能写：

```dts
pinctrl-names = "default";
pinctrl-0 = <&spi2m2_pins>;
```

这里的：

```text
"default"
```

不是：

> 芯片默认使用 M2。

而是：

> 这个设备处于正常工作状态时使用的默认 pinctrl state。

这是两个完全不同的“默认”。

---

# 八、Pinctrl 比 PinMux 范围更大

PinMux 主要回答：

> 这个 Pin 接给谁？

例如：

```text
GPIO → SPI2_SCLK
```

而 Pinctrl（Pin Control，引脚控制框架）通常还可能管理：

```text
PinMux
Pull-up / Pull-down
Drive Strength
Slew Rate
Input Enable
Output Configuration
```

所以：

```text
PinMux
```

可以认为是：

```text
Pinctrl
```

里面最重要的一部分。

例如 SPI Pin 可能不只是选择：

```text
这个 Pin 给 SPI
```

还可能同时配置：

```text
Drive Strength：驱动能力
Pull：上下拉
Slew Rate：边沿速率
```

高性能 SoC 里这些配置比普通 MCU 更常见、更复杂。

---

# 九、Clock：Linux 为什么也要专门管理时钟

MCU 里面你应该很熟：

```c
__HAL_RCC_SPI1_CLK_ENABLE();
```

外设没有 Clock（时钟），寄存器或者状态机通常就无法正常工作。

Linux 也是一样。

例如 RK3588 某个 SPI Controller 可能需要：

```text
Bus Clock
Functional Clock
```

Device Tree 可能描述：

```dts
clocks = <&cru CLK_SPI2>, <&cru PCLK_SPI2>;
```

这里表示：

> 这个设备依赖这些 Clock。

Driver 再通过 Linux Common Clock Framework（公共时钟框架）使用这些资源。

例如概念上：

```c
clk = devm_clk_get(dev, NULL);

clk_prepare_enable(clk);
```

所以 MCU：

```text
RCC
 ↓
Enable SPI Clock
```

Linux：

```text
Device Tree
 ↓
Clock Framework
 ↓
Controller Driver
```

硬件本质没有变化。

---

# 十、为什么 Linux 不直接在 Driver 里写死 Clock

因为不同 SoC：

```text
Clock Tree
时钟树
```

可能完全不同。

甚至：

```text
RK3566
RK3588
RK3576
```

同类 Controller 所依赖的时钟数量、名字、Parent Clock（父时钟）都可能变化。

Linux 希望 Driver 只说：

> “我要这个 Clock。”

而不是：

> “直接给 CRU 某个寄存器第 17 位写 1。”

于是就有：

```text
Common Clock Framework
```

统一管理 Clock。

---

# 十一、Reset 也是一样

MCU 里经常会有：

```text
Peripheral Reset
```

例如：

```c
__HAL_RCC_SPI1_FORCE_RESET();
__HAL_RCC_SPI1_RELEASE_RESET();
```

Linux 也需要管理硬件 Reset。

设备树可能写：

```dts
resets = <&cru SRST_SPI2>;
```

Driver 使用：

```text
Reset Framework
```

来：

```text
Assert Reset
Deassert Reset
```

所以：

```text
MCU RCC Reset
```

和：

```text
Linux Reset Framework
```

本质上解决的是同一类问题。

---

# 十二、Linux 的 Power Management 为什么看起来复杂很多

MCU 中 Power Management（电源管理）往往比较直接。

例如：

```text
关闭某个 Sensor
关闭 LCD
关闭 SPI Clock
进入 Sleep
进入 STOP
```

很多时候由应用代码直接决定。

但 RK3588 这类 SoC 里面可能同时有：

```text
CPU
GPU
NPU
ISP
VOP
USB
PCIe
Video Codec
Camera
Display
Audio
```

很多模块平时可能根本不用。

如果一直全部供电：

```text
功耗会非常高。
```

所以 Linux 需要更加精细地管理：

```text
Clock
Regulator
Power Domain
Runtime PM
System Suspend
```

---

# 十三、Regulator 是什么

Regulator（稳压器/电源调节器）可以理解成：

> Linux 对板级电源轨的一种统一抽象。

例如板子上：

```text
PMIC
  │
  ├── 1.8V
  ├── 3.3V
  └── 5V
```

某个 Sensor：

```text
VDD → 3.3V
```

设备树可能写：

```dts
vdd-supply = <&vcc_3v3>;
```

于是 Driver 不需要知道：

```text
这块板到底用了哪个 PMIC
PMIC 哪个寄存器控制 3.3V
```

它只需要：

```text
我要 vdd 电源。
```

然后通过 Regulator Framework（电源调节器框架）：

```c
regulator_enable();
regulator_disable();
```

控制。

---

# 十四、Power Domain 又是什么

Power Domain（电源域）主要常见于复杂 SoC。

例如 RK3588 内部可能把：

```text
GPU
NPU
ISP
Video
Display
```

划分成不同电源域。

不用的时候，可以直接：

```text
整个硬件区域断电
```

这比：

```text
只关闭一个 Clock
```

省电更多。

所以大致可以理解：

```text
Clock Gating
→ 设备不跑，但可能仍然供电

Power Domain Off
→ 一整块硬件区域直接断电
```

MCU 里的 STOP / Standby 或某些 Peripheral Power Domain，也有类似思想，只是高性能 SoC 的粒度和依赖关系复杂得多。

---

# 十五、Runtime PM 是什么

Runtime PM：

```text
Runtime Power Management
运行时电源管理
```

主要解决：

> 系统还在正常运行，但某个设备暂时没人使用，要不要把它关掉？

例如：

```text
Camera 现在没人打开
 ↓
ISP 空闲
 ↓
Clock 可以关
Power Domain 可以关
```

等用户以后：

```text
打开 Camera
```

再重新上电。

所以：

```text
System Suspend
```

是整个系统进入睡眠。

而：

```text
Runtime PM
```

是：

> 系统没睡，但是某个设备自己可以睡。

这对 SoC 功耗非常重要。

---

# 十六、电源管理和 MCU 最主要的区别

MCU 经常是：

```text
Application
 ↓
“我知道现在不用 LCD”
 ↓
手动关 LCD
 ↓
手动关 Clock
```

Linux 中：

```text
User Space
Driver
Subsystem
Power Domain
Clock
Regulator
```

可能同时存在很多使用者。

所以不能由某一个 Driver 随便：

```text
把公共电源关了
```

否则：

```text
另一个设备可能还在用。
```

因此 Linux 更强调：

```text
Reference Count
资源依赖
统一 Framework
```

谁申请、谁释放，由 Framework 统一判断资源到底能不能关闭。

---

# 十七、Device Tree + Framework + Driver 的关系

可以把它理解成：

```text
Device Tree

负责描述：
“我有什么资源？”
        │
        ↓
Linux Framework

负责管理：
“这些资源怎么统一控制？”
        │
        ↓
Driver

负责使用：
“我要哪些资源？”
```

例如一颗设备：

```dts
device@xxx {
    clocks = <&cru CLK_XXX>;

    resets = <&cru SRST_XXX>;

    power-domains = <&power RK3588_PD_XXX>;

    vdd-supply = <&vcc_3v3>;

    pinctrl-names = "default";
    pinctrl-0 = <&device_pins>;
};
```

可以理解成：

```text
我要工作需要：

Pin
Clock
Reset
Power Domain
3.3V 电源
```

Driver 再去获取这些资源：

```text
pinctrl
clock
reset
regulator
runtime PM
```

---

# 十八、Device Tree 不是 Driver 配置文件那么简单

很多人会把 Device Tree 理解成：

> Linux Driver 的参数文件。

这个理解太窄。

Device Tree 更像：

> **对硬件拓扑和板级资源关系的描述。**

例如：

```text
哪个 Controller 存在
寄存器范围
使用哪些 Clock
连接哪个 GPIO
供电来自哪里
使用哪组 Pin
SPI 上挂了什么设备
I2C 地址是多少
```

这些都属于：

```text
Hardware Description
硬件描述
```

---

# 十九、从 MCU 角度重新看 Device Tree

MCU 工程里经常有：

```text
CubeMX
startup
HAL_MspInit()
Board Init
BSP
```

这些地方共同完成：

```text
PinMux
Clock
GPIO
外设实例选择
板级连接
电源
```

Linux 把其中大量内容变成：

```text
Device Tree
+
对应 Kernel Framework
```

所以可以粗略对应：

| MCU / FreeRTOS          | Linux                  |
| ----------------------- | ---------------------- |
| GPIO Alternate Function | pinctrl / PinMux       |
| CubeMX Pin 配置           | Device Tree pinctrl    |
| RCC Clock               | Common Clock Framework |
| Peripheral Reset        | Reset Framework        |
| GPIO 控制电源 EN            | Regulator / GPIO       |
| 电源域控制                   | Generic Power Domain   |
| 应用手动关外设                 | Runtime PM             |
| Board Init              | Board Device Tree      |
| HAL 底层外设驱动              | Controller Driver      |

这里不是严格的一一映射，但非常适合建立初期理解。

---

# 二十、拿 RK3588 + SPI 外设完整看一遍

假设硬件：

```text
RK3588
   │
SPI2
   │
ADC
```

RK3588 内部：

```text
SPI2 Controller
```

由公共的：

```text
Rockchip SPI Controller Driver
```

负责。

板级 Device Tree：

```dts
&spi2 {
    pinctrl-names = "default";
    pinctrl-0 = <&spi2m2_pins>;

    status = "okay";

    adc@0 {
        compatible = "vendor,adc";
        reg = <0>;
        spi-max-frequency = <10000000>;
        vdd-supply = <&vcc_3v3>;
    };
};
```

这里描述：

```text
SPI2 被启用
使用 M2 这组 Pin
CS0 接 ADC
最高 SPI 频率 10 MHz
ADC 使用 3.3V 电源
```

Controller Driver 不需要知道：

```text
板子上到底接的是 ADC 还是 LCD
Pin 具体走哪组
ADC 电源从哪里来
```

这些都属于 Board Configuration（板级配置）。

---

# 二十一、最重要的理解：Linux Driver 不应该拥有整块板

MCU 项目里很容易形成：

```text
我的 Driver
自己开 Clock
自己配 GPIO
自己控制电源
自己决定 PinMux
```

因为整个 Firmware（固件）本来就是一个整体。

Linux 不一样。

Driver 只是整个 Kernel（内核）中的一个组件。

所以更推荐：

```text
不要：
Driver 直接写死板级资源

而是：

Driver
 ↓
向 Framework 申请资源

Framework
 ↓
根据 Device Tree
找到真实硬件资源
```

也就是说：

```text
Driver：
“我要一个 reset GPIO”

Device Tree：
“reset GPIO 是 GPIO2_3”
```

或者：

```text
Driver：
“我要 vdd”

Device Tree：
“vdd 来自 vcc_3v3”
```

这样同一个 Driver 才能在不同板子上复用。

---

# 二十二、最后把主线记成这一张图

```text
                   硬件设计

RK3588 SoC                  PCB Board
     │                         │
     │                         │
SPI Controller            SPI 接到哪组 Pin
I2C Controller            外设接在哪
GPIO                       使用哪个电源
Clock                      Reset 怎么接
     │                         │
     └────────────┬────────────┘
                  ↓

             Device Tree
           描述硬件与连接
                  │
                  ↓

        Linux Resource Framework

     pinctrl
     clock
     reset
     regulator
     power domain
     runtime PM

                  │
                  ↓

               Driver

       获取资源并操作硬件
```

可以把这一篇最后压缩成一句话：

> **MCU 往往把 PinMux、Clock、Reset、电源和板级连接直接写进 BSP 或初始化代码，而 Linux 为了让同一份 SoC/Controller Driver 能复用于不同板卡，把“硬件怎么工作”和“板子怎么连接”分开：前者交给 Driver，后者主要由 Device Tree 描述，再通过 pinctrl、clock、reset、regulator、power domain 等内核 Framework 统一管理资源。**

这也是理解嵌入式 Linux BSP 最重要的一条主线：

```text
SoC Hardware
      ↓
通用 Driver
      +

Board Hardware
      ↓
Device Tree
      ↓
Kernel Framework
      ↓
最终组成一块真正能工作的板子
```