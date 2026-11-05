# B31：四项原生 IP，累计124项源码快照

本批依据用户确认的 `goal.txt` 恢复四通道开发。基线为 `1d0afbd`；新增能力经过语义去重、外部技术资料及许可证只读审阅后独立实现，采用仓库 Apache-2.0 许可。Orchestrator 实现 Huffman 核，并完成跨通道集成及证据核对。

| 功能包 | 新增能力 | 有效有限检查 / 成功仿真 | 架构风险 |
| --- | --- | ---: | --- |
| [axil_timeout_bridge](../cores/system/axil_timeout_bridge/README.md) | AXI-Lite 独立读写超时、SLVERR、方向隔离及迟到响应排空；保持未接受请求的 VALID 与负载 | 11 / 4 | LOW |
| [block_ca_cfar](../cores/signal_processing/block_ca_cfar/README.md) | 有 guard/training 窗的局部噪声自适应检测，使用精确有理阈值比较，逐 cell 输出 | 10 / 4 | MEDIUM |
| [grayscale_vertical_seam_carve](../cores/image_processing/grayscale_vertical_seam_carve/README.md) | 最小梯度垂直接缝 DP 与回溯，实际减列并输出移除位置及代价 | 12 / 5 | MEDIUM |
| [canonical_huffman_table](../cores/acceleration/canonical_huffman_table/README.md) | 运行时由码长构建 canonical 编码表、双 bank 原子激活、错误保留旧表及符号查码 | 10 / 4 | 默认 LOW；RAM 映射 MEDIUM |

43条有效检查包括17次有限仿真；历史失败、被后续检查替代的成功记录和重复编译不重复计算为覆盖范围。四项当前状态均为 `LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED`。其中 LINT_PASS 的具体证据是 Icarus `-g2012 -Wall -tnull` 语法/展开检查，没有额外 Verilator 或形式证明。累计继承的一项仅语法候选继续保持原状态。

CA-CFAR 检查覆盖1223个输出 cell、3717个反压周期、非法配置及复位。接缝裁剪覆盖五种尺寸、70帧及60,186个输出像素；原64×64 TB仿真时限失败保留，修正几何相关看门狗后只定向重跑最大尺寸，RTL和该组输入/期望向量保持原字节。Huffman 覆盖四种参数、11,367条命令、45,463个反压周期，以及16位全一码字、失败 BUILD 保留旧表和复位取消。AXI-Lite 覆盖四种参数，包括最短超时、分离 AW/W、最终期限响应优先、隔离及迟到响应；同拍本地请求与迟到排空仅做源码审查。

原始失败保持可追溯：Huffman 首次调用遇到损坏的 Chocolatey PATH 入口，HDL未执行；切换至仓库内实际存在的 OSS 工具后通过。CA-CFAR 的首轮极窄参数 TB 使用了无法表示的分母，原始失败和源码保留，修复测试刺激后通过。所有回执保留实际命令、结果和源码映射；没有把失败或未运行检查改为 PASS。

交叉审查未发现具体 RTL 功能缺陷。检查运行器的缺工具/超时收尾问题已修复。AXI-Lite 与图像核最后的运行器安全修改只做源码检查，图像核另执行了不涉及模型/HDL的缺工具探针；原已执行版本保留在 `history/` 并通过哈希映射，不能将历史回执视作覆盖这些新运行器字节。Huffman 的最终运行器及新增最大码字边界实际执行通过。每包 `B31_DELIVERY.json` 汇集明确选中的原始回执，不重新执行模型或 HDL。

每包均包含实际 RTL、从包根解析的 `files.f` 和 `example/files.f`、完整接口/位宽/复位/反压/时序说明、独立参考测试以及本地依赖。四项没有外部 RTL 依赖或厂商原语。所有新包用 `.gitattributes` 保留原始日志和源码字节，避免 Windows 换行转换破坏证据哈希。架构风险仅为源码判断；默认及最大参数的实际器件资源、频率、功耗与硬件吞吐均未测量。

累计快照：[源码及SHA-256清单](snapshots/source_20261106_b31.json)；[源码闭包和模块声明审计](snapshots/source_20261106_b31_structure.json)。B30的120项清单逐项原样继承；新快照中的四个包与旧包之间没有重复模块声明。离线使用时从对应包根解析清单，并保留仓库 LICENSE及快照所列依赖。

本轮未运行综合、布局布线、STA、上板、PPA、完整回归、历史组合检查器或累计合并 HDL 编译。此交付为本地 Git 源码快照；既有用户修改及未跟踪资产保持原状。长期持续开发目标保持 active。
