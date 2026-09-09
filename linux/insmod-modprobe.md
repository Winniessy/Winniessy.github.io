# `insmod` 与 `modprobe` 学习笔记

## 1. 它们解决什么问题

Linux 内核可以把部分驱动编译成可动态加载的内核模块，文件通常以 `.ko` 结尾，例如：

```text
aic8800_bsp.ko
aic8800_fdrv.ko
hid-generic.ko
```

`insmod` 和 `modprobe` 都可以把 `.ko` 模块加载进正在运行的 Linux 内核。二者最终都会使用 `init_module()` 或 `finit_module()` 一类系统调用完成加载，但加载前的处理能力不同：

- `insmod`：按指定文件直接加载，不主动解决依赖。
- `modprobe`：按模块名查找模块，并自动处理依赖、别名和配置。

一句话记忆：

```text
insmod  = 我明确指定这个 .ko 文件，请直接加载
modprobe = 请找到这个模块，并把它依赖的模块一起加载
```

## 2. 基本用法

### 2.1 使用 `insmod`

```bash
insmod /lib/modules/aic8800_bsp.ko
```

`insmod` 的参数是 `.ko` 文件路径。如果模块在当前目录：

```bash
insmod ./aic8800_bsp.ko
```

如果模块有参数：

```bash
insmod ./example.ko debug=1
```

### 2.2 使用 `modprobe`

```bash
modprobe aic8800_bsp
```

`modprobe` 的参数是模块名，一般不带路径和 `.ko` 后缀。

如果模块有参数：

```bash
modprobe example debug=1
```

`modprobe` 默认从下面的内核版本目录查找模块：

```text
/lib/modules/$(uname -r)/
```

## 3. 核心区别

| 对比项 | `insmod` | `modprobe` |
|---|---|---|
| 指定方式 | `.ko` 文件路径 | 模块名 |
| 自动查找模块 | 否 | 是 |
| 自动加载依赖 | 否 | 是 |
| 读取 `modules.dep` | 否 | 是 |
| 处理模块 alias | 否 | 是 |
| 处理 blacklist | 否 | 是 |
| 适合手动调试 | 很适合 | 适合 |
| 适合正式系统管理 | 一般 | 更适合 |
| 适合非标准模块目录 | 适合 | 需要额外配置 |
| 加载顺序控制 | 开发者显式控制 | 根据依赖关系自动控制 |

## 4. 一般分别用在什么场景

### 4.1 `insmod` 的典型场景

#### 场景一：正在开发或调试一个驱动

刚编译出模块时，它可能还没有安装到系统模块目录：

```text
build/
└── my_driver.ko
```

此时可以直接测试：

```bash
insmod ./my_driver.ko
dmesg | tail
```

这种方式路径明确，适合快速验证刚编译的模块。

#### 场景二：嵌入式根文件系统比较精简

一些 Buildroot 或厂商根文件系统中：

- 没有完整的 `modprobe` 工具；
- 没有生成 `modules.dep`；
- 模块放在厂商自定义目录；
- 只需要加载固定的几个驱动。

启动脚本可能直接写成：

```bash
insmod /vendor/modules/aic8800_bsp.ko
insmod /vendor/modules/aic8800_fdrv.ko
```

#### 场景三：需要严格控制加载顺序

例如厂商要求：

```text
先加载底层BSP模块
→ 加载固件辅助模块
→ 加载Wi-Fi功能模块
```

脚本可以显式控制：

```bash
insmod aic8800_bsp.ko
insmod aic_load_fw.ko
insmod aic8800_fdrv.ko
```

但这里的顺序应以实际厂商脚本和模块依赖为准。

#### 场景四：需要从指定位置加载特定版本

系统中可能已经存在同名模块，但调试时希望加载当前目录的新版本：

```bash
insmod ./test-version/my_driver.ko
```

这比按模块名搜索更直接，但必须确认模块和当前内核版本匹配。

### 4.2 `modprobe` 的典型场景

#### 场景一：模块已规范安装到系统目录

模块已经安装到：

```text
/lib/modules/$(uname -r)/kernel/...
```

并执行过：

```bash
depmod -a
```

这时优先使用：

```bash
modprobe 模块名
```

#### 场景二：模块存在多层依赖

假设：

```text
module_a 依赖 module_b
module_b 依赖 module_c
```

执行：

```bash
modprobe module_a
```

`modprobe` 会根据模块依赖信息，按顺序加载：

```text
module_c → module_b → module_a
```

使用 `insmod` 时则需要开发者自己确定顺序。

#### 场景三：正式发行系统或通用 Linux 系统

Ubuntu、Debian 等完整 Linux 系统通常使用 `modprobe`：

```bash
modprobe uhid
modprobe hid_generic
modprobe hci_uart
```

它更适合配合以下机制：

- udev 自动加载；
- 设备 ID 和模块 alias；
- systemd 服务；
- `/etc/modprobe.d/` 参数配置；
- blacklist；
- 模块依赖管理。

#### 场景四：根据硬件 ID 自动加载驱动

驱动模块可能声明 USB、PCI、SDIO 等设备别名。系统发现匹配硬件后，可以根据 alias 调用 `modprobe` 自动加载对应驱动。

例如：

```text
内核发现设备
→ 产生modalias
→ udev接收事件
→ modprobe根据alias找到模块
→ 加载驱动及其依赖
```

`insmod` 不具备按 alias 自动查找模块的能力。

## 5. 模块依赖是怎么来的

模块在编译时会记录自己引用的内核符号。模块安装后执行：

```bash
depmod -a
```

系统会扫描当前内核版本对应的模块目录，并生成依赖索引，例如：

```text
/lib/modules/$(uname -r)/modules.dep
/lib/modules/$(uname -r)/modules.alias
/lib/modules/$(uname -r)/modules.symbols
```

`modprobe` 会读取这些文件，`insmod` 不会。

查看一个模块的基本信息：

```bash
modinfo aic8800_fdrv
```

查看模块依赖字段：

```bash
modinfo -F depends aic8800_fdrv
```

只查看 `modprobe` 准备执行什么，而不真正加载：

```bash
modprobe --show-depends aic8800_fdrv
```

## 6. 加载过程

### 6.1 `insmod` 的处理过程

```text
指定.ko文件
→ 直接交给内核
→ 内核检查格式、版本和符号
→ 完成重定位
→ 调用模块初始化函数
```

如果依赖模块没有提前加载，内核可能找不到相应符号。

### 6.2 `modprobe` 的处理过程

```text
指定模块名
→ 查询modules.alias和modules.dep
→ 读取/etc/modprobe.d/配置
→ 检查blacklist和模块参数
→ 先加载依赖模块
→ 再加载目标模块
```

`modprobe` 最后仍然需要通过内核提供的模块加载系统调用完成真正加载。

## 7. 卸载模块

### 7.1 使用 `rmmod`

```bash
rmmod aic8800_fdrv
```

`rmmod` 直接要求内核卸载指定模块，不主动处理依赖关系。

### 7.2 使用 `modprobe -r`

```bash
modprobe -r aic8800_fdrv
```

`modprobe -r` 会考虑依赖关系，并可能卸载不再被使用的依赖模块。

如果模块正在被使用，可能看到：

```text
Module is in use
```

需要先停止正在使用该模块的网络接口、服务或设备。

## 8. 常见报错及排查

### 8.1 `Unknown symbol`

示例：

```text
Unknown symbol xxx
```

常见原因：

- 依赖模块没有加载；
- 依赖模块版本不一致；
- 所需内核符号没有导出；
- 模块编译配置与当前内核不同。

排查：

```bash
dmesg | tail -n 50
modinfo 模块名
modprobe --show-depends 模块名
```

如果是依赖缺失，优先尝试规范安装后使用 `modprobe`。

### 8.2 `Invalid module format`

常见原因是 `.ko` 与当前运行内核不匹配：

```bash
uname -r
modinfo -F vermagic ./my_driver.ko
```

需要确认内核版本、架构、编译选项和模块 vermagic 一致。

### 8.3 `Module not found`

常发生于：

```bash
modprobe my_driver
```

可能原因：

- 模块没有安装进 `/lib/modules/$(uname -r)/`；
- 模块目录对应的内核版本不正确；
- 安装后没有执行 `depmod -a`；
- 模块名写错。

排查：

```bash
find /lib/modules/$(uname -r) -name '*my_driver*.ko*'
depmod -a
modprobe my_driver
```

### 8.4 `Operation not permitted`

可能原因：

- 当前用户没有管理员权限；
- 内核禁止加载模块；
- Secure Boot 或模块签名校验失败；
- 系统启用了模块加载限制。

首先检查：

```bash
dmesg | tail -n 50
```

### 8.5 模块已经编进内核

如果某驱动配置为：

```text
CONFIG_XXX=y
```

它已经是内核的一部分，不存在需要加载的独立 `.ko` 文件，也不需要执行 `insmod` 或 `modprobe`。

如果配置为：

```text
CONFIG_XXX=m
```

才会生成可动态加载的 `.ko` 模块。

## 9. 如何确认模块是否加载成功

查看已加载模块：

```bash
lsmod
```

查找指定模块：

```bash
lsmod | grep aic8800
```

查看内核日志：

```bash
dmesg | tail -n 100
```

查看模块的 sysfs 信息：

```bash
ls /sys/module/aic8800_bsp
```

注意：模块出现在 `lsmod` 中只说明模块初始化成功，不代表硬件一定工作正常。还需要继续检查：

```text
驱动是否匹配到设备
固件是否加载成功
总线是否通信正常
目标设备节点或网络接口是否出现
```

例如 Wi-Fi 驱动还要确认：

```bash
ip link show wlan0
dmesg | grep -Ei 'aic|sdio|firmware|wlan'
```

## 10. 在 AIC8800/FCS960K 项目中的选择

厂商初始化脚本使用 `insmod` 或封装的 `try_insmod`，通常是为了：

- 明确选择当前板卡对应的驱动；
- 精确控制模块加载顺序；
- 从厂商目录加载模块；
- 兼容精简根文件系统；
- 在加载过程中插入固件、延时和错误处理逻辑。

示意流程：

```text
启动脚本
→ 检测AIC8800模组
→ insmod底层BSP模块
→ 加载模组运行固件
→ insmod Wi-Fi功能驱动
→ 等待wlan0出现
```

如果后续把驱动规范安装到：

```text
/lib/modules/$(uname -r)/
```

并正确生成 `modules.dep`，则可以改为：

```bash
modprobe aic8800_fdrv
```

由 `modprobe` 自动加载其依赖。是否能够这样替换，必须先通过 `modprobe --show-depends` 和实际上板测试确认，不能简单把所有 `insmod` 文本替换为 `modprobe`。

## 11. 选择建议

可以使用下面的判断方式：

```text
模块刚编译出来、需要快速调试？
├─ 是 → insmod ./xxx.ko
└─ 否
   ↓
模块已安装到/lib/modules/$(uname -r)？
├─ 否 → insmod指定路径，或先规范安装
└─ 是
   ↓
是否希望自动处理依赖和alias？
├─ 是 → modprobe xxx
└─ 否 → insmod明确控制顺序
```

一般建议：

- 驱动开发初期、厂商 bring-up 脚本：常用 `insmod`。
- 正式产品和完整 Linux 系统：优先使用 `modprobe`。
- 无论使用哪一种，都要结合 `dmesg` 和实际设备状态验证。

## 12. 面试回答模板

> `insmod` 和 `modprobe` 都用于加载 Linux 内核模块。`insmod` 直接加载指定路径下的 `.ko` 文件，不会主动解析依赖，适合驱动调试、精简根文件系统和需要严格控制加载顺序的厂商启动脚本；`modprobe` 按模块名从 `/lib/modules/$(uname -r)` 查找模块，并结合 `modules.dep`、alias 和 `/etc/modprobe.d` 配置自动处理依赖，更适合正式系统中的模块管理。项目中 Wi-Fi/BT 厂商脚本采用显式模块加载方式，以控制 AIC 底层模块、固件加载模块和功能驱动的初始化顺序。