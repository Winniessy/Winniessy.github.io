# RK3566上机检查

## KickPi K11C 安装 Ubuntu 24.04 后的系统检查与故障修复

## 1. 硬件与系统环境

设备信息：

- 开发板：KickPi K11C V1.2
- SoC：RK3566
- 内存：4GB
- 存储：32GB eMMC
- 系统：Ubuntu 24.04.4 LTS
- 内核：Linux 6.1.141
- 架构：AArch64

首先检查系统版本、内存和存储：

```bash
cat /etc/os-release
uname -a
lsblk
free -h
df -h /
```

检查结果：

- Ubuntu 系统和 RK3566 内核启动正常。
- 可用内存约 3.0GiB。
- eMMC 实际容量约 29GiB。
- 根分区已使用 5.5GiB，剩余约 22GiB。
- 当前没有 Swap，暂不影响正常使用。

网络方面，开发板已连接手机热点：

```bash
nmcli device status
ip -4 -br addr
ping -c 4 www.baidu.com
```

开发板获得地址 `192.168.172.6`，并且可以正常访问互联网。Windows 电脑也能够 Ping 通开发板并通过 SSH 登录。

## 2. 发现三个失败服务

使用下面的命令检查启动失败的 systemd 服务：

```bash
systemctl --failed --no-pager
```

首次检查发现三个失败服务：

```text
apport.service
networking.service
rockchip.service
```

问题汇总如下：

| 服务 | 根本原因 | 修复方法 |
|---|---|---|
| `rockchip.service` | Rockchip 初始化脚本调用了不存在的 `hwclock` | 安装 `util-linux-extra` |
| `networking.service` | 镜像配置了不存在的 `eth0` 和 `eth1` | 备份并移走错误配置 |
| `apport.service` | `/etc/os-release` 中的 `ID_LIKE` 配置错误 | 修正为 `ID_LIKE=debian` |

## 3. 修复 rockchip.service

首先查看服务状态：

```bash
systemctl status rockchip.service --no-pager -l
```

服务以状态码 `127` 退出。状态码 `127` 通常表示脚本调用的某个命令不存在。

进一步查看启动日志：

```bash
sudo journalctl -b -u rockchip.service -n 80 --no-pager
```

日志中的关键错误是：

```text
/etc/init.d/rockchip.sh: line 170: hwclock: command not found
```

说明 Rockchip 官方初始化脚本需要 `hwclock`，但镜像中没有安装提供该命令的软件包。

安装缺失组件：

```bash
sudo apt update
sudo apt install util-linux-extra
```

这里：

- `apt update` 只更新软件包索引。
- `apt install` 安装提供 `hwclock` 的组件。
- 没有执行完整的 `apt upgrade`，以避免意外更新厂商内核和多媒体组件。

确认命令已经存在：

```bash
command -v hwclock
```

输出：

```text
/usr/sbin/hwclock
```

测试读取硬件 RTC：

```bash
sudo hwclock --show
```

命令可以正常返回时间，说明 RTC 和 `hwclock` 都可以工作。

随后重新启动服务：

```bash
sudo systemctl restart rockchip.service
systemctl status rockchip.service --no-pager -l
```

修复后的关键结果：

```text
code=exited, status=0/SUCCESS
```

服务显示为 `inactive (dead)` 并不代表失败。它执行的是一次性平台初始化脚本，脚本完成后正常退出，因此重点应看退出状态是否为 `0/SUCCESS`。

日志中还出现过：

```text
warning: command substitution: ignored null byte in input
```

该警告没有导致脚本退出，真正导致原始故障的是缺少 `hwclock`。

## 4. 修正系统时区

硬件时钟最初显示：

```text
2026-09-11 17:51:52+00:00
```

它使用的是 UTC，并不是时间错误。北京时间是 UTC+8，对应：

```text
2026-09-12 01:51:52
```

系统最初使用 `Etc/UTC` 时区，因此将显示时区改为上海：

```bash
sudo timedatectl set-timezone Asia/Shanghai
timedatectl
```

修改后：

```text
Local time: Sat 2026-09-12 01:57:11 CST
Universal time: Fri 2026-09-11 17:57:11 UTC
Time zone: Asia/Shanghai (CST, +0800)
RTC in local TZ: no
```

让 RTC 保持 UTC 是 Linux 推荐的做法，所以：

```text
RTC in local TZ: no
```

属于正常状态。

## 5. 修复 networking.service

查看服务日志：

```bash
sudo journalctl -b -u networking.service -n 80 --no-pager
```

关键错误：

```text
Cannot find device "eth0"
Cannot find device "eth1"
ifup: failed to bring up eth0
ifup: failed to bring up eth1
```

查看实际网络接口：

```bash
ip -br link
```

结果表明开发板实际接口为：

```text
lo
end1
wlan0
```

其中：

- `wlan0` 是无线网卡，工作正常。
- `end1` 是有线网卡。
- `end1` 显示 `NO-CARRIER`，只是因为没有插网线，不代表驱动故障。
- 系统中不存在 `eth0` 和 `eth1`。

查看传统网络配置：

```bash
cat /etc/network/interfaces
ls -la /etc/network/interfaces.d/
grep -RInE 'eth0|eth1' /etc/network/interfaces.d/
```

发现两个错误的预置文件：

```text
/etc/network/interfaces.d/eth0
/etc/network/interfaces.d/eth1
```

内容分别要求系统通过 DHCP 启动不存在的 `eth0` 和 `eth1`。

为了保留恢复能力，没有删除文件，而是先创建备份目录：

```bash
sudo mkdir -p /etc/network/interfaces.disabled
```

然后把错误配置移出自动加载目录：

```bash
sudo mv /etc/network/interfaces.d/eth0 \
             /etc/network/interfaces.d/eth1 \
             /etc/network/interfaces.disabled/
```

重新启动网络初始化服务：

```bash
sudo systemctl restart networking.service
systemctl status networking.service --no-pager -l
```

修复后显示：

```text
Active: active (exited)
status=0/SUCCESS
```

`active (exited)` 表示初始化任务已经成功完成。Wi-Fi 仍由 NetworkManager 管理，因此操作过程中 SSH 没有断开。

## 6. 修复 apport.service

Apport 是 Ubuntu 的自动崩溃报告服务。查看日志：

```bash
sudo journalctl -b -u apport.service -n 80 --no-pager
```

关键错误：

```text
RuntimeError: Could not determine system package manager.
Please file a bug and provide /etc/os-release!
```

检查 Apport 的判断逻辑：

```bash
sed -n '1,70p' \
/usr/lib/python3/dist-packages/apport/packaging_impl/__init__.py
```

代码会读取 `/etc/os-release`，只有 `ID` 或 `ID_LIKE` 中包含 `debian`，才会选择 `apt/dpkg` 实现。

检查相关文件：

```bash
ls -l /etc/os-release \
      /etc/debian_version \
      /usr/bin/apt \
      /usr/bin/dpkg
```

这些文件和命令都存在。真正的问题在 `/etc/os-release`：

```text
ID=ubuntu
ID_LIKE=ubuntu
```

Ubuntu 使用 Debian 的软件包体系，因此这里应当包含：

```text
ID_LIKE=debian
```

修改前先备份原文件：

```bash
sudo cp -a /etc/os-release \
    /etc/os-release.before-apport-fix
```

然后修正配置：

```bash
sudo sed -i \
's/^ID_LIKE=.*/ID_LIKE=debian/' \
/etc/os-release
```

验证结果：

```bash
grep -E '^(ID|ID_LIKE)=' /etc/os-release
```

输出：

```text
ID=ubuntu
ID_LIKE=debian
```

重新启动 Apport：

```bash
sudo systemctl restart apport.service
systemctl status apport.service --no-pager -l
```

结果：

```text
Active: active (exited)
status=0/SUCCESS
```

## 7. 重启并进行最终复查

完成修复后安全重启开发板：

```bash
sudo reboot
```

重新连接 SSH 后检查失败服务：

```bash
systemctl --failed --no-pager
```

最终结果：

```text
UNIT LOAD ACTIVE SUB DESCRIPTION

0 loaded units listed.
```

再次检查时间：

```bash
timedatectl
```

确认以下配置在重启后仍然生效：

```text
Time zone: Asia/Shanghai (CST, +0800)
RTC in local TZ: no
```

## 8. 最终结论

本次检查说明：

- Ubuntu 24.04 已成功安装到 eMMC。
- 内存、存储、HDMI、USB、Wi-Fi、SSH 和 RTC 工作正常。
- Rockchip 平台初始化脚本已经恢复正常。
- 镜像中残留的错误网卡配置已备份并停用。
- Ubuntu 崩溃报告服务已经恢复。
- 重启后 systemd 没有失败服务。

这次遇到的三个故障都来自厂商定制镜像的软件配置，并不是 RK3566、eMMC 或网卡硬件损坏。下一阶段可以开始检查视频编解码、V4L2、RKVENC/RKMPP 以及摄像头驱动环境，为后续 RTSP 推流做准备。
