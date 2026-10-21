# Isolated AWB constant-three divider candidate

2026-10-17：代码及独立功能回归 PASS。此目录是 `/root/awb_board_candidate` 的独占开发边界；生产 RTL、冻结 v95、UART 黄金、原 watchdog、共享 top/build 均未修改。未运行综合、布局布线或板卡操作，面积、DSP、Fmax、hold 和板端资格尚未测量。

候选仅把 `DIV_TARGET` 的 `floor((sum_r+sum_g+sum_b)/3)` 从 58 位可变除数 divider 分离为 50 位精确 radix-4 常数除法。三个通道的可变除法、borrow-prefix、floor/clamp、黑帧中性增益、错误位和外部 CE/valid/ready 逻辑保持 v95。模块名称为并排编译而改名；`run_regression.py` 会核对允许的完整文本变换，并单独核对 variable-divider/prefix 除模块名和准确性修正的头部注释外正文未改变。

复现命令（仓库根目录）：

```powershell
python -B .\cores\system\common_scaffold\image\isp\sim\awb_div3_20261017\run_regression.py
python -B .\cores\system\common_scaffold\image\isp\sim\awb_div3_20261017\collect_public_references.py
```

第一条先验证 helper，再创建或核对 autogain 候选，随后执行 v95 双实例对照。工具通过现有 `device_flow.resolve()` 定位 OSS CAD Suite 原生 `iverilog`/`vvp`，编译使用 `-g2012 -Wall`；精确命令见各 `compile_*.log` / `simulation_*.log`。第二条仅更新公开参考证据，可离线跳过，不参与 RTL oracle。

独立 Python oracle 仅使用无界整数 `//`、`%`、`min/max` 和显式错误位，与 RTL 的逐位/逐 digit 算法独立。17 个原始 v95 向量从生产回归 fixture 只读取得，每个黄金输出先与整数 oracle 核对，不重写旧黄金。

| 回归 | 位宽 | 向量 / 实际结果检查 | 结果 |
| --- | --- | --- | --- |
| 常数除 3 helper | 1, 2, 3, 7, 49, 50, 51 | 8,400 / 8,407 | PASS |
| 其中 50 位 helper | 50 | 5,398 / 5,399 | PASS，含 0、最大值、2 的幂邻域、3 倍数邻域和 4,096 组随机数 |
| AWB 候选与 v95 + 整数 oracle | SUM_WIDTH=1, 8, 9, 13, 16, 17, 48, 49 | 1,135 / 1,143 | PASS |
| 默认 48 位 AWB | 48 | 289 / 290 | PASS，含未改的原 17 向量 |

“实际结果检查”每个配置比向量数多一次，原因是复位取消后重放一个有效事务。向量分布、固定种子和 mem SHA 见 `vectors_manifest.json`；逐例延迟和握手覆盖计数见 `regression_summary.json`。

覆盖 CE 暂停、输入快照后持续发送 poison 请求、忙时 start、输出背压、输出 ready 在 CE=0 时保持、helper 同沿退休与新请求接收。helper 在 busy 和待取结果时分别执行 CE=0 异步复位；AWB 在 target busy、channel divide busy 和待取结果三处执行 CE=0 异步复位，释放复位后继续保持 CE=0 再恢复。所有情况均检查无幽灵输出并验证后续恢复。

延迟统计为从输入接收边沿到首个输出 valid 的 CE 有效上升沿数量，包含接收边沿，不计 CE=0。50 位 helper 为 26 个边沿（接收 1 + 计算 25）。默认 48 位 AWB 所有非元数据错误事务（包括黑帧）均比 v95 少 33 个 CE 边沿；原即时元数据错误保持 1 个边沿。原 17 例：

| case | v95 CE | 候选 CE |
| --- | --- | --- |
| 0 | 250 | 217 |
| 1 | 598 | 565 |
| 2 | 772 | 739 |
| 3 | 190 | 157 |
| 4 | 67 | 34 |
| 5–7 | 1 | 1 |
| 8 | 306 | 273 |
| 9–10 | 67 | 34 |
| 11–12 | 130 | 97 |
| 13–14 | 190 | 157 |
| 15–16 | 250 | 217 |

所有受检 SUM_WIDTH<=49 的有效 CE 延迟仍小于继承的 800 边沿上限；未修改原 watchdog。该表是 RTL 仿真计算周期，不能推导新器件 Fmax 或板测 PASS。

helper 的接口为 `awb_constant_div3_radix4 #(.WIDTH(50))`：

| 信号 | 合约 |
| --- | --- |
| `clk, rst_n, clk_en` | 异步低有效复位；CE=0 冻结全部状态；复位取消在途事务和待取结果 |
| `start, start_ready, numerator_in[WIDTH-1:0]` | 仅在 CE 有效且 start/ready 同高时接收；忙时请求忽略 |
| `busy` | 接收后到最后一个计算边沿为高 |
| `result_valid, result_ready` | sticky valid；背压时商和余数稳定；允许旧结果退休同沿接收新请求 |
| `quotient_out[WIDTH-1:0], remainder_out[1:0]` | valid 时为精确 floor(n/3)、n%3；余数范围 0..2；非 valid 期间商为工作寄存器，不应采样 |

每一步 `trial=4*remainder+next_digit` 的范围为 0..11，选择商 digit 0..3 后满足 `trial=3*quotient_digit+new_remainder` 且余数仍小于 3。逐 digit 保持前缀恒等式，奇数位宽在最高端补零，不改变数值。未声称形式化工具证明。

供父任务串行测量的构建输入：

- `awb_constant_div3_radix4.v`：独立 helper，必须作为单独 RTL 源加入候选构建。
- `img_isp_awb_autogain_div3_candidate.v`：顶层模块 `img_isp_awb_autogain_div3_candidate`，参数及端口与生产 `img_isp_awb_autogain` 完全相同。它内含改名的 byte-divider/prefix 子模块，无需额外生产 autogain 文件。
- 在独立 staged harness 中实例化候选模块；统计、像素增益及 UART 自测仍使用原文件和原黄金。不要同时将候选再改名覆盖生产文件。

关键 SHA256：

| 文件 | SHA256 |
| --- | --- |
| 只读生产 / 冻结 v95 autogain | `98715b6e6937575bfca1121c8b20029b1f59c8a715b4b6c17639a07e7178bb98` |
| 只读生产 stats | `26aa23144444042085860068275b0bb4388d3e5785633e8213358ce29c3d5cc0` |
| 候选 helper | `565f370fa57163e42c6f831d1316ef2d5b8380d3590bcc586322111352299d1b` |
| 候选 autogain | `ba73ff2aae17e8fa5fddf94d1f1f84cf8aa51ede96540d274295bdd94e786660` |

实际公开 HTTP 参考（均 HTTP 200，commit/source SHA/关键行保存在 `public_references.json`）：

- [Project F: Division in Verilog](https://projectf.io/posts/division-in-verilog/) 及其[固定版本整数 divider](https://github.com/projf/projf-explore/blob/c2eca17e9d3c5084db0c993a09d59c94bbd93439/lib/maths/div_int.sv)：对照迭代长除法和 busy/done 边界。本候选使用自行编写的常数三 radix-4 算法和 CE/背压接口，没有复制该实现。
- [AMD Vitis AWB](https://github.com/Xilinx/Vitis_Libraries/blob/e42643491a5851557fb392990d7be2e8139ae67b/vision/L1/include/imgproc/xf_autowhitebalance.hpp)：参考统计/通道增益与像素应用分离、像素循环 II=1 的结构。其数值归一化不同，不替换本地 mean-based gray-world，不作为 Gowin 面积/时序证据。

并行只读代码审查由 `/root/awb_board_candidate/div3_scope_review` 完成，无阻断项；它建议的 CE=0 异步复位覆盖已补充并执行。父任务指出复制注释仍提及旧的常数三共享路径，现已将该头部注释修正为只负责 channel quotient。修正后完整独立轻量回归再次 PASS，最终完成时间 `2026-10-17T06:51:40.891319Z`，collector 和全部仿真输入 SHA 均与最终回归记录一致。

VVP 及改名 reference RTL 放在本目录内由 runner 创建的唯一临时子目录，`TemporaryDirectory` 在成功或异常退出时清理。最终 `retained_vvp=[]`、`retained_pyc=[]`；未删除历史证据、已有构建产物或目录外文件。保留源码、向量、可复现脚本和小型日志；无网络完整源码副本、网表或波形大文件。
