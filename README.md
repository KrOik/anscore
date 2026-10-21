# Anscore

**Reusable FPGA IP Cores & Hardware Accelerators**

Anscore 是一个面向 FPGA 设计与硬件加速的模块化 IP 核开源仓库，涵盖密码计算、数字信号处理、图像处理、通信协议、数据采集、存储管理、神经网络加速与嵌入式控制。

项目围绕**可复用的 RTL 设计、可组合的数据通路与可验证的工程实现**持续建设。除了 IP 源码，仓库还整理了参考模型、测试用例、自动化脚本和板级适配工程，方便从单核验证逐步扩展到完整 FPGA 系统。

[浏览 IP 功能索引](docs/IP_INDEX.md) · [查看仓库源码](cores/) · [参与贡献](CONTRIBUTING.md)

## 项目特点

- **多领域 IP 库**：从算术、流控和总线接口等基础模块，扩展到 NTT/INTT、DSP/ISP、CNN 推理、通信和电机控制等功能模块。
- **模块化设计**：按功能组织源码，区分通用 IP、系统集成和开发板适配，便于按需选用与组合。
- **配套验证工具**：各功能包根据实现情况提供 RTL 测试、软件参考模型、测试向量、主机程序及构建脚本。
- **面向实际硬件**：支持围绕 Gowin/Tang 系列 FPGA 开展综合、时序分析和板级验证，并持续推进 Tang Primer 25K（GW5A-25）上的功能集成。

## IP 功能模块

| 功能领域 | 主要内容 | 源码目录 |
| --- | --- | --- |
| **Cryptography** | 格密码 NTT/INTT、AES、SM2、RSA 及密码学基础算子 | [`cores/crypto`](cores/crypto/) |
| **Signal Processing** | FFT、滤波、CORDIC、DSP/ISP 流水线及数字锁相处理 | [`cores/signal_processing`](cores/signal_processing/) |
| **Image & Video** | 图像窗口算子、流式 ISP、视频合成与显示数据处理 | [`cores/image_processing`](cores/image_processing/) |
| **Communication** | UART、SPI/I²C、Ethernet/UDP 及通信基础模块 | [`cores/communication`](cores/communication/) |
| **Data Acquisition** | ADC 采集接口、同步采集与麦克风阵列处理 | [`cores/acquisition`](cores/acquisition/) |
| **Storage & DMA** | SD 卡 SPI、缓冲管理、帧描述符与数据搬运 | [`cores/storage`](cores/storage/) |
| **Hardware Acceleration** | CNN、SNN/LSTM、A* 搜索及通用计算算子 | [`cores/acceleration`](cores/acceleration/) |
| **Motor Control** | FOC、坐标变换、PWM 与相关电机控制模块 | [`cores/control`](cores/control/) |
| **System Infrastructure** | Stream Fabric、总线互联、FIFO/CDC、寄存器控制及测试基础设施 | [`cores/system`](cores/system/) |

完整的模块清单、具体入口和功能包位置见 **[IP_INDEX.md](docs/IP_INDEX.md)**。同类功能可能存在不同架构或实现版本，选型时请参考对应功能包的接口说明和验证记录。

## 仓库结构

```text
anscore/
├── cores/
│   ├── crypto/              # 密码与安全计算
│   ├── signal_processing/   # DSP、变换与锁相处理
│   ├── image_processing/    # 图像、ISP 与视频处理
│   ├── communication/       # 通信协议与接口
│   ├── acquisition/         # ADC 与阵列采集
│   ├── storage/             # 存储、缓冲与 DMA
│   ├── acceleration/        # AI 与通用硬件加速
│   ├── control/             # 电机与控制算法
│   └── system/              # 总线、数据流和基础组件
├── host/                    # 主机端测试与交互工具
├── scripts/                 # 仿真、构建及板级操作入口
├── docs/                    # IP 索引、开发文档与项目记录
├── CONTRIBUTING.md
└── LICENSE
```

功能包内部按需求包含 RTL、仿真、参考模型、测试向量、文档和板级工程。历史功能包的内部布局可能不同，以各自的说明文件为准。

## 快速开始

### 1. 获取源码

```bash
git clone https://github.com/KrOik/anscore.git
cd anscore
```

### 2. 准备开发环境

建议使用 **OSS CAD Suite** 提供的开源 RTL 工具链（包括 Icarus Verilog、Yosys 等），并根据目标板卡准备对应的 Gowin 工具与驱动。

Windows PowerShell 环境下，可将 OSS CAD Suite 安装目录的 `bin` 和 `lib` 加入 `PATH`，例如：

```powershell
$env:OSS_CAD_ROOT = "C:\path\to\oss-cad-suite"
$env:PATH = "$($env:OSS_CAD_ROOT)\bin;$($env:OSS_CAD_ROOT)\lib;$env:PATH"
```

也可以将工具链放在 `tools/oss-cad-suite/oss-cad-suite/`，供现有 PowerShell 脚本自动定位。具体依赖请以选用的功能包说明为准。

### 3. 运行示例测试

在仓库根目录执行：

```powershell
# UART 接收模块仿真与参考输出检查
.\scripts\test_comm_uart_rx.ps1

# TVLA 分析工具的自检
python host/tvla/analyze_tvla.py --self-test
```

如需探索格密码 NTT/INTT，可运行对应功能包的仿真入口：

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
```

不同 IP 的仿真、综合、下载及主机测试入口位于 `scripts/` 或相应功能包中。板级运行前请核对所选 FPGA 器件、引脚约束及外围设备。

## IP 集成与验证

Anscore 将可复用 IP 与板卡工程分层组织：**IP 本体**实现计算或接口功能，**适配层**负责目标器件、时钟、引脚和外设连接。开发者可以先通过测试向量与参考模型验证模块行为，再按目标硬件条件完成综合、时序和板级测试。

不同功能包具有各自的实现进度与验证范围，具体接口、依赖、性能数据及测试结果以包内文档为准。

目前的重点开发方向包括 **Stream/Test Fabric、Buffer/DMA、流式 ISP、INT8 CNN、数字锁相 DSP、Ethernet/UDP、视频合成和电机 FOC**，以 Tang Primer 25K 为主要集成目标之一。

相关技术记录：[25K IP 开发工单](docs/FPGA_IP_ASSET_WORK_ORDER_25K_V3_20261020.md) · [验证状态台账](docs/ip_asset_25k/STATUS.md)

## 文档与贡献

- **[IP 功能索引](docs/IP_INDEX.md)**：查找模块、功能包和源码入口。
- **[贡献指南](CONTRIBUTING.md)**：了解目录约定、测试要求与提交规范。
- **[项目声明](NOTICE)**：查看第三方代码与外部依赖的相关说明。
- **[许可证](LICENSE)**：查看项目开源许可全文。

欢迎通过 Issues 和 Pull Requests 交流设计建议、提交改进或补充测试用例。

## License

本仓库中作者原创的代码与贡献采用 **[Apache License 2.0](LICENSE)**。第三方文件及外部依赖继续遵循各自的版权和许可证要求，具体信息见 [NOTICE](NOTICE)。
