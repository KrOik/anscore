# 2026-11-04 第十四批：三项有限仿真通过与一项语法候选

基线 `01b92bf2f8d81fff097f1965de61edf81604ae4f`，开发分支
`development/ip-assets-20261104`。本批保留此前26个稳定引用，新增本地
`stable/source-20261104-b14` 与 annotated tag `snapshot/source-20261104-b14`；无push。

| 功能包 | 新增能力 | 当前证据与边界 |
|---|---|---|
| [ram_fenwick_index](../cores/storage/ram_fenwick_index/README.md) | 持久化可更新bucket质量、精确范围和、按累计质量选择index | 5配置、7182主响应；643773次leaf及同量aggregate核对，99次立即reset与完整fresh恢复 |
| [binary_linear_recurrence](../cores/signal_processing/binary_linear_recurrence/README.md) | 从原始二进制观测推断最短有限线性递推及下一位 | 6配置、3027帧/26151输入；1519个合法系数向量、8347条递推方程，120次立即reset/fresh |
| [streaming_gldm](../cores/image_processing/streaming_gldm/README.md) | 双行缓存流式灰度依赖矩阵，逐中心统计阈值内局部相似邻居 | 9配置、2228帧/35152像素/68976稠密bin，2228次精确tail；133次立即reset/fresh |
| [weighted_interval_schedule](../cores/acceleration/weighted_interval_schedule/README.md) | 任意到达顺序的signed半开区间最大权重无冲突子集，确定性bitmap平局 | **仅LINT_PASS候选**。core/example语法通过；首N1数值子进程20秒TIMEOUT，零配置完成，其余数值/非法参数检查NOT_RUN |

三项UNIT_SIM_PASS包合计20组配置、70条当前合格工具记录，包含21项预期
非法参数拒绝（6/4/11），352次立即取消及完整fresh恢复。主通道另外只有
1条适用于当前core/example的合格语法记录；其旧TB编译和终止的vvp仍保留
在3条原尝试记录中，不能计为当前数值证据。累计源码包含55个具有明确
有限UNIT证据的包与1个仅LINT的候选；所有包均HW_UNVERIFIED。

## 超时、普通失败与验证范围

区间核首N1 vvp在20秒停止，未重试、缩小fixture或提高限时。静态检查发现
TB在复位释放后可能读取尚未更新的ready，已增加1ns驱动settle；修正后没有
运行数值检查。该诊断不能证明RTL功能正确。报告分别保留原attempted哈希、
当前包哈希及未变的三项syntax源哈希。README已将最大64项、reset矩阵及
八项参数拒绝全部明确为计划覆盖/NOT_RUN。

存储核初次普通失败为CLEAR响应的pre-edge采样上界少1拍；保留10条历史
记录及新旧TB/runner哈希，生产RTL、oracle、fixture和TEST_PLAN未变，修正
采样上界后完整原矩阵通过。图像核初次普通语法失败为保留字标识符，保留
2条历史记录与旧源哈希，精确重命名后完整原矩阵通过。两项均无超时。
递推核首轮原矩阵通过。合格完成后的修改仅是文档/哈希打包，无数值重跑。

GLDM最大128x128从工具前即为compile-only，数值NOT_RUN；最大实际数值面积
32x24，单轴128。B11面积开最大配置TIMEOUT/NOT_RUN、B12 GLRLM及B13 GLSZM
最大方形compile-only范围逐对象原样保留，未重跑旧矩阵。

## 实现、资源与独立参考

Fenwick核使用leaf及one-based聚合两同步RAM，SET替换单点、RANGE求两个
prefix差、SELECT二进制提升求首个prefix大于unsigned rank的位置。全32位
索引先检查后窄化，越界/rank>=total不改变数据。mutation在响应呈现前完成；
held响应期间没有并发命令。reset串行清空后才ready。N1..256包含非2幂，
质量1..32bit，精确总和不wrap。独立flat-list oracle直接slice求和、线性
查找rank，并在每主响应后核所有leaf/聚合区间。SELECT candidate>N分支在
固定配置动态命中0次，仅静态审查，文档明确披露。RAM默认2432/最大18432bit，
另scalar/read/output289/519bit；981条probe/setup/recovery命令另列。

递推核在线GF2 Berlekamp-Massey，用同步history RAM逐tap求discrepancy，
两个M+1位多项式仅做常量一位移位和XOR，复用读口求下一位。返回最短有限
order L与lag连接c0=1；系数在i>L为0，最高lag系数允许0。有限前缀可能有
多个最短解，契约不承诺唯一系数或上游位兼容。oracle以不同候选阶的GF2
线性系统证明最小阶，核每条方程和下一位；740个唯一解逐向量相等、779个
非唯一解核合法性，362个返回向量有零最高lag。空样本/overflow独立错误，
保留count/tag而order/poly/next清零。M1..256；history加两多项式194/770bit。
计入probe/setup/recovery的52319次discrepancy tap、7409次prediction tap、
15549 held、88192 blocked周期与main oracle数分开。最大实测tail1022周期。

GLDM保留MSB量化gray0，第一像素捕获unsigned alpha/tag。每center的dependence
为自身加8邻域内绝对gray差<=alpha的真实邻居数，边界裁剪，无传递连通或
ROI。输出全部gray×d1..9；固定N个输入的SOF/EOL错误独立drain，整矩阵
count清零。两行gray/valid RAM和六个window寄存器、8个小比较器、平衡popcount
与同步histogram RMW替代帧RAM。oracle直接枚举clipped坐标集合；78744次
line/window、35152次center/hist更新、186088个in-bound邻居及145864个相似
邻居逐帧核对。13/15个reset目标恢复完整亮角点/暗背景图，额外16378像素与
10224个dense记录分开。RAM1552/5140bit；精确tail默认176、全域最多656周期。

区间核原始item与endpoint-chain两同步RAM保持输入顺序，串行选最小finish
后扫描兼容前驱，优化总权重及最小原index bitmap。positive length保证前驱
finish严格更小；共同新增bit不改变前缀mask平局顺序。无排序网络或数据搬移。
空集合法，zero weight可全部不选；overflow/非法geometry任一错误整帧拒绝。
RAM1344/12672bit，scalar406/830bit；正常tail推导K(4K+2)+2，未获数值确认。
独立coordinate-event oracle及小域全subset核对仅是所提供测试设计。

四包均普通ready/valid、同步高有效reset、单时钟，无CE或CDC；旧CE流需要
adapter。source保持到接受，held全部输出字段稳定。无新外部RAM、厂商原语、
运行时乘除或未闭合sibling依赖。风险默认LOW/最大MEDIUM均为结构判断；未测
LUT/FF/BRAM、Fmax、功耗、器件适配或板级吞吐，没有继承旧硬件证据。

实际RTL前已阅读固定上游相关实现及完整许可证：AtCoder ac-library CC0、
mhostetter/galois MIT、PyRadiomics BSD3、TheAlgorithms/Python MIT；具体SHA、
文件hash、引用边界和semantic去重见各SOURCES.md。没有执行或引入上游源码，
新贡献用root Apache-2.0 LICENSE/NOTICE。全部源、example/files.f及测试仅需
离线Python标准库与已有Icarus。A审root、B审A、C审B、root审C；审查不重跑仿真。

## 累计冻结与恢复

[B14清单](snapshots/source_20261104_b14.json)逐对象继承旧52包、10个support
files及dependency commits，新增44个包内文件，累计543+10文件、56core+57example、
113tops、119个唯一生产源。区间候选显式required_status=LINT_PASS，并绑定
syntax_source_sha256、1条syntax检查、1条TIMEOUT记录及completed_profiles0；
其他包仍默认要求UNIT_SIM_PASS。检查器输出实际成熟度，不把候选标为单元通过。

最终冻结提交 `7d31e53c6b5600366c1b46f1ade8eb54e7343fb8`，实际输出见
[冻结检查记录](snapshots/source_20261104_b14_check.txt)。一次实际隔离Icarus
`-tnull`子进程通过113tops/119sources，继承的20条timescale警告与B13相同，
无其他编译诊断。没有数值矩阵重跑。首次清单预检查曾错误声明Fenwick报告
存在`prior_failed_attempts`字段；实际历史在两个已hash归档文件中。该次在
调用任何编译器前停止，完整输出保留在
[失败预检查](snapshots/source_20261104_b14_precheck_failed.txt)。只删除这项
不存在的字段规则后重新冻结；全部源码、报告、旧52对象和其他证据规则未变。

功能提交：Fenwick `5899fda`、递推 `b123dd3`、GLDM `fe0b909`、区间候选与
显式LINT证据门槛 `5e1a926`，完整ID在清单中。四组交叉审查均CLOSED PASS；
区间文档措辞修订只刷新文档hash，未重跑终止的数值检查。

独立发布审计CLOSED PASS：逐一核543+10个committed文件、44个新增文件的
功能提交归属、旧对象/依赖不变、证据规则与113/119闭包；确认55项有限UNIT
和1项LINT候选区分、失败预检查与一次实际编译记录。审计未重跑检查器、
编译器或数值测试。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b14 --manifest docs/snapshots/source_20261104_b14.json --compile
```

源码冻结后只提交本文、README入口及真实检查输出。所有原tracked修改/删除、
未跟踪资产、goal.txt和旧稳定引用受保护；不push。Goal继续active，此批为
持续开发检查点。

前批：[第十三批](IP_ASSET_BATCH_20261104_B13.md)。
