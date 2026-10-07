# Linux DMA 与 DMA-BUF：从 Camera 到 VPU 的共享 buffer

Camera、VPU、GPU 和显示设备之间传递图像时，最容易混淆的是 DMA 地址、物理地址、IOMMU 和 DMA-BUF。它们分别解决不同问题：DMA 负责让设备访问内存，IOMMU 负责地址转换和隔离，DMA-BUF 负责让多个驱动共享同一个 buffer。

## 1. DMA 先解决“谁来搬数据”

如果完全由 CPU 搬运一帧图像，路径大致是：

~~~text
外设
  ↓
CPU 读取
  ↓
CPU 寄存器
  ↓
CPU 写入 DDR
~~~

数据量一大，CPU 就会被大量复制操作占住。DMA 的思路是让外设或 DMA Controller 直接访问内存：

~~~text
Camera Sensor
      ↓
MIPI CSI-2
      ↓
RKCIF / ISP
      ↓ DMA
DDR Buffer
~~~

CPU 主要负责配置地址、长度和传输方向，启动 DMA，并在完成中断到来后处理结果。真正的数据搬运由设备这个 bus master 完成。

不过 DMA 并不是完全绕开 CPU 或总线。CPU、GPU、VPU、ISP 和 DMA 都可能同时访问 DDR，最终仍然要经过 AXI/NoC、总线仲裁、QoS 和 DDR Controller。DMA 只是减少了 CPU 亲自执行复制指令的工作。

## 2. CPU 地址、物理地址和 DMA 地址

Linux DMA 中最重要的区别，是下面三种地址不能混为一谈：

~~~text
CPU 虚拟地址
      ↓ CPU MMU
物理地址
      ↓
DDR

设备 DMA 地址
      ↓ IOMMU（如果启用）
物理地址
~~~

CPU 侧通常使用指针或虚拟地址：

~~~c
void *cpu_addr;
~~~

设备侧使用 dma_addr_t：

~~~c
dma_addr_t dma_addr;
~~~

在没有 IOMMU 的简单平台上，DMA 地址可能恰好和物理地址相同。但驱动不能因此直接把 phys_addr_t 当成设备地址使用。Linux 应该通过 DMA API 获取设备真正能够访问的地址：

~~~c
dma_addr_t dma_addr;

dma_addr = dma_map_single(dev,
                          cpu_addr,
                          size,
                          DMA_FROM_DEVICE);
~~~

之后写入设备寄存器的，应当是这个 dma_addr，而不是驱动自己计算出来的物理地址。

有 IOMMU 时，设备看到的通常是 IOVA：

~~~text
VPU 看到 IOVA 0x80000000
             ↓ IOMMU
       物理地址 0x12340000
~~~

同一块 DDR 对 CPU、VPU 和 GPU 可能分别有不同的地址：

~~~text
同一块 DDR
  PA   = 0x12340000
  CPU  = 某个内核或用户虚拟地址
  VPU  = 0x80000000
  GPU  = 0x40000000
~~~

所以更准确的说法不是“这块 buffer 的 DMA 地址是多少”，而是“这块 buffer 对哪个 device 的 DMA 地址是多少”。

## 3. DMA API 和缓存一致性

Linux 中常见的 DMA 内存使用方式可以粗略分成两类。

对于长期存在的描述符、ring buffer 或控制结构，可以使用 coherent DMA：

~~~c
void *cpu_addr;
dma_addr_t dma_addr;

cpu_addr = dma_alloc_coherent(dev,
                              size,
                              &dma_addr,
                              GFP_KERNEL);
~~~

这里同时得到 CPU 访问地址和设备访问地址。

对于阶段性或一次性的 DMA，可以使用 streaming DMA：

~~~text
CPU 准备 buffer
      ↓
dma_map_single()
      ↓
设备 DMA
      ↓
dma_unmap_single()
~~~

不同平台的 CPU Cache 和设备访问关系不一样。CPU 可能还在 Cache 中看到旧数据，而 DMA 已经把新数据写到了 DDR；也可能 CPU 修改还没有回写到内存，设备就开始读取。因此需要按照 DMA 方向和平台规则处理同步：

~~~text
DMA_FROM_DEVICE
设备写 DDR → CPU 读取

DMA_TO_DEVICE
CPU 准备数据 → 设备读取
~~~

Linux DMA API 会负责必要的映射和缓存维护，必要时还会使用 dma_sync_single_for_cpu()、dma_sync_single_for_device() 等接口。不能只看到地址映射成功，就认为 CPU 和设备一定已经看到同一份最新数据。

## 4. DMA-BUF 解决“多个设备怎么共享”

DMA-BUF 不是一种新的内存，也不是分配器。它是 Linux 中用于跨驱动、跨设备共享 DMA buffer 的统一抽象。

传统的数据流可能是：

~~~text
Camera DMA
    ↓
Camera Buffer
    ↓ CPU memcpy
Encoder Buffer
    ↓
VPU
~~~

使用 DMA-BUF 后，可以变成：

~~~text
Camera
  ↓ DMA
DDR Buffer
  ↑       ↑
Camera   VPU
~~~

Camera、VPU、GPU 或 Display 可以围绕同一个 backing memory 工作，避免中间再复制一份数据。

DMA-BUF 在内核中由 struct dma_buf 表示，用户空间通常通过一个文件描述符传递它：

~~~text
dma_buf
   ↓
struct file
   ↓
fdtable
   ↓
dma-buf fd
~~~

所以 DMA-BUF fd 本质上仍然是普通 Linux 文件描述符，只是它对应的 struct file 最终关联到一个 struct dma_buf。如果要在进程之间传递这个 fd，可以使用 Unix Domain Socket 的 SCM_RIGHTS，不能只把一个整数直接发给另一个进程。

DMA-BUF 有两个角色：

- **Exporter**：负责创建和管理 buffer，并导出 DMA-BUF；
- **Importer**：拿到别人导出的 buffer，在自己的设备上使用。

Importer 使用一个 DMA-BUF 时，常见流程是：

~~~text
dma_buf_get(fd)
      ↓
dma_buf_attach(dmabuf, dev)
      ↓
dma_buf_map_attachment()
      ↓
struct sg_table
      ↓
设备 DMA
~~~

attach 表示这个 device 要使用这块 buffer，建立的是设备和 DMA-BUF 之间的关系；map_attachment 才是真正为这个 device 建立 DMA 映射，并返回适合设备访问的 scatter-gather 信息。

同一块 buffer 对不同设备可能需要不同的映射，所以 attach 时必须指定具体的 struct device *。

## 5. mmap、vmap 和设备映射不是一回事

DMA-BUF 相关代码中经常同时出现 mmap、vmap 和 map_dma_buf，它们服务的对象不同：

~~~text
mmap
  → 给用户态 CPU 建立虚拟地址映射

vmap
  → 给内核态 CPU 建立虚拟地址映射

map_dma_buf
  → 给某个 DMA 设备建立设备地址映射
~~~

用户调用 mmap 得到的是用户虚拟地址；内核通过 dma_buf_vmap 得到的是内核虚拟地址；设备最终使用的则是通过 dma_buf_map_attachment 建立的 DMA 地址或 IOVA。

这三种映射可能指向同一块底层 buffer，但用途和地址空间不同，不能互相替代。

另外，共享 buffer 还要解决访问顺序：Camera 正在写入时，VPU 不能直接读取未完成的帧。DMA-BUF 会结合 reservation object 和 dma-fence 等机制，协调 producer 和 consumer：

~~~text
Camera 写 buffer
      ↓
写入完成，fence signal
      ↓
VPU 开始读取
~~~

DMA-BUF 解决的是“共享哪块 buffer”，fence 解决的是“什么时候可以访问”。

## 6. Camera 到 VPU 的完整链路

以 V4L2/videobuf2 管理 Camera buffer 为例，典型路径可以简化成：

~~~text
Camera Sensor
      ↓
MIPI CSI-2
      ↓
RKCIF / ISP
      ↓ DMA
DDR Capture Buffer
      ↓
V4L2 / vb2
      ↓ VIDIOC_EXPBUF
DMA-BUF fd
      ↓
GStreamer / MPP
      ↓
VPU driver
      ↓ dma_buf_get()
dma_buf_attach()
      ↓
dma_buf_map_attachment()
      ↓
sg_table / DMA API
      ↓
IOMMU（如果平台启用）
      ↓
VPU IOVA
      ↓
VPU 直接读取 Camera Buffer
~~~

V4L2 的 io-mode=dmabuf 通常表示 V4L2/vb2 负责分配 capture buffer，再通过 VIDIOC_EXPBUF 导出 DMA-BUF fd，让下游模块继续使用。

dmabuf-import 则是反过来：buffer 由外部模块先分配，V4L2 通过 V4L2_MEMORY_DMABUF 导入：

~~~text
dmabuf
  V4L2 分配 → Export → 下游使用

dmabuf-import
  外部分配 → fd → V4L2 Import
~~~

所谓零拷贝，重点是避免 Camera buffer 到 Encoder buffer 之间额外的 CPU memcpy。Camera 写入 DDR 和 VPU 读取 DDR 仍然是 DMA，这并不矛盾。

## 7. DMA-BUF、DMA-Heap 和 CMA

这几个概念也需要分开：

~~~text
DMA-Heap
  解决：谁来分配 buffer

DMA-BUF
  解决：多个设备怎么共享 buffer

CMA
  解决：如何获得较大的物理连续内存
~~~

如果设备没有 IOMMU，可能要求 buffer 物理连续，这时 CMA 比较常见。启用 IOMMU 后，即使底层物理页不连续，也可以通过 IOMMU 映射成设备看到的连续 IOVA，从而降低设备对物理连续内存的依赖。

但 SoC 有 IOMMU，并不代表每个外设都一定经过 IOMMU。最终要结合具体硬件 IP、设备树、驱动和内核配置判断。可以通过设备树中的 iommus 属性、内核日志以及 /sys/kernel/iommu_groups/ 等信息辅助确认。

## 8. 总结

这几个概念可以用一句话分别记住：

- **DMA**：让设备直接访问内存，减少 CPU 搬运。
- **DMA 地址**：设备使用的地址，应该通过 DMA API 获取，不能默认等于物理地址。
- **IOMMU**：把设备看到的 IOVA 映射到物理地址，同时提供隔离和重映射能力。
- **DMA-BUF**：让不同驱动和设备共享同一个 DMA buffer。
- **DMA-Heap**：一种 buffer 分配方式。
- **CMA**：为需要物理连续内存的场景提供支持。
- **Fence**：协调多个设备对共享 buffer 的访问顺序。

Camera 到 VPU 的核心链路就是：

~~~text
Camera 通过 DMA 写入 V4L2/vb2 buffer
        ↓
V4L2 导出 DMA-BUF fd
        ↓
VPU importer attach + map
        ↓
VPU 通过自己的 DMA 地址读取同一块 buffer
        ↓
避免中间 CPU memcpy
~~~

理解这条链路后，再去看 dma_buf_attach、dma_buf_map_attachment、V4L2 VIDIOC_EXPBUF 和 IOMMU 映射，基本就能知道每一步在解决什么问题了。
