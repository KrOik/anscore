# 常用 IP 与图像处理开发框架

本轮按用户要求优先常用 IP 和图像算法代码开发，暂缓旧库清点及密码学开发。
图像功能代码已补齐主要帧处理入口，并完成全目录编译和小帧分组参考检查。
细节、推荐入口与限制见 [image/README.md](image/README.md)。部分图像模块已完成
Tang Primer 25K 限定参数下的独立综合、50 MHz 时序检查和三次 SRAM/UART 板测；
整体尚未验收完毕，最新范围和失败记录见
[验证续记](evidence/20261017_validation_status.md)。这些结果不代表全部模块组合、
任意帧尺寸或实时视频吞吐已通过。
根目录 `run_tests.py` 已纳入独立 image 分组；`signal_video` 保留 legacy 命名的
统一命令入口，实际功能与限制以 manifest、ABI 和测试证据为准。
本轮完成记录与检查证据见 [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md)。
2026-10-18：原48项 `signal_video` 占位框架入口均已有功能实现，并通过统一仿真回归；
这是接口文档限定范围内的结果，不代表原300余核全库清点、任意参数、综合时序或全部板测通过。
模型超分辨率核需要外部训练和量化权重，尚无预训练图像质量验收。

| 目录 | 开发范围 |
|---|---|
| `stream_bus/` | 弹性流、变宽、帧仲裁、AXI-Lite 寄存器/实际路由、AXI4 burst/native 内存桥 |
| `memory/` | 同步 RAM/FIFO、真实流式 DMA 和描述符链内存复制 |
| `peripherals/` | GPIO/PWM/timer/IRQ，实际 UART/SPI/I²C/QSPI/SD-SPI 串行控制 |
| `common/` | CE/native 内存握手适配、字节地址同步 RAM、legacy 错误应答器 |
| `cdc/` | 电平同步、复位同步与单字邮箱 |
| `signal_video/` | 48项 DSP／图像功能命令和数据流入口，详细范围见 FUNCTIONAL_IMAGE_ABI.md 与 FUNCTIONAL_DSP_ABI.md |
| `image/isp/` | Bayer、Gamma、AWB 统计/增益、CCM、亮度/对比度、色彩转换 |
| `image/filters/` | 实际空域/时域滤波、完整 Canny、二值化与两遍形态学 |
| `image/geometry/` | 缩放、降采样、上采样、旋转/镜像、仿射/透视及帧存储访问 |
| `image/dehaze/` | 完整同步帧 DCP、自动大气光、导向细化与恢复 |
| `image/histogram/` | 完整帧 HE/CLAHE、严格限幅重分配及多 tile 插值 |
| `image/multiframe/` | 实际帧存储 OSD/帧差/EWMA/融合、SAD 自动配准与拼接 |
| `image/pipelines/` | RAW/Bayer 前端及自动 AWB 完整色彩处理连接 |
| `image/window/` | 双同步行存储 3×3 裁边窗口，供 Bayer/滤波/边缘前端使用 |
| `integration/` | 流/FIFO 连接、DMA→CE适配→物理时钟内存往返检查 |

`functional_minimal` 仅表示早期基础代码实现了有限功能；
`implementation_draft_unverified` 表示实际计算/控制代码已经写入、尚未验证；
`implementation_group_checked` 或同义 group-tested 状态表示有限组级检查通过；
`placeholder` 表示接口占位。占位必须明确返回错误或拉高 unsupported，
不会把直通、无输出或空结果作为成功算法。状态和缺失能力见各目录说明。

原生数据流通常使用共同 CE，传输条件为 `clk_en && valid && ready`，
不能直接作为任意无 CE 的 AXI Stream 设备。AXI-Lite/AXI 目录明确
自己的标准总线响应规则。不同图像组的像素位宽、窗口、配置、存储地址单位
和完成信号不同，接线前以各模块端口为准。

串行外设接受操作后按物理时钟持续推进，CE 仅控制 CSR 握手。DMA 原生
内存侧仍采用共同 CE；连接普通物理时钟内存时使用 `common/` 中的适配器。

```powershell
python cores/system/common_scaffold/run_tests.py --jobs 3
```

源文件包为 `rtl_functional_sources.f`，含实现、支持模块与兼容入口，排除
统一算法模板和测试台。从仓库根可用 `iverilog -g2012 -tnull -f
cores/system/common_scaffold/rtl_functional_sources.f` 做整个源包编译。

统一占位层与 `image/` 实现稿名称不同，不自动替换或冒充已集成；后续由
具体项目选择所需源文件。此框架没有修改旧顶层、UART 合约或密码系数存储。
任何顶层集成仍需后续确认资源与接口约束。
