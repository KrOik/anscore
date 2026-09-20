# Reusable FPGA IP Cores

按功能组织的自主开发 FPGA IP 源码仓库，采用 Apache-2.0。现有第三方文件的版权和许可证声明继续适用。

| 目录 | 功能 |
| --- | --- |
| `cores/crypto` | 混合格密码 NTT/INTT、AES、SM2、RSA 等 |
| `cores/signal_processing` | DSP、变换、DSP/ISP 流水线库 |
| `cores/image_processing` | 图像窗口处理 |
| `cores/communication` | 通信算子 |
| `cores/acquisition` | ADC 采集、麦克风阵列 |
| `cores/storage` | SD 卡 SPI |
| `cores/acceleration` | CNN、SNN/LSTM、A*、通用加速算子 |
| `cores/system` | 流、总线、基础算子和扩展库 |
| `host` | IP 对应主机验证工具 |
| `scripts` | 仿真、构建和板级验证入口 |

包内部保留 RTL、模型、测试、向量、文档与验证摘要的相对布局；板卡顶层、管脚约束和板级测试是对应功能包的适配层，不代表可复用 IP 本身。不同历史库可能包含相近模块，应参考各包 manifest、接口及验证状态选择，不能将名称相近的模块直接互换。

## 验证

需自行安装 OSS CAD Suite，并设置 `$env:OSS_CAD_ROOT` 为包含 `bin` 和 `lib` 的安装目录，或将工具链放在 `tools/oss-cad-suite/oss-cad-suite`。Python 主机依赖见各功能包说明。完整功能族索引见 [IP_INDEX](docs/IP_INDEX.md)。

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
python host/tvla/analyze_tvla.py --self-test
```

综合、布线及上板需要各包文档指定的目标器件、工具版本与依赖。外部 SDK、第三方 IP 和本机工具安装不随仓库分发。部分历史脚本仍含原开发环境或外部依赖路径，不能视为所有包均已完成跨平台移植。

## 状态与边界

本仓库收集开发中的 IP 和验证材料，不作统一量产验收声明。尤其格密码整机流程、掩码和随机化仍是研究原型；功能仿真不等同于 TVLA 或形式化侧信道安全证明。具体状态以每包文档为准。

`docs/package_map.json` 记录原项目到功能包的映射。发布树只包含源码、测试、模型、必要向量、约束与文档，排除历史 evidence/artifacts、采集文件、运行日志、网表及仿真可执行文件。原始验证记录保存在本地开发工作区。

本仓库保留远程原有 LICENSE 初始提交。后续源码导入提交按维护者要求，回填到 2026-09-20 至 2026-10-15（UTC+08:00）；这些日期是整理导入的编排日期，不代表实际开发或逐日验证时间。详细说明见 [导入记录](docs/IMPORT_HISTORY.md)。
