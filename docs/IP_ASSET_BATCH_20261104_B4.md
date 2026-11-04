# 2026-11-04 第四批与累计十六项源码快照

本批从 `e711afc` 开发，继续使用 `development/ip-assets-20261104`。
`stable/source-20261104-b4` 与固定标签 `snapshot/source-20261104-b4` 收录
累计十六项已审查能力。此前三批稳定分支及标签保持原提交。

| 功能包 | 新增能力与组合价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [word_memmove](../cores/storage/word_memmove/README.md) | 原生应答字端口上的重叠安全搬移，自动选择方向，报告成功写应答进度；实际连接旧仲裁器及RAM | `cf9021a` | 4配置356描述符、45568个存储字比较，每配置5个复位切点；15字重叠组合搬移、32字读回及4次并发旁路读；4非法参数拒绝 |
| [iir_lattice_synthesis](../cores/signal_processing/iir_lattice_synthesis/README.md) | 全极点格型合成、反射系数bank原子提交、逐级定点饱和；实际接已有LPC估计器的reflection输出 | `0b997b8` | 5配置2010样本、912个预期clip、30组模型；真实分析/合成8样本，错误模型排空并保留旧历史；10非法参数拒绝 |
| [point_convex_hull](../cores/image_processing/point_convex_hull/README.md) | 任意乱序signed二维点集的精确凸包，去重和去共线中间点，确定性顶点流 | `a860946` | 5配置672块、2502个token，含3×3格点全部512种子集；独立Jarvis oracle；最大24bit/64点实际仿真含64顶点凸包；6非法参数拒绝 |
| [kruskal_msf](../cores/acceleration/kruskal_msf/README.md) | 组合已有堆队列和并查集，实现signed加权最小生成森林、选边流、精确总权重和连通分量数 | `2799f99` | 5配置420图、3683个token，对照独立Prim oracle；非singleton每配置7个复位切点；最大256节点/1024边仅编译；10非法参数拒绝 |

四个通道均贡献实际RTL。各包有接口/参数/数值/复位/背压/错误契约、源文件清单、
实例、可再生有限TB、源码绑定的实际命令记录及固定外部来源和许可审查。
交叉审阅分别由A审Kruskal、B审memmove、C审格型、root审凸包完成，未发现
阻塞缺陷；C另行审查共享依赖快照检查器。必要注释澄清已纳入最终证据。

## 使用边界与结构风险

- memmove按完整32位word操作，地址为32位byte地址。零长度优先no-op，非零
  命令先校验对齐和地址范围，同址才no-op。错误不回滚；done_words仅计算成功
  写应答，失败写是否已作用取决于backend契约。拷贝范围需调用者独占。
  核心无数据数组，默认风险LOW、最大位宽时序风险MEDIUM。组合例复用原有
  active-low异步复位的仲裁器/RAM，须协调复位，RAM内容不因复位清空。
- 格型核心采用逐级向零截断和饱和，逐样本报告clip，不能推断无溢出或无限精度
  稳定性。完整shadow bank校验后提交并清历史；坏bank保留旧系数和历史。
  c_done是脉冲，c_error保持最近状态；配置通知无ready。一个迭代移位加法乘法
  通路服务全部阶段。默认232bit/最大592bit数组，风险LOW/MEDIUM。
- 凸包输出Cartesian CCW，屏幕y向下时显示为顺时针；起点为signed字典序最小点。
  空集发一个empty token，容量超限整块拒绝也发一个error+empty token，均不是
  无输出。容量按去重前selected点数计算。寄存数组默认3072bit、最大9216bit，
  一个共享至25×25乘法器，风险MEDIUM/HIGH，不声称BRAM推断或设备fit。
- Kruskal忽略无效端点并置bad_index，忽略self-loop而不占容量；只保留前
  MAX_EDGES条eligible边，溢出后求得的是该前缀的森林。负权和平行边合法，
  tuple顺序确定tie。最后summary包括孤立点和精确signed总和。默认存储1136bit，
  最大76800bit，风险LOW/MEDIUM；共享源未改，不继承旧核的硬件验证结论。

风险是结构判断，不是实测面积、功耗、频率或吞吐。四核心均单时钟、同步高有效
复位、无CE；CE-qualified接口需要适配。配置、通知和存储接口的独立握手语义
见各README。每个实际工具子进程限制15或20秒，没有自动升级到完整回归。
核心状态均为 **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**，组合示例为
**INTEGRATION_CANDIDATE**。没有运行综合、布局布线、STA或上板。

## 固定源码与离线闭包

[累计清单](snapshots/source_20261104_b4.json)绑定142个包内文本文件，另显式
绑定6个共享支持文件：根LICENSE/NOTICE、旧backend的SPEC/来源许可记录和
两个实际RTL。所有hash来自提交Git blob。清单内包含前十二项的原有源码与
有限证据，不代表整个历史仓库重新验收。

[检查器](../scripts/check_source_snapshot.py)先导出全部批准的提交文件，再
归一化解析兄弟包相对路径；越界、绝对路径、未列出的依赖仍拒绝，不能借用
工作区文件补足闭包。相同共享源仅编译一次，不同文件的module重名仍报错。
memmove例子的examples/files.f、格型例子的integration.f均单独纳入闭包检查。
旧B3清单也通过更新检查器的24顶层隔离编译，保留向后兼容。

本批冻结检查在 `eb67f7e7f42bc29ab0fe6f3a19bc3c104412cc79` 通过：
**16个内核 + 17个示例顶层，共33个top、35个唯一生产源文件**在一次
Icarus `-tnull` 隔离导出编译中通过。文件及源码证据hash、实际有限检查记录、
模块重名和依赖闭包均通过；输出见[冻结记录](snapshots/source_20261104_b4_check.txt)。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b4 --manifest docs/snapshots/source_20261104_b4.json --compile
```

快照检查不重跑数值仿真，也不扩大有限测试证明范围。各包脚本在离线工具可用时
可重现对应测试；正式交付无需Internet、外部构建系统或在线生成源。
新增实现均原创Apache-2.0，未复制外部候选源码，旧资产原字节保留。
原有无关未提交修改、删除和未跟踪文件未收录或清理。

前批记录：[第一批](IP_ASSET_BATCH_20261104.md)、
[第二批](IP_ASSET_BATCH_20261104_B2.md)、[第三批](IP_ASSET_BATCH_20261104_B3.md)。
整体Goal继续active；本批是可追溯的进展检查点。
