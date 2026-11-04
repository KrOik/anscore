# 2026-11-04 第五批与累计二十项源码快照

本批开发基线为 `cf9b62d`，分支继续使用 `development/ip-assets-20261104`。
新稳定分支 `stable/source-20261104-b5` 和固定标签 `snapshot/source-20261104-b5`
绑定累计二十项能力。前四批分支与标签保持原提交。

| 功能包 | 独立增量与组合价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [word_writeback_cache](../cores/storage/word_writeback_cache/README.md) | 直接映射整行填充、字节写合并、脏行写回及flush+invalidate；实际连接旧BRAM | `097d2cd` | 5配置2318命令（含30个idle reset标记）、15503个后端事件、4288个RAM字比较；每配置7个阶段复位探针；组合例通过，8非法参数拒绝 |
| [stream_linear_fit](../cores/signal_processing/stream_linear_fit/README.md) | masked整数样本流直接得到OLS斜率/截距和精确spread；复用已有2×2求解器 | `727aebf` | 6配置472帧、10090个输入beat/9665个保留样本对，含137退化帧、49溢出前缀帧、31饱和帧；Fraction中心化oracle，256种最小数据两样本帧穷举；11非法参数拒绝 |
| [polyline_rdp](../cores/image_processing/polyline_rdp/README.md) | 有限线段距离的精确RDP有序折线简化，保端点和顺序，无开方/除法 | `423d947` | 6配置999折线、3352输出，含729条格网三点有序路径；独立递归Fraction oracle；27次复位取消，最大参数实际仿真；6非法参数拒绝 |
| [bipartite_match](../cores/acceleration/bipartite_match/README.md) | 兼容边流到最大基数一对一资源匹配，支持非对称集合及确定性配对 | `a9ab9e3` | 9配置1902图、11660输出；独立最大流与868个subset-DP交叉核对；2×3和3×3共576种图全部覆盖并重排/重复回放；每配置9个复位探针；6非法参数拒绝 |

每项都具备实际RTL、源文件清单和最小示例、完整契约、离线有限TB或生成模板、
实际工具记录和源码/依赖hash、语义去重及只读外源许可记录。每工具子进程限制
15或20秒。新包全部文本为LF，临时向量及模拟器产物已清理，不依赖在线下载。

## 调用边界与架构风险

- 缓存仅适用于普通幂等RAM。成功写命令可只更新dirty缓存，flush成功后才保证
  全部脏写已获后端应答且全失效。写回错误保留整条dirty行；填充错误不安装
  半行；flush错误保留已处理前缀进度。复位丢弃dirty数据，需协调后端旧应答。
  缓存地址应由调用者独占，无snoop或MMIO语义。默认2048bit数据+416bit元数据，
  最大32768+1408bit，风险LOW/MEDIUM。旧BRAM的复位语义在例子中独立说明。
- 拟合保留前 `2^COUNT_W-1` 个selected样本；溢出结果只描述该前缀。正常方程
  整数统计无中间量化；最终系数向零截断并独立饱和。spread为零时报告退化，
  返回零系数。约束 `2*DATA_W+COUNT_W+1<=24` 匹配旧solver域，不能任意扩大
  样本/数值宽度。一个小乘法器收集统计，solver内部迭代共享算术，不存样本帧。
  默认风险LOW，最大系数/小数/结果位宽风险MEDIUM，无实测资源或时序承诺。
- 折线距离针对有限线段，含端外投影和零长段；距离严格大于epsilon才分段，
  同距取最早输入点。epsilon=0仍删除冗余共线点。空集/超容均发一个状态token，
  超容整块拒绝，不发布prefix。无闭合轮廓拓扑或最优压缩保证。默认/最大点、
  栈及bitmap为1184/3008bit，共享27×27/35×35乘法器，风险MEDIUM/HIGH。
- 匹配只优化基数，不处理边权和跨图公平性。每个左节点发一条结果，unmatched
  的right为零，固定总基数重复在全部结果中。重复边幂等，无边数容量截断；
  非法端点忽略并置bad_index。升序root/FIFO/升序邻居使相同邻接图的完整配对
  结果确定，但不承诺字典序最优。默认/最大数组及valid/seen/row为200/1824bit，
  另有标量控制；风险LOW/MEDIUM，不宣称BRAM推断。最坏串行工作为O(L²R)。

四核心均单时钟、同步高有效复位、无CE；普通ready/valid与CE-qualified接口不能
仅凭端口名称直接连接。各自backend、帧和输出数量契约见README。全部状态为
**LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**，示例为 **INTEGRATION_CANDIDATE**。
风险标签只来自结构审查；未运行综合、布局布线、STA、上板或扩大回归。

## 交叉审阅与复位证据修正

A审匹配、B审缓存、C审拟合、root审折线。审阅发现匹配TB在观察瞬态state后，
复位任务又等待一个negedge，导致实际取消位置前进。已拆成立即断言reset_now
和等待入口reset_core，并为每图首个valid结果强制三拍停顿，覆盖单节点配置。
最终原九组有限套件重跑通过；生产RTL没有因此修改。

同类审计促成两项额外测试修正：

- 折线模板立即取消观测state，单点分支改为有界等待并断言OUT_HOLD，再复位。
  `0088b57` 仅改测试脚本和证据；原六组有限检查重跑通过。
- 上批Kruskal的短暂PUSH状态探针也消除额外等待。`53016a2` 仅改TB和证据；
  原五组420图/3683token/24工具记录重跑通过，生产RTL及向量内容未改。

最终修正均已只读复核。B5清单绑定这些更新后的测试与证据，并记录修正提交；
原B4固定快照保留历史文件。没有将阶段探针解释为任意周期复位证明。

## 累计稳定集合与离线检查

[B5清单](snapshots/source_20261104_b5.json)绑定180个包内文本文件和6个共享
支持文件。原求解器、仲裁器、RAM等共享RTL仍引用同一源文件，未复制或改写。
根LICENSE/NOTICE和backend说明/许可记录一并导出。该清单仅覆盖持续开发中
已审查的二十项，不表示整个历史仓库重新验收。

最终冻结检查在 `7e5a5d34bdde9867aba1cc8858c944f64c4a5370` 通过：
**20个内核+21个示例，共41个top、43个唯一生产源文件**，在仅含清单提交内容
的隔离目录中一次Icarus `-tnull` 编译通过。检查包括全部文件hash、有限检查
记录、源码/依赖证据绑定、路径闭包和module重名。原始输出自动保存到
[冻结记录](snapshots/source_20261104_b5_check.txt)。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b5 --manifest docs/snapshots/source_20261104_b5.json --compile
```

该检查不会重跑全部数值仿真，也不扩大有限证据的证明范围。源码可离线使用，
无外部RTL或在线构建依赖。原有未提交修改、删除及未跟踪资产未收录或清理。
开发Goal继续active，此处是可追溯的进展检查点。

前批记录：[第一批](IP_ASSET_BATCH_20261104.md)、[第二批](IP_ASSET_BATCH_20261104_B2.md)、
[第三批](IP_ASSET_BATCH_20261104_B3.md)、[第四批](IP_ASSET_BATCH_20261104_B4.md)。
