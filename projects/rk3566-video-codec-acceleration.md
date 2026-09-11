# RK3566 视频编解码与硬件加速环境检查记录

## 一、为什么要分层检查

RK3566 的视频硬件是否可用，不能只看某一个设备文件或某个软件命令，而要逐层确认：

```text
设备树
  ↓
内核驱动
  ↓
/dev 设备节点
  ↓
用户态 MPP/RGA/Mali 库
  ↓
GStreamer/FFmpeg 插件
  ↓
实际编码与解码测试
```

例如，看到 `/dev/mpp_service` 只能说明驱动创建了接口；只有实际完成一段 H.264/H.265 编码并正常输出，才能证明整条路径真正可用。

本次检查的目标包括：

- RK3566 视频编解码驱动是否加载。
- MPP、RGA、GPU、ISP 设备节点是否存在。
- 普通用户是否有访问权限。
- Rockchip 用户态动态库是否齐全。
- GStreamer 是否带有 Rockchip MPP 插件。
- FFmpeg 是否能直接调用 Rockchip 硬件。
- H.264/H.265 编码和解码能否实际运行。

---

## 二、检查设备节点

执行：

```bash
ls -l /dev/mpp_service /dev/rga /dev/video* /dev/media* /dev/dri 2>&1
```

发现的主要节点如下。

| 节点 | 类型 | 用途 |
|---|---|---|
| `/dev/mpp_service` | 字符设备 | Rockchip MPP 内核接口，负责视频硬件编解码任务 |
| `/dev/rga` | 字符设备 | RGA 图像缩放、裁剪、旋转、格式转换接口 |
| `/dev/video0`～`video9` | 字符设备 | V4L2 视频设备，本机实际属于 RKISP |
| `/dev/media0` | 字符设备 | Linux Media Controller，描述 CSI、ISP、传感器之间的媒体拓扑 |
| `/dev/dri/card0`、`card1` | DRM设备 | 显示、NPU等 DRM 设备的控制节点 |
| `/dev/dri/renderD128`、`renderD129` | Render节点 | 无需控制显示模式的渲染类接口 |
| `/dev/video-camera0` | 符号链接 | 指向 `/dev/video0` 的厂商摄像头别名 |
| `/dev/video-dec0`、`video-enc0` | 普通文件 | 不是标准字符设备，也没有被 V4L2 枚举为编解码器 |

在 `ls -l` 的输出中：

- `c` 开头表示字符设备，例如 `crw-rw----`。
- `l` 开头表示符号链接。
- `-` 开头表示普通文件。

因此，`video-dec0` 和 `video-enc0` 虽然名字像编解码器，但它们只是4字节普通文件，不能直接当成 V4L2 编解码设备使用。

设备节点检查只能证明驱动接口存在，不能单独证明硬件可以成功工作。

---

## 三、检查内核驱动日志

执行：

```bash
sudo dmesg | grep -Ei 'mpp|rga|vpu|rkvdec|rkvenc|hantro|v4l2|isp|camera|gpu|drm'
```

关键结果包括：

```text
mpp_service mpp-srv: probe success
rga: Module initialized. v1.3.11
mpp_rkvenc ... probing finish
mpp_vdpu2 ... probing finish
mpp_vepu2 ... probing finish
mpp_jpgdec ... probing finish
mpp_rkvdec2 ... probing finish
mali ... Probed as mali0
```

对应含义：

- `mpp_service`：MPP核心服务初始化成功。
- `mpp_rkvenc`：RKVENC编码器已加载。
- `mpp_vepu2`：VEPU2编码单元已加载。
- `mpp_vdpu2`：VDPU2解码单元已加载。
- `mpp_rkvdec2`：RKVDEC2解码单元已加载。
- `mpp_jpgdec`：JPEG硬件解码单元已加载。
- `rga`：RGA驱动和IOMMU绑定成功。
- `mali0`：Mali GPU驱动完成探测。

### 日志中需要记录的警告

```text
mpp_rkvenc ... no regulator, devfreq is disabled
```

编码器没有启用动态电压和频率调节。当前720P测试正常，但以后进行1080P、4K、长时间运行或功耗测试时需要继续关注。

```text
shared_niu_a is not found
shared_niu_h is not found
```

RKVDEC2没有找到某些共享复位资源，但驱动随后完成了探测，并且实际解码测试成功。因此目前不应仅根据这两条日志修改设备树。

```text
Couldn't find power_model DT node
No thermal zone specified
```

Mali设备树缺少部分功耗模型参数，驱动使用了备用模型。GPU仍然成功初始化，这不是当前视频编解码的阻塞问题。

```text
rkisp-vir0: update sensor failed
```

当前没有安装MIPI摄像头，所以ISP找不到传感器符合实际情况。等摄像头安装后再排查。

---

## 四、检查用户访问权限

MPP、RGA、V4L2节点属于 `video` 用户组，因此执行：

```bash
id
```

结果：

```text
groups=...,27(sudo),29(audio),44(video)
```

当前 `kickpi` 用户已经属于 `video` 组，可以访问：

- `/dev/mpp_service`
- `/dev/rga`
- `/dev/video*`
- `/dev/media*`

虽然用户没有加入 `render` 组，但检查ACL：

```bash
getfacl -p /dev/dri/renderD128 /dev/dri/renderD129
```

结果中存在：

```text
user:kickpi:rw-
```

说明当前桌面登录会话已经为 `kickpi` 用户授予读写权限，暂时不需要修改用户组。

需要注意：以后如果改成纯后台、无桌面登录的RTSP服务，动态ACL可能不同，届时需要重新检查服务账户权限。

---

## 五、检查用户态工具

执行：

```bash
command -v ffmpeg gst-launch-1.0 v4l2-ctl mpi_dec_test mpi_enc_test mpp_info_test
```

所有工具均已安装：

```text
/usr/bin/ffmpeg
/usr/bin/gst-launch-1.0
/usr/bin/v4l2-ctl
/usr/bin/mpi_dec_test
/usr/bin/mpi_enc_test
/usr/bin/mpp_info_test
```

这说明镜像已经预装：

- FFmpeg
- GStreamer
- V4L2工具
- Rockchip MPP测试程序

---

## 六、检查 MPP 用户态库

执行：

```bash
mpp_info_test
```

关键结果：

```text
mpp version: 520ab553
author: Herman Chen
2025-12-16
```

程序可以正常启动，没有动态库缺失或权限错误，证明MPP用户态库能够正常加载。

进一步检查动态库：

```bash
ldconfig -p | grep -Ei 'rockchip_mpp|librga|libmali'
```

发现：

```text
librockchip_mpp.so
librga.so
libmali.so
libmali-hook.so
libMaliOpenCL.so
```

说明以下用户态组件均已安装：

- Rockchip MPP编解码库
- RGA图像处理库
- Mali GPU用户态库
- Mali OpenCL库

这些库均为 AArch64 版本，与RK3566系统架构一致。

---

## 七、检查 GStreamer 硬件插件

查看版本：

```bash
gst-launch-1.0 --version
```

结果：

```text
GStreamer 1.24.2
```

搜索 Rockchip 插件：

```bash
gst-inspect-1.0 | grep -Ei 'mpp|rockchip|rga'
```

发现：

```text
mpph264enc
mpph265enc
mppjpegenc
mppjpegdec
mppvideodec
mppvpxalphadecodebin
```

主要插件含义：

| 插件 | 用途 |
|---|---|
| `mpph264enc` | H.264硬件编码 |
| `mpph265enc` | H.265硬件编码 |
| `mppvideodec` | H.264/H.265等视频硬件解码 |
| `mppjpegenc` | JPEG硬件编码 |
| `mppjpegdec` | JPEG硬件解码 |

至此可以确认，GStreamer已经具备直接调用Rockchip MPP的能力。

---

## 八、实际测试 H.264 硬件编码

执行：

```bash
gst-launch-1.0 -v \
videotestsrc num-buffers=150 is-live=true ! \
video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! \
mpph264enc ! h264parse ! fakesink
```

流程：

```text
测试画面 → H.264硬件编码 → H.264解析 → 丢弃输出
```

结果：

```text
profile=High
level=4
framerate=30/1
Got EOS
Execution ended after 4.995 seconds
```

150帧在约5秒内完成，符合30fps实时运行，H.264硬件编码正常。

测试中出现：

```text
unable to create enc vp8 for soc rk3566 unsupported
```

这是插件探测VP8编码能力时产生的提示，不影响H.264编码。

---

## 九、实际测试 H.265 硬件编码

执行：

```bash
gst-launch-1.0 -v \
videotestsrc num-buffers=150 is-live=true ! \
video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! \
mpph265enc ! h265parse ! fakesink
```

结果：

```text
video/x-h265
profile=main
level=4
bit-depth-luma=8
Got EOS
Execution ended after 4.994 seconds
```

说明720P、30fps、H.265 Main Profile硬件编码正常。

---

## 十、实际测试 H.264 硬件解码

为了同时验证编码器和解码器，使用如下管线：

```bash
gst-launch-1.0 -v \
videotestsrc num-buffers=150 is-live=true ! \
video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! \
mpph264enc ! h264parse ! mppvideodec ! fakesink
```

流程：

```text
测试画面
  → H.264硬件编码
  → H.264码流解析
  → MPP硬件解码
  → NV12原始图像
```

关键结果：

```text
mppvideodec sink: video/x-h264
mppvideodec src: video/x-raw, format=NV12
Got EOS
Execution ended after 5.002 seconds
```

H.264硬件解码正常。

---

## 十一、实际测试 H.265 硬件解码

执行：

```bash
gst-launch-1.0 -v \
videotestsrc num-buffers=150 is-live=true ! \
video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! \
mpph265enc ! h265parse ! mppvideodec ! fakesink
```

关键结果：

```text
mppvideodec sink: video/x-h265
mppvideodec src: video/x-raw, format=NV12
Got EOS
Execution ended after 4.996 seconds
```

H.265硬件解码正常。

---

## 十二、编码测试后检查内核错误

执行：

```bash
sudo dmesg | \
grep -Ei 'mpp|rkvenc|vepu|iommu.*fault|page fault|bus error|timeout' | \
tail -n 80
```

没有发现测试期间产生的：

- IOMMU fault
- Page fault
- Bus error
- 编解码超时
- 编码器或解码器复位
- 内核崩溃

输出内容均为开机初期的驱动初始化记录。

---

## 十三、检查 FFmpeg 硬件能力

执行：

```bash
ffmpeg -hide_banner -hwaccels
```

FFmpeg列出了：

```text
vdpau
cuda
vaapi
drm
opencl
vulkan
```

这只能说明FFmpeg编译进了这些通用接口，不代表它们全部能在RK3566上工作。例如RK3566没有NVIDIA GPU，因此这里的 `cuda` 不能实际使用。

检查编解码器：

```bash
ffmpeg -hide_banner -encoders | grep -Ei 'rkmpp|mpp|v4l2m2m'
ffmpeg -hide_banner -decoders | grep -Ei 'rkmpp|mpp|v4l2m2m'
```

只发现：

```text
h264_v4l2m2m
hevc_v4l2m2m
vp8_v4l2m2m
...
```

没有发现：

```text
h264_rkmpp
hevc_rkmpp
```

说明当前FFmpeg没有直接编译Rockchip MPP适配，只带有通用V4L2 M2M包装器。

---

## 十四、确认 V4L2 节点用途

执行：

```bash
v4l2-ctl --list-devices
```

结果：

```text
rkisp-statistics:
    /dev/video8
    /dev/video9

rkisp_mainpath:
    /dev/video0
    ...
    /dev/video7
    /dev/media0
```

这说明所有 `/dev/video*` 都属于 RKISP 摄像头流水线，不是标准V4L2 M2M硬件编解码节点。

因此：

- FFmpeg虽然列出了 `h264_v4l2m2m`，但当前没有匹配的编解码设备节点。
- FFmpeg列表中的V4L2 M2M包装器不适合作为当前主要硬件编解码方案。
- 已实测成功的 `GStreamer + Rockchip MPP` 应作为后续RTSP推流的主要技术路线。

---

## 十五、最终检查结论

| 检查项目 | 结果 |
|---|---|
| MPP内核服务 | 正常 |
| H.264硬件编码 | 正常 |
| H.265硬件编码 | 正常 |
| H.264硬件解码 | 正常 |
| H.265硬件解码 | 正常 |
| 720P 30fps实时处理 | 正常 |
| RGA内核驱动 | 已加载 |
| RGA用户态库 | 已安装 |
| Mali GPU驱动 | 已加载 |
| Mali用户态/OpenCL库 | 已安装 |
| RKISP/Media Controller | 已注册 |
| GStreamer Rockchip MPP插件 | 正常 |
| FFmpeg直接调用RKMPP | 当前不支持 |
| FFmpeg V4L2 M2M实际设备 | 未发现 |
| 编解码运行时内核错误 | 未发现 |

当前已经证明 RK3566 的 H.264/H.265 硬件编解码链路能够正常工作，所以不需要为了编解码功能修改设备树。

尚未完成的项目包括：

- 1080P、4K和多路并发性能测试。
- 长时间稳定性和温度测试。
- RGA实际图像转换测试。
- GPU/OpenCL实际运算测试。
- MIPI摄像头和RKISP测试。
- RTSP服务端和客户端测试。

后续设备树工作主要面向具体的MIPI摄像头，包括传感器型号、I²C地址、供电、复位GPIO、MCLK、CSI D-PHY、Lane数量以及ISP端点连接。
