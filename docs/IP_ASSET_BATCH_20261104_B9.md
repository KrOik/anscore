# 2026-11-04 第九批与累计三十六项源码快照

本批基线为 `807d992b6b0e793c08ceba2d44993d21c1dd1583`，继续使用
`development/ip-assets-20261104`。新稳定分支 `stable/source-20261104-b9`
与固定标签 `snapshot/source-20261104-b9` 绑定累计三十六项。前八批十六个
稳定引用保留原提交，清单的直接前批明确为B8。

| 功能包 | 独立能力与调用价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [shared_packet_queues](../cores/storage/shared_packet_queues/README.md) | 多packet FIFO动态共享cell池，整包原子发布、回滚、选队POP/FLUSH与credit | `d4016f8` | 5配置3050命令、7105输入/4048输出，91次实际prefix回滚；23645次完整池partition检查、2443033次cell观察；79次立即阶段取消 |
| [weighted_isotonic](../cores/signal_processing/weighted_isotonic/README.md) | 有权非递减最小二乘拟合，精确有理最大常值块及成员区间 | `d4e4f12` | 6配置2562主帧、9433输入/4487输出；2436正常/126错误，8482项KKT前缀检查、2276次小域全分区loss交叉；106次立即取消 |
| [label_region_adjacency](../cores/image_processing/label_region_adjacency/README.md) | 标签raster的区域邻接图及精确共享单位边数，含节点/像素/边总数 | `48c546c` | 8配置932主帧、129092像素、10831边及932个DONE；2x2全256四label图、3x3全512双正label图；99次立即取消 |
| [maxflow_mincut](../cores/acceleration/maxflow_mincut/README.md) | 一般有向容量图的精确最大流、canonical流矩阵及残量可达最小割证书 | `c7f6632` | 7配置1120图、8764输入/60061输出；995次穷举割交叉、83次确定性完整解回放；最大32节点/24位容量实际仿真；98次立即取消 |

本批26组实际仿真配置、97条工具记录，包含34项预期非法参数拒绝，四包分别
8/8/12/6项；每工具子进程限时15或20秒。四包40个本地文件全部严格UTF-8/LF，
具真实可综合RTL、完整离线清单、最小实例、接口/数值/错误/复位/反压契约、
独立有限测试、当前源码hash、只读语义去重、实际固定外源源码与完整许可证
预检，以及定性的存储/算子风险预算。任务临时向量和模拟器产物已自动清理。

## 主要边界与资源风险

- 共享包队列PUSH私有预留cell，只在完整包闭合且容纳后发布。池满整包回滚，
  不损伤既有同队或其他队列；无效首qid只drain，不访问非法队。首op/qid/tag
  拥有整包，masked尾可以提交最后一个保留word。POP由调用者选队，没有自动
  调度或公平性；held word仍归队列，只有输出握手才归还cell。展示的credit/
  queue计数是该token握手后的快照，不能在未握手时当成已释放。FLUSH仅回收
  选队全部已提交packet；reset丢弃全池所有旧队列并用CELLS周期重建free链。
  默认cell存储/queue元数据3008/104bit，最大26880/544bit，另计控制寄存器。
- 保序回归输入顺序就是caller提供的协变量顺序，不内部排序。严格正权，最大
  64项signed24值和unsigned16权。每个输出为最大常值块的未约分sum(w*x)/sum(w)
  及dense-kept start/length；相等均值也合并，所以块均值严格递增。无除法、舍入
  或近似误差。empty/超容/任意kept零权独立置位，零权谓词包含excess drain，
  拒绝整帧；错误count仍是前MAX_LEN个kept的诊断计数，其他block payload零。
  一个输入乘法器与共享串行比较乘积通路，最大交叉乘积69位；stack默认736/
  最大4864bit，没有引入未跟踪的fraction_compare。
- 区域图按固定WIDTH*HEIGHT握手计数，没有s_last；错误SOF/EOL不重定界，caller
  必须补足固定像素数或reset。正标签可断连但视作同一ID，0背景不建边，只计
  横/纵共享cell-side；a<b唯一、字典序输出，不返回孤立节点ID，但done_nodes含
  其数量。任意marker/range错误都在固定帧drain后拒绝整帧：零edge，四个数值
  DONE字段为零，保留首tag及两错误位。同pixel左方/上方若命中相同pair，严格
  先写后再读，保留两次计数。默认64x64/L4/K15，row+table逻辑RAM3406bit，
  最大95510bit。1024x1024最大几何仅语法编译；实仿含默认64²和1024长行/列。
- 最大流支持一般有向图、循环、双向容量和自环；重复pair采用**最后赋值覆盖**，
  含zero删除，不自动求平行边容量和。容量原值与CAP_W+1位残量共存，保留反向
  撤流空间；source预seen、FIFO BFS、ascending邻居及parent/bottleneck实现精确
  增广。输出N²个row-major pair，包括零容量；flow=max(capacity-residual,0)，
  取消对向抵消，满足容量与守恒。残量可达cut的出割容量等于总流。首terminal
  与32位edge ID在截断前检查，任一错误整帧只发一个canonical masked状态。
  不承诺最小费用或词典序最小解。最大总流520093665已实仿；默认/最大graph+
  scratch数组2296/51296bit。无外部graph RAM、变量乘变量或除法通路。

四核心均普通ready/valid、单时钟、同步高有效reset、无CE/CDC，连接旧CE-qualified
流需要明确adapter。所有有效结果含完整元数据在反压时保持。只有一个事务在途，
序列化RAM/算子牺牲持续速率；没有每时钟一个packet/pixel/拟合/图求解的声明。
四包风险均为默认LOW、最大MEDIUM，是结构判断，不是测得的PPA或器件适配。
状态为 **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**；最小例为语法证据支持
的 **INTEGRATION_CANDIDATE**。无综合、PnR、STA、上板或扩大回归，无实测
资源、频率或功耗结果，未迁移旧库历史硬件证据。

## 独立审查与有限证据边界

A审最大流、B审共享包队列、C审保序回归、root审区域图，冻结版均无剩余实质
问题。审查覆盖池partition及原子发布、held POP ownership、同步stack生命期、
有符号交叉乘比较、相等均值合并、两次同pair计数、首行旧RAM隔离、反向残量
宽度、流/割证书、错误drain和立即阶段复位。

队列oracle是独立packet列表，不模拟物理free链；TB另按canonical边界检查
queued/pending/free全池不重叠、内容、tail及count，包含4403次pending PUSH和
4844次held POP检查。保序oracle用Fraction max-min表征，KKT前缀及严格边界
条件补证，n<=5再穷举全部连续分区的精确loss，不镜像PAVA栈。共4361正常块，
其中2792未约分有理均值；8482是KKT条件数，不是帧数。

区域oracle以每个label的单位cell边界集合XOR后求不同label集合交集，不复写
left/up RAM递推；每个edge、DONE与明确的scan/输入/结果时序独立核验。自查
加强了实际held-edge复位目标和later-SOF fixture，相同八组有限检查复核通过，
生产RTL未变。共享包队列精确首/后继valid、保序1925次后继间隔也已检查。

最大流参考用独立push-relabel预流，不走RTL BFS增广路径；N<=8再穷举割。
发布矩阵另逐项验容量、对向抵消、所有顶点守恒，并从输出重建残量可达集合，
检查cut容量=oracle总流。反向重路由、双向最大容量及最大源出口总量均有fixture。
首valid用独立总流F得保守界，不能误称为精确周期断言。

合计382次立即阶段取消；所有目标在观察到边界后直接reset_now，没有额外
active edge。保序含second product中点、真实held normal/error与blocked offer，
队列含rollback/FLUSH/部分POP，区域含双contact更新和held DONE，最大流含
forward/reverse部分更新。取消后按各包文档核验恢复：队列检查重建credit及空
队列，另外三包以fresh singleton/empty检查；主fixture计数不含恢复事务。
服务周期的统计范围以各回执为准。这些是有限状态
探针和canonical边界检查，不是任意周期或全部参数的证明。

外源固定版本、实际hash和许可决策在各包SOURCES.md：verilog-axis为MIT，
SciPy、scikit-image及NetworkX为BSD-3-Clause。均只读比较实际源码及完整license，
未复制、翻译、执行或分发上游实现。保序预检识别到旧fraction_compare未跟踪，
保持原状且排除依赖，必要比较在新目录独立实现。新贡献按root LICENSE/NOTICE，
包队列另有独立Apache许可证。四新包无需sibling RTL或在线构建系统。

## 累计冻结与恢复

[B9清单](snapshots/source_20261104_b9.json)绑定 **336个包内文本文件与10个共享
支持文件**。B8旧32个package对象及support逐对象保留，四新包不增加外部支持
源。根LICENSE/NOTICE及旧backend说明/许可继续导出。只覆盖本轮持续开发中
审查的三十六项，不表示整个历史仓库或全部合法输入重新验收。

冻结检查提交 `5541db3fe1599c7bf5cf57ad5700e4b7b6403297` 通过：**36内核+
37示例，共73个top、79个唯一生产源文件**。只用清单所列提交字节构造隔离目录，
一次Icarus `-tnull` 编译成功；验证package/support hash、源证据绑定、有限记录、
离线路径闭包与module重名。没有重跑累计数值测试。实际输出直接保存于
[冻结记录](snapshots/source_20261104_b9_check.txt)，仍有20条已知timescale继承
警告，无其他诊断或错误；未为消警告改写旧无延时源码。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b9 --manifest docs/snapshots/source_20261104_b9.json --compile
```

最终发布提交只补本记录、实际检查输出与README入口，冻结源码/清单/检查器
保持不变。root仅暂存任务精确路径并串行提交，无push。原有未提交修改、删除
及其他未跟踪资产保留。Goal继续active，本批是持续开发的稳定检查点。

前批：[第一批](IP_ASSET_BATCH_20261104.md)、[第二批](IP_ASSET_BATCH_20261104_B2.md)、
[第三批](IP_ASSET_BATCH_20261104_B3.md)、[第四批](IP_ASSET_BATCH_20261104_B4.md)、
[第五批](IP_ASSET_BATCH_20261104_B5.md)、[第六批](IP_ASSET_BATCH_20261104_B6.md)、
[第七批](IP_ASSET_BATCH_20261104_B7.md)、[第八批](IP_ASSET_BATCH_20261104_B8.md)。
