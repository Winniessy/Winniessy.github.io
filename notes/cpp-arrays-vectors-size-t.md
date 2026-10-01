# C++ 基础：数组、`std::array`、`std::vector` 与 `size_t`

数组是 C++ 里最基础、也最容易在细节上出错的一类数据结构。C 风格数组、`std::array` 和 `std::vector` 都能连续存储元素，也都支持下标访问，但它们在长度、内存管理和接口上有明显区别。

## 1. 三种数组的基本区别

~~~cpp
int a[3] = {1, 2, 3};
std::array<int, 3> b = {1, 2, 3};
std::vector<int> c = {1, 2, 3};
~~~

| 特性 | C 风格数组 | `std::array` | `std::vector` |
| --- | --- | --- | --- |
| 长度 | 固定 | 固定 | 动态 |
| 元素是否连续 | 是 | 是 | 是 |
| `.size()` | 不支持 | 支持 | 支持 |
| `.push_back()` | 不支持 | 不支持 | 支持 |
| 整体赋值 | 不支持 | 支持 | 支持 |
| 动态内存管理 | 不负责 | 不需要额外分配 | 自动管理 |
| 随机访问 | O(1) | O(1) | O(1) |

三者都可以通过下标访问元素：

~~~cpp
std::cout << a[0] << '\n';
std::cout << b[0] << '\n';
std::cout << c[0] << '\n';
~~~

## 2. C 风格数组

### 2.1 定义和长度

数组长度可以由初始化列表推导：

~~~cpp
int a[] = {1, 2, 3};
~~~

它等价于：

~~~cpp
int a[3] = {1, 2, 3};
~~~

但下面的定义无法确定数组大小：

~~~cpp
int a[];  // 错误
~~~

`extern int a[];` 是另一种情况，它只是声明一个不完整数组类型，并没有在当前语句中定义数组对象。

### 2.2 用 sizeof 计算元素个数

~~~cpp
int a[] = {1, 2, 3, 4, 5};

std::size_t bytes = sizeof(a);
std::size_t count = sizeof(a) / sizeof(a[0]);
~~~

假设 `int` 占 4 字节，`sizeof(a)` 是 20，`sizeof(a[0])` 是 4，因此元素个数为 5。

这个方法只适用于数组对象本身，数组传入普通函数参数后会发生退化。

### 2.3 数组退化为指针

~~~cpp
void print_array(int a[])
{
    // 这里的 a 实际上等价于 int*
}
~~~

它等价于：

~~~cpp
void print_array(int *a)
{
}
~~~

所以在函数内部使用 `sizeof(a)` 得到的是指针大小，而不是原始数组的总大小。在常见的 64 位系统中，这个结果通常是 8 字节。

如果函数需要知道数组长度，应当把长度作为额外参数传入，或者使用 `std::array`、`std::span` 等能够表达范围的类型。

## 3. std::array

`std::array` 是 C++11 引入的固定长度容器，可以理解为带有标准容器接口的原生数组封装。

~~~cpp
#include <array>

std::array<int, 3> a = {1, 2, 3};
~~~

它的模板参数包括元素类型和元素数量：

~~~cpp
template<class T, std::size_t N>
struct array;
~~~

数组长度是类型的一部分：

~~~cpp
std::array<int, 3> a;
std::array<int, 4> b;
~~~

`a` 和 `b` 是两种不同的类型。下面这种写法缺少长度参数：

~~~cpp
std::array<int> a;  // 错误
~~~

C++17 支持类模板实参推导，因此可以写成：

~~~cpp
std::array a = {1, 2, 3};  // 推导为 std::array<int, 3>
~~~

### 3.1 常用接口

~~~cpp
std::array<int, 3> a = {10, 20, 30};

a.size();    // 3
a.front();   // 10
a.back();    // 30
a.at(1);     // 带边界检查，返回 20
a.data();    // 获取首元素指针
a.fill(0);   // 全部填充为 0
~~~

`operator[]` 不做边界检查：

~~~cpp
a[10];        // 越界访问，属于未定义行为
a.at(10);     // 越界时抛出 std::out_of_range
~~~

### 3.2 内存位置

`std::array` 的元素直接存储在对象内部，不会因为使用了 `std::array` 就自动分配一块堆内存。

~~~cpp
void func()
{
    std::array<int, 100> a;
}
~~~

这里的局部对象通常位于栈上，但不能简单说 `std::array` 一定在栈上。对象放在哪里取决于对象本身的存储方式：

~~~cpp
auto p = std::make_unique<std::array<int, 100>>();
~~~

此时 `std::array` 对象位于动态分配的内存中。

## 4. std::vector

`std::vector` 是动态数组容器，元素连续存储，可以在运行过程中增加或删除。

~~~cpp
#include <vector>

std::vector<int> nums = {1, 2, 3};
~~~

它的主要特点是：

- 支持动态扩容；
- 元素连续存储；
- 支持 O(1) 随机访问；
- 自动管理元素存储空间；
- 尾部插入的摊还复杂度为 O(1)。

### 4.1 size 和 capacity

- `size()`：当前实际存在的元素数量；
- `capacity()`：当前已经分配、可以容纳的元素数量。

~~~cpp
std::vector<int> v;
v.reserve(10);

std::cout << v.size() << '\n';      // 0
std::cout << v.capacity() << '\n';  // 至少为 10
~~~

`reserve(10)` 只预留存储空间，不会创建 10 个有效元素。因此下面的代码仍然是错误的：

~~~cpp
v[0] = 100;  // size 仍然是 0，属于未定义行为
~~~

### 4.2 reserve 和 resize

~~~cpp
std::vector<int> a;
a.reserve(10);  // 只增加容量，不改变 size

std::vector<int> b;
b.resize(10);   // 创建 10 个有效元素
~~~

对于 `std::vector<int>`，`resize(10)` 新增的元素会初始化为 0。

| 操作 | size 是否变化 | capacity 是否可能变化 |
| --- | --- | --- |
| `reserve(n)` | 不变 | 可能增加 |
| `resize(n)` | 变化 | 可能增加 |
| `push_back(x)` | 增加 1 | 可能增加 |
| `pop_back()` | 减少 1 | 通常不变 |
| `clear()` | 变为 0 | 通常不变 |

### 4.3 常见的内部结构

具体实现由标准库决定，但常见实现可以抽象成三个指针：

~~~text
begin    → 第一个元素
end      → 有效元素末尾
end_cap  → 已分配空间末尾
~~~

因此可以理解为：

~~~text
size     = end - begin
capacity = end_cap - begin
~~~

三指针只是常见实现，不是 C++ 标准强制规定的布局。`vector` 对象本身可以在栈、堆或静态存储区，而元素存储区通常由分配器动态分配。

### 4.4 动态扩容

~~~cpp
std::vector<int> v;
v.reserve(2);
v.push_back(10);
v.push_back(20);
v.push_back(30);  // 容量不足，可能触发重新分配
~~~

容量不足时，通常会经历以下过程：

1. 分配一块更大的连续存储空间；
2. 移动或复制旧元素；
3. 构造新增元素；
4. 销毁旧元素并释放旧空间；
5. 更新内部指针。

C++ 标准没有规定具体扩容倍数，实际实现可能采用 1.5 倍、2 倍或其他增长策略。

容量充足时，`push_back()` 通常是 O(1)；发生扩容时通常是 O(n)。综合多次插入的平均成本，`push_back()` 的复杂度是摊还 O(1)，不是每一次都严格 O(1)。

### 4.5 扩容导致地址失效

~~~cpp
std::vector<int> v;
v.reserve(2);
v.push_back(10);
v.push_back(20);

int *p = &v[0];
v.push_back(30);  // 可能触发重新分配
~~~

如果发生了重新分配，旧元素会搬到新地址，原来的指针、引用和迭代器都会失效：

~~~cpp
std::cout << *p;  // 可能是未定义行为
~~~

如果能够提前估计元素数量，可以使用 `v.reserve(1000)` 减少重新分配次数，但后续数量超过容量时，地址依然可能变化。

## 5. size_t

`size_t` 是用于表示对象大小、数组长度和内存范围的无符号整数类型。它不是一种独立的基本类型，而是由实现定义的无符号整数类型别名。

`sizeof` 的返回类型是 `size_t`：

~~~cpp
int value = 10;
auto bytes = sizeof(value);
~~~

容器的 `size()` 返回值通常也是对应的 `size_type`，在常见实现中与 `size_t` 兼容：

~~~cpp
std::vector<int> v = {1, 2, 3};
auto count = v.size();
~~~

### 5.1 无符号下溢

~~~cpp
std::size_t i = 0;
i--;
~~~

`i` 不会变成 -1，而是发生无符号回绕。在常见的 64 位平台上，结果会变成：

~~~text
18446744073709551615
~~~

下面的循环就是一个典型错误：

~~~cpp
for (std::size_t i = nums.size() - 1; i >= 0; i--)
{
    std::cout << nums[i] << '\n';
}
~~~

因为 `i` 是无符号类型，`i >= 0` 永远成立。倒序遍历可以写成：

~~~cpp
for (std::size_t i = nums.size(); i > 0; i--)
{
    std::cout << nums[i - 1] << '\n';
}
~~~

这个写法也能正确处理空数组。

### 5.2 size_t 和 ssize_t

Linux 开发中还经常会遇到 `ssize_t`：

| 类型 | 是否有符号 | 常见用途 |
| --- | --- | --- |
| `size_t` | 无符号 | 对象大小、缓冲区长度 |
| `ssize_t` | 有符号 | 读写结果，允许返回负数 |

例如：

~~~c
ssize_t read(int fd, void *buf, size_t count);
~~~

`count` 表示希望读取的字节数，返回值表示实际读取的字节数；返回 0 表示结束，返回 -1 表示出错。

### 5.3 算法题中用 int 还是 size_t

如果题目已经保证数组长度在 `int` 范围内，使用 `int` 写循环通常更方便：

~~~cpp
int n = static_cast<int>(nums.size());
for (int i = 0; i < n; ++i)
{
    std::cout << nums[i] << '\n';
}
~~~

实际工程中，如果容器可能很大，应优先保留 `size_t` 或容器自己的 `size_type`，避免把大数转换成 `int` 后丢失信息。

## 6. 初始化方式的区别

### 6.1 C 风格数组和 std::array

~~~cpp
int a[] = {1, 2, 3};       // 3 个元素
int b[5] = {1, 2, 3};      // 5 个元素，后两个为 0

std::array<int, 3> c = {1, 2, 3};
std::array<int, 5> d = {1, 2, 3}; // 后两个元素为 0
~~~

C++17 起，`std::array a = {1, 2, 3};` 可以通过类模板实参推导得到 `std::array<int, 3>`。

### 6.2 vector 的圆括号和花括号

下面两种写法含义不同：

~~~cpp
std::vector<int> a(5);  // 5 个元素，值初始化为 0
std::vector<int> b{5};  // 1 个元素，值为 5
~~~

再看两个元素的例子：

~~~cpp
std::vector<int> a(3, 5); // [5, 5, 5]
std::vector<int> b{3, 5}; // [3, 5]
~~~

可以先这样理解：圆括号通常用于指定元素数量和初始值，花括号通常表示实际的元素列表。

## 7. 嵌入式开发中的注意点

`std::vector` 的元素通常连续存储，但它可能在扩容时重新分配，导致原有地址变化。DMA 缓冲区除了地址稳定，往往还需要满足：

- 特定的物理内存或设备可访问地址；
- 对齐要求；
- Cache 一致性要求；
- 固定的生命周期；
- 特定的内存分配和释放方式。

因此，不能仅凭“`vector` 连续存储”就把它直接当作 DMA 缓冲区。需要 DMA 时，应根据平台使用专门的 DMA 分配接口，并在设备访问前后处理缓存同步。

如果元素数量固定、希望避免动态内存分配，可以优先考虑 `std::array`。如果需要动态增加元素，且运行环境允许使用堆内存，再考虑 `std::vector`。

## 8. 总结

- **C 风格数组**：固定长度、连续存储、语法简单，但缺少标准容器接口。
- **`std::array`**：固定长度、连续存储，长度属于类型的一部分，适合不需要扩容的数据。
- **`std::vector`**：动态长度、连续存储，通过容量管理和重新分配实现扩容。
- **`size_t`**：用于表示对象大小和长度的无符号类型，使用时要注意下溢和有符号/无符号混合运算。

一般算法题中，需要动态维护元素数量时可以使用 `std::vector`；元素数量固定时可以使用 C 风格数组或 `std::array`。在嵌入式项目中，还要结合内存占用、实时性、动态分配策略和外设访问约束来选择数据结构。
