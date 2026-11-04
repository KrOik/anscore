# 2026-11-04 原生 IP 批次与源码稳定快照

本批新增四项独立能力。开发分支为 `development/ip-assets-20261104`；
源码稳定分支为 `stable/source-20261104`，固定标签为
`snapshot/source-20261104`。基线为 `430d420`，四项功能分别提交，便于单独复用和回退。
稳定分支是源码可调用快照，**不是硬件合格快照**。

| 功能与源码入口 | 功能提交 | 依赖与最小连接 | 有限检查证据 |
| --- | --- | --- | --- |
| [选择性流多播](../cores/system/stream_multicast/README.md) | `46b5338` | 包内 `files.f`、`examples/multicast_2way.v` | `check_results.json`：2项静态编译、3组仿真；每组179输入，分别105/309/513输出 |
| [CDF 5/3 整数小波](../cores/signal_processing/cdf53_block/README.md) | `010b765` | 包内 `files.f`、`examples/cdf53_roundtrip.sv` | `verification.json`：18组正逆参数、6460个样本比较；64样本串联；5组非法参数拒绝 |
| [定点块 SSIM](../cores/image_processing/stream_ssim/README.md) | `fa1ba13` | 包内 `files.f`、`example/ssim_block_example.sv` | `verification.json`：3组参数66块；最大参数仅编译；4组非法参数拒绝 |
| [在线二叉堆优先队列](../cores/acceleration/binary_heap_queue/README.md) | `af5fdeb` | 包内 `files.f`、`examples/binary_heap_queue_example.sv` | `reports/validation.json`：8组参数4694条参考命令；每组26个复位取消时间切点 |

四个内核均为 `LINT_PASS`（Icarus语法/展开检查）、`UNIT_SIM_PASS`、
`HW_UNVERIFIED`。连接示例属于 `INTEGRATION_CANDIDATE`，没有完整系统硬件验证。
本轮未执行综合、布局布线、STA、上板或完整回归；旧资产的历史证据没有迁移到新增RTL。

## 使用与接口边界

四个包的 `files.f` 均列出完整生产源码，没有运行时下载、外部生成器、
ROM初始化文件或未提交的RTL依赖。每个包提供独立的Python标准库测试入口，
每个工具子进程限制在15或20秒；缺工具、超时或失败不记作PASS。
临时向量、生成TB与模拟器二进制位于任务专属临时目录并自动清理。

四项接口都采用标准 `valid && ready`，没有CE端口。多播使用异步低有效复位，
其余三项使用同步高有效复位。连接现有CE-qualified stream之前必须检查语义，
需要时使用独立适配器。包内说明定义了复位取消、数值格式、输入/输出顺序、
配置、背压和错误行为；不能仅凭端口名称直接连接。

结构审查的定性风险：多播默认LOW，大端口数的扇出与ready归约MEDIUM；
小波默认LOW、最大参数MEDIUM；SSIM宽迭代算术MEDIUM；堆队列默认容量LOW、
比较/选择路径MEDIUM，大容量可能HIGH。它们不代表实测资源、频率或功耗。

全部代码独立原创，采用仓库Apache-2.0许可。开发前只读检查的固定上游、
具体文件、许可及未引入代码的结论见各包 `SOURCES.md`，SSIM记录在其README。
优先队列候选缺少许可，故未复制或改编任何候选源码。

## 源码冻结与检查

本批功能提交后进入源码冻结窗口；窗口仅处理依赖、命名、接口说明和索引等
影响调用的问题。包内 `.gitattributes` 固定LF，避免跨平台检出改变文件摘要。
工作区原有大量未提交资产与既有删除未被本批提交收录，也未被删除或重写。
它们不属于本批稳定快照的新增能力清单；基线旧文件可从原提交恢复，不能据此
推断所有历史资产已经逐项重验。

[机器可读快照](snapshots/source_20261104.json) 列出本批35个文本产物的
SHA-256、功能提交、依赖清单、示例顶层与原始有限检查记录。
[源码快照检查器](../scripts/check_source_snapshot.py) 从指定Git提交读取文件，
核对摘要、有限检查记录、生产依赖闭包和本批模块名称唯一性。`--compile`
只导出清单内文件到新临时目录并一次性编译4个内核和4个示例，避免依赖脏工作区
中的隐藏文件。基线模块名搜索未发现这些新增生产模块或示例的重名声明。

在仓库根目录复查稳定标签：

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104 --compile
```

该检查器验证源码快照的一致性与独立编译能力，不替代有限功能测试、形式证明或
硬件验收。各有限单元测试入口见对应README；未列出的参数和输入组合不宣称通过。
本批[冻结检查输出](snapshots/source_20261104_check.txt)已保存；其后仅添加文档入口
与检查记录，包内源码、原始测试证据、清单和检查器均保持一致。

## 后续开发边界

此批已完成可追溯交付，整体Goal继续保持active。后续按四通道做语义去重与
功能增量开发，仍由Orchestrator贡献计算/加速RTL。新任务在开发分支继续，
不移动本批稳定标签。既有未提交资产的正式收录需要先完成其源码、许可、
依赖与证据审计；不能将整个脏工作区批量暂存作为稳定快照。
