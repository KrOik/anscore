# ISP 外部设计参考

核对日期：2026-10-17。以下资料用于审查实现结构，未复制外部代码。

| 来源 | 可借鉴的设计点 | 本项目的验证边界 |
| --- | --- | --- |
| [Yosys memory handling 官方文档](https://github.com/YosysHQ/yosys/blob/main/docs/source/using_yosys/synthesis/memory.rst) | 块 RAM 需要同步读；读口寄存器和附加逻辑应允许综合工具识别。文档给出独立同步读口和碰撞行为的模板。 | 原 Gamma 把 RAM 输出和 bypass 放在同一输出寄存器赋值分支，实测映射为 768 个 RAM16SDP4。v40 将 LUT 读寄存器与 bypass 数据/选择寄存器分开，完整 top 综合得到 6 SDPX9B，无分布式 RAM；仍须路由和真实板测。 |
| [AMD Vitis Vision Gamma 实现](https://github.com/Xilinx/Vitis_Libraries/blob/main/vision/L1/include/imgproc/xf_gammacorrection.hpp) | RGB 通道各用 256 项 LUT，按输入灰度查表；像素并行度决定 LUT 分区/复制。源码为 Apache-2.0 许可。 | 可用作通道/索引组织参考；它是 HLS 实现，不能直接证明 Gowin RTL 的 RAM、CE、背压或 SOF 双 bank 换表协议。 |

本仓库 v40 配置测试覆盖 incomplete commit、乱序地址、同周期 write/commit、两次
bank swap、stalled SOF。预期像素和 UART 来自独立 Python golden，未按板测结果改写。


补充核对 [Charles Eric LaForest 的 Ready/Valid 握手规则](https://fpgacpu.ca/fpga/handshake.html)：
流水线只在接受事务时更新相关状态，阻塞时保持数据/valid，避免 ready/valid 组合环。
v53 按这一结构审查三段弹性流水，配置在输入 SOF 接受时选择并随像素传递；未复制外部 RTL。
独立原整数公式对照覆盖 14,336 组像素/增益/亮度组合、43,008 通道结果，并检查 CE 暂停、
输出背压和复位清空。公开设计规则仅用于审查，不能替代本地时序或真实板测。
