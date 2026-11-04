# 2026-11-05 第十五批与累计六十包源码快照

基线 `9716da0847c26f09f4a9b856a84fc330dfb26351`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b15`、annotated tag `snapshot/source-20261105-b15`；
此前28个稳定引用保持，无push。

| 功能包 | 独立新增能力 | 当前合格有限证据 |
|---|---|---|
| [block_intern_store](../cores/storage/block_intern_store/README.md) | 固定多字block按完整内容驻留、共享refcount、不可变READ与RELEASE | 5配置、3594主命令/4618响应token/58274次物理slot核对；97次立即reset及完整fresh恢复 |
| [kendall_tau_b](../cores/signal_processing/kendall_tau_b/README.md) | 原始signed配对点的精确Kendall τ-b代数表示与全部tie分类 | 6配置、3614帧/17367输入、396264次prefix pair核对、6223次main乘法步骤；120次立即reset/fresh |
| [streaming_ngtdm](../cores/image_processing/streaming_ngtdm/README.md) | 双行缓存计算逐gray邻域均值差的精确120倍累加 | 9配置、948帧/27472像素/3568稠密bin、948次精确tail；155次立即reset/fresh |
| [stable_preference_match](../cores/acceleration/stable_preference_match/README.md) | 两侧严格偏好的提议方最优稳定双射，返回双方rank与proposal数 | 6配置、1523事务/104590输入/5391输出、13577提议、8231拒绝证书；114次立即reset/fresh |

四包本轮均LINT_PASS/UNIT_SIM_PASS/HW_UNVERIFIED，共26组固定仿真配置、
93条当前合格工具记录，包含31项预期非法参数拒绝（10/6/11/4），486次立即
取消及完整fresh恢复。所有原定矩阵首轮通过，无工具失败、超时或fixture
缩减；合格完成后未重跑数值矩阵。示例只有语法/实例化证据。

累计60包中59包具有明确的有限UNIT证据，B14加权区间调度仍是仅LINT候选，
其首N1数值TIMEOUT_NOT_RUN与零完成配置保持，没有重试。B11灰度面积开最大
配置超时、B12 GLRLM/B13 GLSZM/B14 GLDM最大方形compile-only范围原样继承。
本批NGTDM最大128x128从工具前即固定为compile-only，数值NOT_RUN；最大实际
数值面积32x24，单轴128。稳定匹配N32、Kendall长度256与驻留32slot×16word
配置实际运行了各自限定数值矩阵，不能外推为全域或硬件验证。

## 语义、架构与验证边界

驻留核先完整收集WORDS数据，经同步RAM逐live slot/逐word比对完整bit。
匹配则增加该handle的refcount，满表也可去重；不匹配才复制到最低free slot。
refcount满则不变更，READ返回完整不可变block，RELEASE递减并在零时释放。
命令与data流分别握手，一条命令拥有计算和held输出；mutation在ACK呈现前
完成。全32位handle先验证后窄化；没有generation，已释放handle复用后不能
区分旧handle，调用方必须遵守引用所有权。reset/CLEAR串行清ref，不复位payload。
SLOTS1..32、WORDS1..16、DATA1..32、REF1..16；R16饱和边界未动态覆盖，明确
保持静态审查范围。独立content-keyed dictionary核响应和所有live物理内容。
6597次word比较、4678次payload写与110889非reset周期、62813命令blocked、
30550data blocked、28860held包含probe/setup/recovery；3594主命令和58274
slot核对单列，检查所有slot的ref、仅live slot的payload；另1166条setup/recovery
命令。逻辑数组2304/17408bit，scalar151/197。

Kendall核每接受一点与之前所有保留点同步串行比较，equality先于signed方向，
互斥计C、D、仅x tie、仅y tie、双tie。返回精确signed S=C-D及unsigned
R=(P-Tx_all)*(P-Ty_all)，表示τ-b=S/sqrt(R)，没有近似scalar、p值或τ-c承诺。
固定PW步shift-add求R，无sqrt/divider；常量x/y独立错误含不足两点，overflow
drain不能改变或修复已保留prefix。任错metrics全零，count/tag保留。最大P32640、
R1065369600，signed S16bit、R30bit安全。oracle按(x,y)排序、严格y逆序数及
边际/联合multiplicity choose2计算，不镜像RTL pair分类。1535合法帧含693正、
669负、173零，1181含tie；每配置全部8种错误。probe-inclusive scan466357、
乘法7138、held18484、blocked918876与main pair/mul数分开。最大实测tail527，
RAM1024/16384bit，scalar263/476。

NGTDM中心不参与邻域均值，clipped8邻域k仅为0/1/2/3/5/8，输出n[g]及
S120[g]=120Σ|g-mean(neighbors)|。gray0保留，1x1孤立中心不贡献count/difference，
与实际上游C孤立计数有意不同，无API兼容承诺。两行gray/valid RAM、balanced
sum/popcount、注册abs及常量120/k shift-add、packed histogram RMW，不需帧RAM。
固定N输入的SOF/EOL错误仍完整drain，再输出所有gray的零统计。Fraction oracle
直接枚举clipped坐标，核27472中心、27452有效更新、156392邻居、10386非整数
均值、13987非零delta。全部k分别命中20/160/5240/3392/4568/14092中心。
内部106509grid、58003center、57925update及12545held/349089blocked含恢复流量，
main单列。数值tail最大908，结构全域916/default244；RAM512/1940bit。

稳定匹配核输入固定2N²个32位partner，位置隐含side/agent/rank；每行必须完整
严格permutation。bad ID、duplicate、FIRST/LAST错误独立sticky，固定drain后
错误只发一个canonical masked状态，没有prefix匹配。两同步偏好RAM保留提议
顺序与接收方inverse rank，小表记录next-rank/mate/owner；串行选最低free提议方，
接收方只接受更优者。结束输出N个提议方有序配对及双方rank；提议方最优，
不承诺接收方也最优。空缺列表、tie与不同side容量不在该标准严格双射接口内。
独立验证先直接核双射与全部blocking pair，再逐拒绝证书归纳证明：winner比
当前receiver更喜欢的所有partner此前已被证明不可能，则loser与该receiver
也不可能出现在任何stable matching。最终每个更优partner均被排除，从而
证明proposer-optimal，无需重建DUT mate/free算法。另1422帧枚举全部双射的
stable解，29帧有多个stable解。精确tail Sscan+6P+2逐帧核验，六配置实测最大
9/25/52/147/422/14610；全域保守N²(N+6)+2最多38914。RAM384/10240bit，小表
80/512bit，其他scalar103/239bit。所有计数为main-only，reset fresh另列。

四包均普通ready/valid、单时钟、同步高有效reset，无CE或CDC；source保持到
接受，held全部字段稳定。旧CE流需adapter。reset在目标观察后不多走active
edge即取消，随后完整fresh恢复；有限probe不等于任意周期形式证明。无新
外部RAM、vendor primitive或未闭合sibling依赖。风险默认LOW/最大MEDIUM均为
结构判断；未测LUT/FF/BRAM/DSP、Fmax、功耗、器件适配或板级吞吐。

实际RTL前的上游源码与完整license预检分别为internment MIT OR Apache、
SciPy BSD3、PyRadiomics BSD3、TheAlgorithms/Python MIT；固定commit/文件hash、
actual body与license读取、语义去重和引用边界见各SOURCES.md。没有复制或运行
上游实现。新源码用root Apache-2.0 LICENSE/NOTICE，离线只需Python标准库及
已有Icarus/vvp。距离变换候选经实际旧RTL确认重复，已在RTL前放弃。

## 源码冻结和恢复

A审root、B审A、C审B、root审C均CLOSED PASS，无功能阻断。README结果描述与
报告hash在完成后刷新；驻留核另外增加本地LF `.gitattributes`，避免CRLF默认
Git设置改变文件。该三路径packaging修订独立审查通过，原RTL/TB/runner/plan/
oracle/vector/tool记录不变、未重跑数值。原tested哈希和current哈希分开保留。

[B15清单](snapshots/source_20261105_b15.json)逐对象继承B14旧56包、10个支持
文件及dependency commits，新增45个包内文件，累计588+10文件、60core+
61example、121tops及127个唯一生产源。B14仅LINT候选的显式证据规则原样保留，
其余包默认仍要求UNIT_SIM_PASS。检查器和全部旧包本轮未改动。

源码冻结提交 `670cb23082d6e8a3200e49a39aba93c92077604c`，实际输出见
[冻结检查记录](snapshots/source_20261105_b15_check.txt)。一次实际隔离Icarus
`-tnull`子进程通过121tops/127sources；20条既有timescale继承警告与B14逐行
相同，无其他编译诊断。没有重跑旧数值矩阵或终止的超时检查。

功能提交分别为驻留 `e577c25`（LF打包终态`9c57cfa`）、Kendall `0ead8ea`、
NGTDM `0d48347`、稳定匹配 `58b0fb3`，完整终态ID见清单feature_commit。

独立发布审计CLOSED PASS：逐一核588+10个committed文件、45个新增文件的
功能提交归属、全部旧对象/依赖/检查器不变、当前证据规则及121/127闭包，
复算26配置/93记录/31拒绝/486reset恢复并核59有限UNIT与1仅LINT的区别。
审计修订一处统计标签为“所有slot的ref、仅live payload”，未改源码或报告，
没有重跑检查器、编译器、oracle或仿真。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261105-b15 --manifest docs/snapshots/source_20261105_b15.json --compile
```

最终发布只提交本文、README入口及真实检查输出；精确路径暂存和串行提交，
不push。原15项tracked修改/删除、21000未跟踪路径、goal.txt及此前28个稳定
引用受保护。Goal继续active，此批为持续功能资产积累检查点。

前批：[第十四批](IP_ASSET_BATCH_20261104_B14.md)。
