# 2026-11-05 第十六批与累计六十四包源码快照

基线 `83b11ea30d4762c5893cf37a8303b11706321876`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b16`、注释标签 `snapshot/source-20261105-b16`；
此前30个稳定引用受保护，无push。

| 功能包 | 新增可复用能力 | 当前合格有限证据 |
|---|---|---|
| [transactional_scratchpad](../cores/storage/transactional_scratchpad/README.md) | 多上下文私有读写集、可重复读、依赖冲突检测及多字原子提交 | 5配置、4062主命令、136条串行提交证书；107次立即reset及完整fresh恢复 |
| [rational_polynomial_interpolate](../cores/signal_processing/rational_polynomial_interpolate/README.md) | 原始无序非均匀节点的精确有理多项式插值与外推 | 6配置、1388帧/3953输入、365287主乘法步骤；162次立即reset/fresh |
| [binary_hausdorff](../cores/image_processing/binary_hausdorff/README.md) | 双原始二值掩膜的精确对称Hausdorff平方距离及双向见证 | 9配置、508帧/10096配对像素、508次精确tail；179次立即reset/fresh |
| [longest_increasing_subsequence](../cores/acceleration/longest_increasing_subsequence/README.md) | 原始signed样本的严格LIS长度及带原始索引的前向最优子序列 | 6配置、689帧/11846输入/2935输出、10267前缀DAG核对、599穷举交叉检查；114次立即reset/fresh |

四包当前均LINT_PASS/UNIT_SIM_PASS/HW_UNVERIFIED，插值与Hausdorff另标
INTEGRATION_CANDIDATE。当前合格证据为26组固定仿真配置、90条工具记录，
含26项预期非法参数拒绝（8/6/6/6），562次立即取消及完整fresh恢复。
示例只有语法与实例化证据，未声称组合系统硬件验证。

本批没有超时、fixture缩减或限时放宽。LIS有两份显式历史记录：首次TB
编译exit0但缺少timescale警告导致资格检查失败，尚未运行仿真；补齐声明
后首次数值矩阵通过，随后独立审阅确认reset helper在目标观察后多等一个
active edge，不能证明声称的立即取消。原始通过收据、状态、哈希和完整
记录归档并标为需要重新资格检查；只修正TB复位调度，在同一冻结计划、
同一六组输入向量哈希、同一20秒子进程上限下重新检查，现已通过。
当前RTL/oracle/plan不变。包含历史共有115条包内实际工具记录，当前合格
90条与历史25条分开；当前合格后仅文档打包刷新，没有再次数值重跑。

累计64包中63包具有明确的有限UNIT证据。B14加权区间调度仍仅LINT，首N1
数值TIMEOUT_NOT_RUN、零完成配置保持，不重试；B11灰度面积开最大配置
超时及B12 GLRLM/B13 GLSZM/B14 GLDM/B15 NGTDM的最大方形compile-only
范围原样保留。本批Hausdorff最大32x32从工具前即固定compile-only，数值
NOT_RUN；实际最大数值面积16x12，另有单轴32。事务核8context×64word、
插值16bit/6节点、LIS32bit/256样本均运行各自有限数值矩阵，不外推为全域。

## 接口、架构与独立证据

事务存储提供BEGIN、READ、STAGE、COMMIT、ABORT、PEEK、CLEAR及非法opcode
拒绝。READ先返回自身私有写，再返回首次读取缓存，否则读取当前提交值并
建立依赖。别的成功提交若写到该依赖，即使同值或ABA也永久标记当前事务
冲突；之后READ/STAGE拒绝，COMMIT拒绝并关闭。盲写无读依赖，按提交次序
串行化。所有多字写及冲突传播在ACK前完成，期间不接新命令；reset取消
部分提交并串行清零全部存储和上下文。完整8bit context和32bit地址先验证
后窄化；上下文复用无generation，调用者拥有旧标识的生命周期。
独立oracle用无限精度逐地址提交epoch和私有dictionary，与RTL的冲突锁存/
扫描不同；每主ACK后累计核50640次已提交存储word、341216次事务word状态，另有
136条串行提交证书。117229非reset周期、42462blocked、26881held、424次
word应用及110次上下文失效含setup/recovery；2191条恢复命令单列。逻辑数组
4736/35840bit、上下文表28/72bit、scalar247/282bit；最大实测tail1218，
保守上界1219，均为默认/最大声明预算或有限行为数据，非综合结果。

插值核接收1..M个signed(x,y)节点，首次token采样signed query；要求x互异，
保留原始输入顺序，不需排序或预计算权重。结果是正分母、未约分的精确
signed numerator/denominator；外推和query恰落节点均合法。以Vandermonde
公共积构造各项，单个W步移位加法乘法器复用所有有符号因子，无除法或
浮点近似。W1..16、M2..6，最大分母240bit、分子260bit。空、重复x、overflow
独立语义与完整drain明确，reachable errors0/1/2/4/6全部覆盖。独立Fraction
oracle先解原始Vandermonde线性系统，再Horner求值，与DUT乘积展开不同；
正abs(V)公共分母另核。1036有效结果中415正、460负、161零，211为非整数，
716未约分、579 query落节点，427非均匀、529无序。主20267 pair factors、
10283 query factors、365287乘法步骤单列。最大tail按配置40/150/551/1353/
2805/145；总声明487/1877bit，其中样本RAM64/192bit。

Hausdorff对mask bit1组成的两点集计算h²(A,B)=max_A min_B距离平方及反向
值，再取较大者。最近目标和最远源均按最低raster index打破tie；相等双向
距离选A->B。返回两组真实源/目标见证，不计算sqrt、分位数或均值，也不做
平移搜索。空A/B和SOF/EOL为四个独立错误，固定N像素完整drain后距离/见证
全零，实际population与首tag保留。复用一个未改动的已有EDT：首次捕获B
并存2bit mask RAM，读B距离图归约A；再重放A，读A距离图归约B。child CE
固定1、reset转换，外部普通ready/valid，不混接CE握手。独立2D集合max-min
oracle核全部字段；TB还核每个选中与未选中的child map点及最近坐标。
342有效/166错误帧、主10224次map检查/5112次mask重放、566最近tie及194最远
tie；inclusive26098map/12887replay/4174selected/3131held/54blocked另列，
blocked均来自held normal/error复位探针。有效精确tail为4N(W+H+3)+2，默认
23810、全域最大274434；任错1。总RAM3072/19456bit，wrapper及child scalar
合计325/387bit。最大32方形数值仍NOT_RUN。

LIS对kept样本序号保留原始索引；masked token不占序号但参与首标志和tag
所有权。串行lower_bound寻找首个tail>=x，严格相等不能延长；历史前驱
指向更早索引，尾值替换不破坏已存链。反向追溯写入witness RAM，再前向
输出最优子序列；不承诺多解中的特定规范见证。FIRST错误和overflow独立
sticky，任错完整drain并只发canonical masked状态。独立oracle按index与
signed值构造DAG求最长路径，核每个已提交样本的ending/整体前缀长度；小
输入另穷举全部子序列，最终直接核最优长度、原始membership、索引与数值
严格递增。主31785次tail比较、126072周期、5146held、100044blocked；2876个
kept见证样本含1367负值，547有效帧必须取proper subsequence。六配置均达到
合法最大长度。三同步RAM共4224/30720bit，scalar226/390bit；always-ready
最终输入至最终输出传输保守339/1303周期，外部无界停顿无有限完成期限。

四包均单时钟、同步高有效reset、普通ready/valid、无外部CE/CDC。source
保持至接受，held输出全字段稳定；每条命令或数值帧拥有其计算与输出，事务
存储允许多个上下文在命令之间保留私有集，不覆盖待消费状态。立即复位探针
在目标观察后不再走active edge即取消，随后完整fresh
恢复；这是固定有限证据，不是任意周期形式证明。默认LOW/最大MEDIUM风险
均为结构判断，未测LUT/FF/BRAM/DSP、Fmax、功耗、板级吞吐或器件适配。

实际RTL之前已读固定上游源码和完整license：rust-stm MIT OR Apache2.0、
SciPy BSD3、TheAlgorithms/Python MIT；来源、文件和哈希、完整license读取
与独立实现边界见各SOURCES。语义去重已检查实际相邻模块行为；没有复制/
执行远程实现或安装脚本。离线采用root Apache LICENSE/NOTICE；A另保留包内
license。所有生产源码、必要依赖、参数及最小实例均在清单闭合。

## 冻结、发布与恢复

A审root（发现reset探针缺陷并在修正后reclose）、B审A、C审B、root审C均
CLOSED PASS。A的README、C的README/SOURCES、root最终README是文档结果刷新，
原tested/current哈希分开；B在首次合格检查后未改动。没有共享RTL或旧基础
模块改写。

[B16清单](snapshots/source_20261105_b16.json)逐对象继承B15全部60包、10个
支持文件和原dependency entries；新增44个包内文件，累计632+12文件、
64core+65example、129tops及136个唯一生产源。新增两个支持文件为未改动的
EDT源及README，固定本地来源提交`430d42049006976683550ecec321a724ef5cea3d`；
root LICENSE/NOTICE已有闭包，原SECDED/divider依赖记录不变。检查器未改动。

源码冻结提交`3c4c79b5043a9e66d502d67a217c4ee353e899a5`，实际输出见
[冻结检查记录](snapshots/source_20261105_b16_check.txt)。唯一一次隔离Icarus
`-tnull`通过129tops/136sources，未执行数值矩阵。21条timescale警告中20条
与B15逐行相同，另1条来自此次新增导出的原样EDT依赖；没有其他诊断。
清单SHA256 `bcdf7f99a95b98ce70f3d0afd3b6aa5acc4d195c3060d5969f92c6f6c2641e62`，
检查记录SHA256 `aea1826242b227afce025e519fc566469c9a6671ff3c984e4cca7f017dce5790`。

功能提交：事务`7e67fd7d4f445289bd19ff3956259c406da98992`；插值
`b6f31f65df0f4a0dadf4e411abd994ce69487b21`；Hausdorff
`41f75cf4d813bcbbd75e6d723383153e3e3b07ac`；LIS
`9b0c72047006e362363990f0490d2e3772980d8a`。完整终态ID也在清单中。

独立发布审计CLOSED PASS：逐一核644个冻结Git文件哈希、四个功能提交归属、
全部旧60包对象/588文件、旧10个支持文件及检查器不变；复算26配置/90当前
记录/26拒绝/562恢复，核根通道4+21历史记录与当前记录分开，累计63有限UNIT
和1仅LINT没有混淆。新增EDT支持及原依赖提交、129/136闭包、21条既知警告
范围、文档与README入口均已审阅。审计未重跑检查器、编译器、仿真或oracle。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261105-b16 --manifest docs/snapshots/source_20261105_b16.json --compile
```

最终发布只暂存本文、README入口及真实检查输出；串行提交，无push。原15项
tracked修改/删除、21000未跟踪路径、goal.txt、原30稳定引用受保护。Goal
继续active，本批是持续积累FPGA原生功能资产的本地检查点。

前批：[第十五批](IP_ASSET_BATCH_20261105_B15.md)。
