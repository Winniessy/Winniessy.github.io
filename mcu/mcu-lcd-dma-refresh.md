# MCU 屏幕 DMA 刷新：双缓冲、Cache、脏区域与 DMA 原理

MCU 屏幕 DMA 刷新可以拆成四个相互关联的问题：

1. CPU 在哪里绘制；
2. DMA 从哪里读取；
3. 哪些区域需要传输；
4. CPU Cache 中的数据是否已经真正写入内存。

理解这四点，就能把双缓冲、Cache 一致性、脏区域和 DMA 的工作机制串联起来。

## 1. 使用双缓冲

双缓冲至少有两种不同用法，实际开发中很容易混淆。

### 1.1 完整帧双缓冲

假设屏幕分辨率为 `800 × 480`，像素格式为 RGB565，每个像素占 2 字节。一张完整帧缓冲区需要：

```text
800 × 480 × 2 = 768000 字节
```

双缓冲则需要约 1.46 MiB：

```c
uint16_t framebuffer[2][800 * 480];
```

工作过程如下：

```text
CPU 绘制 Buffer A
        ↓
DMA/显示控制器读取 A，同时 CPU 绘制 B
        ↓
一帧结束后交换 A、B
```

示意代码：

```c
static uint16_t framebuffer[2][LCD_WIDTH * LCD_HEIGHT];

static uint8_t front_index = 0;  // 当前正在显示或发送
static uint8_t back_index  = 1;  // CPU 正在绘制

void LCD_RenderFrame(void)
{
    uint16_t *draw_buffer = framebuffer[back_index];

    GUI_Draw(draw_buffer);

    /* 如果 MCU 有数据 Cache，这里需要清理 Cache */
    SCB_CleanDCache_by_Addr(
        (uint32_t *)draw_buffer,
        LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t)
    );

    LCD_WaitForPreviousFrame();

    uint8_t temp = front_index;
    front_index = back_index;
    back_index = temp;

    LCD_StartFrameDMA(framebuffer[front_index]);
}
```

完整帧双缓冲的优点是画面完整，不容易撕裂。缺点是内存消耗很大，因此更适合带 SDRAM、PSRAM 或较大 SRAM 的 MCU，例如 STM32H7。

### 1.2 分块双缓冲

如果 MCU 内存不足以保存两帧，可以准备两个较小的块缓冲区：

```c
#define BLOCK_PIXELS 1024

uint16_t block_buffer[2][BLOCK_PIXELS];
```

CPU 填充缓冲区 A 时，缓冲区 B 可以为空。DMA 开始发送 A 后，CPU 立即填充 B；DMA 发送完 A，再继续发送 B：

```text
时间 →
CPU：填充 A | 填充 B | 填充 A | 填充 B
DMA：        发送 A | 发送 B | 发送 A
```

伪代码：

```c
void LCD_RefreshByBlocks(void)
{
    int current = 0;

    PreparePixels(block_buffer[current]);

    while (HasMorePixels()) {
        CleanCache(block_buffer[current], sizeof(block_buffer[current]));

        LCD_StartDMA(
            block_buffer[current],
            sizeof(block_buffer[current])
        );

        current ^= 1;

        /* DMA 发送上一块期间，CPU 生成下一块 */
        PreparePixels(block_buffer[current]);

        LCD_WaitDMAComplete();
    }
}
```

实际代码还需要处理最后一块不足 1024 个像素的情况。

分块双缓冲节省内存，但更适合“边生成、边通过 SPI 发送”的场景。它不能像完整帧双缓冲那样天然保存整个画面。

还必须保证：**DMA 正在读取某个缓冲区时，CPU 不能修改它。** 否则前半部分可能是旧图像，后半部分变成新图像，最终出现花屏。

---

## 2. 为什么 DMA 前需要清理 Cache

这个问题通常出现在 Cortex-M7、部分 Cortex-M33/M55，或带外部内存和数据 Cache 的系统中。很多 Cortex-M0/M3/M4 没有数据 Cache，因此不需要处理这个问题。

假设 CPU 修改了一块帧缓冲区：

```c
framebuffer[0] = 0xF800;  // 红色
```

如果启用了写回式数据 Cache，这次写操作可能只修改了 CPU Cache 中的副本，还没有立即写回 SRAM 或 SDRAM：

```text
CPU 看到的数据：红色
Cache 中的数据：红色
内存中的数据：旧颜色
```

DMA 不经过 CPU Cache，而是直接读取实际内存。因此，DMA 可能把旧颜色发送到屏幕。

```text
CPU → 修改 Cache
DMA → 直接读取内存中的旧数据
```

所谓清理 Cache，也叫 Clean Cache，就是把 Cache 中已经修改的脏数据写回实际内存：

```text
Clean D-Cache
Cache 中的新数据 → SRAM/SDRAM
DMA 再从 SRAM/SDRAM 读取新数据
```

在 STM32 CMSIS 中通常使用：

```c
SCB_CleanDCache_by_Addr((uint32_t *)buffer, size);
```

但是，Cache 操作通常要求地址和长度按照 Cache Line 对齐。Cortex-M7 常见的 Cache Line 大小是 32 字节，因此更安全的封装如下：

```c
#include <stdint.h>

#define CACHE_LINE_SIZE 32U

static void DCache_CleanRange(void *address, uint32_t size)
{
    uintptr_t start = (uintptr_t)address;
    uintptr_t aligned_start = start & ~(CACHE_LINE_SIZE - 1U);
    uintptr_t end = start + size;
    uintptr_t aligned_end =
        (end + CACHE_LINE_SIZE - 1U) & ~(CACHE_LINE_SIZE - 1U);

    SCB_CleanDCache_by_Addr(
        (uint32_t *)aligned_start,
        aligned_end - aligned_start
    );
}
```

发送屏幕数据前这样使用：

```c
DCache_CleanRange(pixel_buffer, pixel_count * sizeof(uint16_t));

HAL_SPI_Transmit_DMA(
    &hspi1,
    (uint8_t *)pixel_buffer,
    pixel_count * sizeof(uint16_t)
);
```

### 2.1 不同 DMA 方向对应的 Cache 操作

| DMA 方向 | Cache 操作 | 原因 |
| --- | --- | --- |
| 内存 → 外设，例如 LCD TX | DMA 前 Clean | 把 CPU 修改的数据写回内存 |
| 外设 → 内存，例如摄像头 RX | DMA 前后通常需要 Invalidate | 丢弃 CPU Cache 中的旧副本 |
| 内存 → 内存 | 根据源、目标分别处理 | 源可能要 Clean，目标可能要 Invalidate |

`Clean` 的含义是“把修改写回内存”，`Invalidate` 的含义是“让 Cache 中的副本失效，下次由 CPU 重新读取内存”。二者不能随便交换。

另一种做法是通过 MPU 把 DMA 缓冲区所在区域设置成不可缓存区。这样不需要每次手工维护 Cache，但 CPU 访问这块内存的速度可能降低。

常见设计如下：

```text
普通变量和代码：Cacheable
DMA 描述符、通信缓冲区：Non-cacheable
大型帧缓冲区：根据性能需求决定
```

还需要注意：SPI DMA 发送完成，只能说明 DMA 已经把最后一份数据交给 SPI 外设；某些芯片上，SPI 可能仍在移位发送最后几个比特。因此拉高片选前，还可能需要等待 SPI 的 Busy 标志清零。

---

## 3. 如何计算脏区域

脏区域就是“这一帧中发生变化、必须重新发送到屏幕的区域”。如果只移动了一个小按钮，就没有必要刷新整个屏幕。

最简单的表示方法是矩形：

```c
typedef struct {
    int16_t x1;
    int16_t y1;
    int16_t x2;
    int16_t y2;
    bool valid;
} DirtyRect;
```

假设屏幕上的一个按钮从：

```text
旧位置：(20, 40)，大小 60 × 30
新位置：(30, 40)，大小 60 × 30
```

旧区域是：

```text
x = 20 ～ 79
y = 40 ～ 69
```

新区域是：

```text
x = 30 ～ 89
y = 40 ～ 69
```

为了清除旧按钮并绘制新按钮，脏区域至少应包含旧、新两个矩形的并集：

```text
x = 20 ～ 89
y = 40 ～ 69
```

矩形合并函数可以写成：

```c
void DirtyRect_Add(
    DirtyRect *dirty,
    int16_t x,
    int16_t y,
    int16_t width,
    int16_t height)
{
    int16_t x1 = x;
    int16_t y1 = y;
    int16_t x2 = x + width - 1;
    int16_t y2 = y + height - 1;

    /* 裁剪到屏幕范围 */
    if (x1 < 0) {
        x1 = 0;
    }
    if (y1 < 0) {
        y1 = 0;
    }
    if (x2 >= LCD_WIDTH) {
        x2 = LCD_WIDTH - 1;
    }
    if (y2 >= LCD_HEIGHT) {
        y2 = LCD_HEIGHT - 1;
    }

    if (x1 > x2 || y1 > y2) {
        return;
    }

    if (!dirty->valid) {
        dirty->x1 = x1;
        dirty->y1 = y1;
        dirty->x2 = x2;
        dirty->y2 = y2;
        dirty->valid = true;
        return;
    }

    if (x1 < dirty->x1) {
        dirty->x1 = x1;
    }
    if (y1 < dirty->y1) {
        dirty->y1 = y1;
    }
    if (x2 > dirty->x2) {
        dirty->x2 = x2;
    }
    if (y2 > dirty->y2) {
        dirty->y2 = y2;
    }
}
```

刷新时，先给 LCD 设置窗口，再发送对应像素：

```c
void LCD_FlushDirtyRect(DirtyRect *dirty)
{
    if (!dirty->valid) {
        return;
    }

    int width  = dirty->x2 - dirty->x1 + 1;
    int height = dirty->y2 - dirty->y1 + 1;

    LCD_SetWindow(
        dirty->x1,
        dirty->y1,
        dirty->x2,
        dirty->y2
    );

    /*
     * 如果帧缓冲区是按整行存储的，
     * 这个矩形的数据未必在内存中连续。
     */
    for (int y = dirty->y1; y <= dirty->y2; y++) {
        uint16_t *line =
            &framebuffer[y * LCD_WIDTH + dirty->x1];

        DCache_CleanRange(line, width * sizeof(uint16_t));
        LCD_SendLineDMA(line, width);
        LCD_WaitDMAComplete();
    }

    dirty->valid = false;
}
```

这里有一个关键细节：屏幕中的矩形在二维坐标上连续，在帧缓冲区中却不一定是一整块连续内存。

例如，屏幕宽度是 320，脏矩形宽度只有 50。一行发送完 50 个像素后，内存中还有这一行剩余的 270 个像素，然后才是下一行的脏数据。

```text
原始帧缓冲区每行跨度：320 像素
脏区域每行有效数据： 50 像素
```

因此，可以逐行 DMA，也可以先把矩形复制到连续的临时缓冲区，再一次性 DMA。

实际 GUI 系统通常会保存多个脏矩形，因为把相距很远的两个小区域强行合并，可能使合并后的区域接近整屏。

简单项目可以只维护一个并集矩形；稍复杂的项目可以维护一个脏矩形数组：

```c
DirtyRect dirty_list[8];
```

当矩形数量超过上限，或者脏区域总面积已经很大时，可以直接退化为全屏刷新。

```c
dirty_area = 所有脏矩形面积之和;
screen_area = LCD_WIDTH * LCD_HEIGHT;

if (dirty_area > screen_area * 60 / 100) {
    LCD_FlushFullScreen();
} else {
    LCD_FlushDirtyRects();
}
```

脏区域通常由 GUI 控件主动上报，不需要每一帧逐像素比较两张图。

例如：

- 按钮颜色发生变化时，把按钮所在矩形标脏；
- 文字改变时，把旧文字区域和新文字区域都标脏；
- 物体移动时，把旧位置和新位置都标脏。

---

## 4. DMA 的原理

DMA 是一个独立于 CPU 的硬件搬运单元。它可以在外设和内存之间传输数据，不需要 CPU 为每个字节执行加载和存储指令。

以 SPI 发送屏幕数据为例，CPU 首先配置 DMA：

```text
源地址：pixel_buffer
目标地址：SPI 数据寄存器
传输数量：2000 字节
数据宽度：8 位或 16 位
源地址：每次递增
目标地址：保持不变
触发源：SPI TX 请求
```

对应关系类似：

```c
DMA.SourceAddress      = pixel_buffer;
DMA.DestinationAddress = &SPIx->TXDR;
DMA.TransferCount      = 2000;
DMA.SourceIncrement    = ENABLE;
DMA.DestIncrement      = DISABLE;
```

目标地址不递增，因为所有数据都要写入同一个 SPI 发送寄存器；源地址递增，因为 DMA 要依次读取缓冲区中的像素。

SPI 发送过程可以理解为：

```text
1. SPI 发送寄存器出现空位
2. SPI 向 DMA 发出 TX 请求
3. DMA 从内存读取一个数据单元
4. DMA 将数据写入 SPI TX 寄存器
5. 传输计数减一，源地址递增
6. 重复上述过程，直到计数变为零
7. DMA 触发完成中断
```

DMA 并不是一次性把所有数据塞进 SPI。它通常由外设的硬件请求节拍驱动：SPI 有空间时才请求下一份数据，所以 DMA 的传输速度最终仍受 SPI 限制。

DMA 还需要和 CPU 竞争内存总线。简化后的硬件关系可以理解为：

```text
                    ┌────────── SPI ───────→ LCD
                    │
CPU ── Cache ── 总线/内存
                    │
DMA ────────────────┘
```

CPU 和 DMA 都可能访问 SRAM、SDRAM 或总线上的外设。总线矩阵或仲裁器决定谁先访问。

DMA 可以减少 CPU 指令开销，但不会让内存访问完全没有成本。如果 DMA 长时间高速搬运大量数据，也可能占用总线带宽，使 CPU 或其他外设访问内存变慢。

完整的屏幕刷新流程通常如下：

```text
CPU 绘制图形
    ↓
记录并合并脏区域
    ↓
清理脏区域对应的 D-Cache
    ↓
设置 LCD 显存窗口
    ↓
启动 DMA
    ↓
CPU 执行其他任务
    ↓
DMA 完成中断
    ↓
发送下一块或结束本次刷新
```

## 总结

这四个问题之间的关系可以概括为：

- **双缓冲**解决 CPU 绘制和 DMA 发送之间的并行与数据所有权问题；
- **Cache 清理**保证 DMA 能读到 CPU 最新写入的数据；
- **脏区域**减少需要传输的像素数量；
- **DMA**负责按照外设请求，把数据从内存搬运到屏幕接口。

在实际设计中，性能瓶颈往往不是单一因素，而是内存容量、总线带宽、SPI/LTDC 接口速度、Cache 策略和刷新区域共同决定的。只有把这些环节一起考虑，才能设计出稳定、低占用且不易撕裂的 MCU 图形刷新方案。