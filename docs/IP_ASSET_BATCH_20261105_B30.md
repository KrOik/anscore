# B30 累计源码交付（120 项）

本次收尾将 B30 四项新能力纳入累计 120 项源码交付。持续开发目标保持暂停；仅更新远端 `main`，不创建新的 stable 分支或 snapshot 标签。

| 功能包 | 功能边界 | 新执行 / 沿用 / 有效记录 | 成功仿真 |
| --- | --- | --- | --- |
| [ram_range_min_index](../cores/storage/ram_range_min_index/DELIVERY.md) | 持久区间赋值、区间最小值及最小索引平局规则、清空 | 25 / 0 / 25 | 12 |
| [exact_1d_transport](../cores/signal_processing/exact_1d_transport/DELIVERY.md) | 平衡一维 L1 精确运输代价及稀疏耦合 | 22 / 3 / 25 | 10 |
| [grayscale_stable_extremal_regions](../cores/image_processing/grayscale_stable_extremal_regions/DELIVERY.md) | 基于既有最大树的单侧稳定极值区域选择；与原始对称 MSER 的定义不同 | 22 / 4 / 26 | 10 |
| [exact_undirected_steiner_tree](../cores/acceleration/exact_undirected_steiner_tree/DELIVERY.md) | 正权无向图 Steiner 精确最优代价及边见证；不承诺全局字典序最优见证 | 28 / 1 / 29 | 12 |

有效记录共 105 条、成功仿真 44 次。全部历史 HDL 子任务实际执行 118 次，其中 114 次成功、4 次历史失败；仿真曾尝试 46 次。四次数值准备各只执行一次，HDL 检查仅使用保存的目标、元组或证书，未重新求解。收尾没有运行编译、仿真、旧检查器、模型或准备脚本。

三处已测修复按字节交付：运输 TB 的扫描目标改为有符号 64 位临时量；区域 TB 的 EOF 扫描改为逐字符消费空白；Steiner RTL 使用打包终端别名消除数组敏感性诊断。每包 `CHECKED_SOURCE.json` 记录原始→已测→交付的映射；历史 AUTHOR/SOURCE seals、原 README/status、receipt 与 raw 保持原样，不能将旧 seal 视为覆盖新 overlay。

19 个成功 VVP 副本在实际审阅完成后精确清理，处置路径、哈希、大小、审阅依据及时间另行记录。失败镜像与完整失败归档永久保留在原本地位置；B30 不将 VVP、运行库二进制或失败归档纳入 Git。嵌套 `.git` 元数据用明确映射复制至 `delivery/relocated`。C 的实际证据报告披露了审阅者曾编写控制器，具体波形和取消输出数值的证据边界以报告为准。

累计源码结构为 251 个原始路径、250 个规范来源、241 个 top、252 个模块声明，未发现名称冲突。B29 的 10,719 个冻结路径保持 Git mode/type/OID 不变。新包的 `files.f` 与 `example/files.f` 均从包根解析；两项复用依赖（canonical CIP RAM 与 grayscale_max_tree）已在累计交付中。

所有新包为 `LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED`，只代表明确列出的有限检查。未进行综合、布局布线、STA、上板或 PPA 实测。累计继承的一项仅语法候选仍保持原状态。组合快照检查器与合并 HDL 编译均为 `NOT_RUN`、零调用，B25 的原始终止失败未重试。

清单：[120 项源码哈希](snapshots/source_20261105_b30.json) · [结构审计](snapshots/source_20261105_b30_structure.json) · [组合检查状态](snapshots/source_20261105_b30_check.json)。原有未提交修改、未跟踪资产和 58 个旧 stable/snapshot 引用均保留，不包含在本次交付提交中。
