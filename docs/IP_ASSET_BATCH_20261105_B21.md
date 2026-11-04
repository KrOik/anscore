# 2026-11-05 第二十一批与累计八十四包源码快照

本批基线 `ed4eda4fe213da6f6fec793ef911daaabfeba2cc`，开发分支
`development/ip-assets-20261104`。本地稳定分支为
`stable/source-20261105-b21`，附注标签为 `snapshot/source-20261105-b21`。
此前40个稳定引用保持原样；无push。

| 功能包 | 新增能力 | 当前合格有限证据 |
|---|---|---|
| [ram_replay_window](../cores/storage/ram_replay_window/README.md) | 多上下文unsigned64非回绕序号滑窗，原子判重/标记、无修改探测及清空 | 5配置、9876主命令、283828完整context行核验、80立即reset及480完整fresh命令 |
| [congruence_merge](../cores/signal_processing/congruence_merge/README.md) | signed余数、非互素正模的精确同余合并，返回规范解及完整LCM周期 | 6配置、4707主事务、401747轨道证书、126立即reset及完整fresh |
| [grayscale_max_tree](../cores/image_processing/grayscale_max_tree/README.md) | 完整灰度上层连通分量层次、规范parent和精确区域area | 10配置、1680帧、17040输出记录、6098规范节点、443立即reset及完整fresh |
| [exact_weighted_set_cover](../cores/acceleration/exact_weighted_set_cover/README.md) | 任意目标列集合的全局最小权覆盖及完整确定性选择见证 | 6配置、8333事务/17029行、319084节点证书、72立即reset及完整fresh |

四包均有明确有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。合格原矩阵为
27组数值配置、111条工具记录（18/19/45/29），含28项预期参数拒绝
（6/4/10/8）。721组立即reset全部完成恢复，共1121个完整fresh事务；
滑窗每组为六条命令，其余每组一帧或事务。每个compiler/simulator子进程
硬限20秒。没有综合、PnR、STA、上板或扩展回归；示例只有语法/实例化证据。

## 实际功能、结构和独立证据

滑窗为每个context保存head与精确W位已见集合，支持MARK、PEEK、CLEAR_CTX、
CLEAR_ALL。序号采用普通unsigned64大小，允许0及最大值，不支持隐式回绕；
epoch切换需清空。年龄恰为W即过旧，前进gap>=W时舍弃全部旧位。完整32bit
context先验证再窄化，保留操作/索引错误优先级，PEEK从不修改。单packed同步
RAM加resettable ownership map隐藏未复位payload；成功MARK提交与结果出现
同edge。独立oracle保存实际整数集合，使用集合成员及区间删除，不模仿RTL
位图移位。9876个主首valid、RAM读写调度及全部结果逐项核对；53457次源保持、
30748次输出保持包含主流量、取消与恢复。最大64context/W256实际数值运行。

同余合并先用四次共享恢复取余归一化signed输入，再遍历模轨道
`x=r1+k*m`，第一次匹配给规范解，轨道返回起点给精确周期；不一致与两种零模
错误有独立状态。W1..16、TAG1..32，完整2W位解/周期。共享标量加/减/比较，
无乘法器、divider primitive或RAM。临时`r1+LCM`也不溢出2W。primary oracle
使用GCD及模逆闭式CRT，W<=3另逐整数枚举；RTL不使用这条求解路径。W1..3
穷举全部输入四元组，W16包含65535步轨道及超过2^31周期。4833个精确延迟
包含126个完整fresh，3076个匹配与51796个除法步均有证书；4701个真实下一
token持续到实际接受。六配置最大观察10/16/24/56/292/65604拍。

最大树对每个灰度阈值的上层连通集合建立规范层次，同级代表是该上层分量内
本级像素的最小栅格地址；同灰度像素可经更亮区域连通。根指向自身且area=N，
非规范像素area=0。支持4/8邻接、1..16宽高、1..8灰度位；无背景豁免或量化。
六个单端口同步RAM组织计数排序、逆序激活、路径折半、规范化及面积累积，
RAM不整体reset。完整帧marker错先drain再输出N条零payload错误记录，没有
提前泄漏。独立oracle逐阈值发现连通集合并查严格包含关系，认证每个阈值的
完整分区、parent及area，不复刻union-find。2x2穷举全部四灰度图，3x3穷举
全部二值图；16x16两种邻接均完成真实数值帧。629475次image、229706次hist、
151961次order、429958次z、192517次parent和139849次area同步读数据核验
包含取消及恢复。443完整fresh共28341像素；22个main/reset仿真标记及每组
精确reset-ID位图均核对。最大配置46个预定探针在首次HDL前按奇偶拆为23+23，
所有探针保留；10个main与12个reset子进程分别限20秒。

集合覆盖输入command目标和R个原始set mask/unsigned权重，输出全局最小
`(权重和,选择位图)`。零权、空set、重复set、空目标、无解均定义；早LAST和
最终缺LAST分别规范报错。同步行RAM加显式pending-exclude栈，include先DFS；
覆盖后立即结算不会错过更优零权平局，因为额外置位只增大位图。仅cost>best
剪枝，保留等成本搜索。primary oracle为独立可达覆盖集合DP，R<=6另直接
枚举子集；额外schedule证书核精确计数。R1/R2穷举所有row/weight/target位型，
R16实际遍历完整无剪枝树及全权重mandatory-all实例。155381个branch与pop
逐项配对，8333个精确首valid及16987个完整行RAM核验通过。源实际预放下一
command和row，860531/851841个blocked周期均核完整保持；72组reset覆盖全部
8状态、最大栈、部分载入和错误hold，并完成全R行fresh及最小位图见证。

| 逻辑声明预算 | 默认/最大RAM(bit) | 默认/最大scalar(bit) | 无外部等待的内部延迟界 |
|---|---:|---:|---|
| 滑窗 |2048/20480|390/848|成功MARK3拍，其他有效查询2拍，清空/拒绝0拍|
| 同余合并 |0/0|151/304|4W+5+n/gcd(m,n)，默认292/最大65604拍；零模0拍|
| 最大树 |3968/13056|203/272|默认17571；最大C4 257539/C8 491787拍|
| 集合覆盖 |504/1936|179/347|5I+3<=5*2^R-2，默认1278/最大327678拍；错误1拍|

这些是源级逻辑声明与周期预算，不是LUT/FF/BRAM测量。四包均单时钟、同步
高有效reset、普通ready/valid，无CE/CDC；源保持至接受或reset，held输出
全部稳定。reset在观察目标后、下一active edge前立即取消；所有完整fresh
均真实退休。外部等待可无界。具体端口、溢出证明、内存所有权、风险和限域
见各README；物理适配、内存推断、Fmax、功耗与硬件吞吐仍未验证。

## 来源与真实失败历史

四包均在RTL前做实际语义去重、固定上游完整相关源码及完整许可证只读检查。
参考为WireGuard/wireguard-go `b3bc704ef0ee21a36298601a9e1e5ff90377ac52`
的replay/replay.go与MIT LICENSE；SymPy
`b4ce69ad5d40e4e545614b6c76ca9b0be0b98f0b`的ntheory/modular.py及完整BSD3/
附加条款LICENSE；scikit-image `a160f384523ac70173d069954b7084bee79fb68e`
的max_tree.py、_max_tree.pyx及完整多许可证LICENSE.txt（相关文件BSD3）；
OR-Tools `0d60e8afe450ec817f510aae965ab8898310cb41`的set_covering3.py及完整
Apache-2.0 LICENSE。各SOURCES保留URL、原始字节数/SHA及能力差异。root另
独立全文读最大树上游，A另独立全文读集合覆盖上游。没有复制或执行上游代码，
没有引入外部RTL、库、ROM、peer或网络依赖。四个files.f及完整示例均离线闭合。

三次先前普通TB失败均非timeout，且不修改生产RTL：

1. 同余attempt00：`matches`是SV保留字，W1 TB compile普通FAIL；4实际/15NOT_RUN。
   原plan `d21778f725674aff06c2692635dfee8fd3dbaeaef02366d5b732d98026b66146`，
   原receipt `db39cdd21ec7ec634e2b4f8896ec21e0e6bcc4f974a1c12bd3e04d22028cc529`。
   完整标识符改名及append archive支持保留原全部刺激。
2. 同余attempt01：W2恢复输入a=-1,b=1,m=2,n=3，正确解1/周期6，旧TB期待5。
   7实际/12NOT_RUN；原plan `c59bab4aab73249c05a041dd93405e0e7c811569e784d4426cc15bbc1329fea2`，
   原receipt `31a8ea6e6442a28b9e2fe0d2e699dfc8fd8a3fef91af36a37e9aa6693fa380e3`。
   两个完整failure_archive按原SHA重构，六fixture/RTL/example跨三版逐字一致。
   REPAIR02.diff证明仅TB/解析期待两行5→1，驱动、21探针及等待时序未变；
   全126个fresh期待另经primary oracle交叉确认。root/C分别审过此证据链。
3. 最大树attempt01：1x7 reset完成全部45组后，末尾posedge-only状态统计
   漏记已在negedge观察后立即取消的Z_HALVE；9实际/36NOT_RUN。原plan
   `91b80b633f2b720951ba3e2353b19e20b4eefef84a412dbf6e008dcfcffed6b4`，原receipt
   `cb84f79562bac0c588d91c3ea7fa6abfa9cf734aecf859104d3e2c1e64de849d`。
   history/attempt_01.json保留19份完整原source/fixture、plan/receipt及NOT_RUN，
   SHA `fee4f726598346b78a58f94e5b95dd0893ab735447134cdd481face53f60f077`。
   仅TB在已有观察点记录state和精确target位图、runner显式repair gate及README
   chronology改变。没有新增edge、缩小检查、改oracle或再生fixture；全部10
   fixture、RTL/example、45children、443targets/fresh及20秒限制逐字段/字节相同。
   完整diff SHA `f104fc5cf3467af509d4002a5a35cec25e0a6cc40e04427a39426be1ca60f518`。

最终同刺激矩阵全部PASS后没有执行代码更改或重跑。同余、最大树、集合覆盖的最大
child分别为6.844秒、6.359秒、9.547秒；滑窗记录保留每child20秒限制。本批包内实际
执行为131条=111条当前合格原记录+20条旧实际记录（4+7+9）；归档里的原PASS或FAIL收据副本
不额外计执行，所有原FAIL与NOT_RUN保持原标签。没有超时重试、缩刺激或加时。

| 当前收据 | SHA256 |
|---|---|
| 滑窗 |`0914cbd4a16ff6aa912b1d33c016eeba541ad8714f86cf18a8d077931cdf0554`|
| 同余 |`3582da9cace4f41e93c477aab611d4509b833ba0eb08614592f49f48774ebe8e`|
| 最大树 |`5c109ee02e7449cef77a97f5b3d07737c10527fbe612a21d292f8871ed3f4707`|
| 集合覆盖 |`35863407c260c7598c97aef1268ddcb7e78280bbc7cdddc1cfdc00edba7a156c`|

B独立发布审计另发现集合覆盖README的最大scalar算术误记：正确公式
`4U+W+4D+4C+4R+T+7`在最大参数为347，原打印447。提交
`a2e9e0df83ef7c61a86e57ff42141107c245f235`仅修正文档与绑定元数据，并新增
history/qualification_001_docs.json，SHA
`9a1b2db6b54e73de47c8e22094b5c24683d497a197a7fd0cf683328a1274df31`。
原8份完整源码、原计划及首次PASS29条收据逐字保存；执行计划
`8cf273448f41710c9ee9b00b0837c81e4c3218346e0bf75aa4a535db77196759`，原收据
`f454363685d739e21d2ae2009f7b0986cddcfedcb47cdc414addddffa6a90826`。
当前计划SHA `655593f223380bea3db9ff3bb3d33f055f33c9c2dbb4efb8711ed97cd6d7fceb`。
所有RTL/TB/runner/example、输入/oracle哈希和原commands/profiles/totals不变，
未运行任何HDL或oracle。新增归档中的29条PASS副本不增加实际执行数。

## 冻结、发布与恢复

累计84包为83个有限UNIT包与1个继承LINT-only候选。B14 weighted_interval_schedule
仍首N1 vvp20秒TIMEOUT_NOT_RUN、零完成配置，其静态TB修复没有重跑。B11
grayscale_area_opening的64x64仿真终止超时、其余7/8配置证据不变；B12 GLRLM
128x128、B13 GLSZM32x32、B14 GLDM128x128、B15 NGTDM128x128及B16 Hausdorff
32x32最大配置的compile-only边界全部保留，不能从本次语法检查外推数值通过。

所有环形互审A→root、B→A、C→B、root→C均CLOSED PASS。四项功能提交按实际
顺序为集合覆盖 `d711a049310d6f415bbd3c29d7792a2806a80075`，滑窗
`1e47884ca174e5d6585dc0dd0e1523fbe064cb1a`，最大树
`85b25f677a4f1f49160252713e074697c1403050`，同余
`1a95fda84f875f4f74dc70a7414c64e9cbb9430a`。root只按精确路径串行暂存/提交。
未修改旧包或共享RTL。最大树归档diff唯一空context行保留标准unified-diff必需
空格前缀，其余文件通过普通whitespace检查，未为检查而篡改原证据。

[B21清单](snapshots/source_20261105_b21.json)完整继承B20全部80个package对象、
849包内文件、12支持及dependency map。新增101文件（11/56/23/11），其中
61当前文件、40归档证据文件；累计950包内+12支持=962冻结文件。84core+
85example共169tops，176个唯一生产源。检查器、默认UNIT门槛、继承显式
LINT-only规则及SECDED/divider/EDT来源提交不变。清单SHA256
`e208d8d1582d2a63e900ddffbfd18361dcbed4cac11f239b8928b805978ef3d6`。

初始源码冻结 `1cf1d31b308f89257d19176f01f832b2e981fd1b`，当时清单SHA
`bac5a4a6e431181cc484f561568a491e5bafa376e3a8d4693426bf590ceabb19`。
唯一一次隔离导出编译exit0，compiler child固定20秒，169tops/176sources通过。
原136行/86PASS输出SHA
`5af0c6d629b60518570351c91db8ad291955be423d4cceecb413f3b4ea87719e`。
25组timescale警告/source note与B20逐行完全相同，无新增诊断，stderr为空。

文档修正后的最终冻结为 `043557903afa0f882a5c303fdcf88dd52ca7da71`。仅再次执行
不带--compile的静态checker，85行/85PASS，stderr为空；未调用compiler、simulator
或oracle。原/最终清单的全部176生产源Git OID逐项相同，顶层与依赖完全相同。
最终962个文件的当前证据/离线闭包重新核验，不把文档修正冒充数值重跑。
[实际输出](snapshots/source_20261105_b21_check.txt)按执行顺序保留原136行并
直接追加85行真实静态stdout，共221行/171PASS。原前缀逐字保留，只有原编译
的50条继承诊断；仅CRLF→LF规范化。完整输出SHA256
`5d4893c2ba0f43c91e4e6d2e9e064f7f1cb57c91689522cf83d174af7ca61910`。

两条实际checker命令（只有第一条启动一个编译child）：

```text
python -B scripts/check_source_snapshot.py --ref 1cf1d31b308f89257d19176f01f832b2e981fd1b --manifest docs/snapshots/source_20261105_b21.json --compile
python -B scripts/check_source_snapshot.py --ref 043557903afa0f882a5c303fdcf88dd52ca7da71 --manifest docs/snapshots/source_20261105_b21.json
```

B最终独立发布审计CLOSED PASS，无剩余发现：962个Git blob逐内容SHA核对，
80个继承package对象及861个旧文件OID不变，176个生产源OID与原编译冻结
逐项相同；文档修正的原证据可完整重构，111条当前合格及20条旧实际记录
计数正确。当前README/本文链接、全部哈希、冻结引用和继承验证边界均核对。
独立审计capture SHA256
`a0ae4c23fcf0d5802a1d46d986cdb4a138619943d31887a6c1e0623882110795`。

A发布前独立保护审计CLOSED PASS：40旧refs逐raw object/type/peeled、原15项
tracked状态/binary diff、goal及完整原21000未跟踪路径双哈希均不变，暂存区空。
最终发布仅暂存本文、README入口与真实检查输出，建立新的本地稳定分支和
附注快照，无push。Goal继续active；本批是可恢复的本地检查点。

前批：[第二十批](IP_ASSET_BATCH_20261105_B20.md)。
