# 2026-11-05 第十七批与累计六十八包源码快照

基线 `c4be2839103480e23976f16f8a41d06fd93057c8`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b17`、注释标签 `snapshot/source-20261105-b17`；
此前32个稳定引用受保护，无push。

| 功能包 | 新增可复用能力 | 当前合格有限证据 |
|---|---|---|
| [extent_pool_allocator](../cores/storage/extent_pool_allocator/README.md) | 任意整数长度的连续地址池分配、起点对齐、完整extent精确释放与碎片摘要 | 5配置、4684主命令、284352次metadata核对、681671次合规source保持；80次立即reset及320条fresh恢复命令 |
| [integer_polynomial_resultant](../cores/signal_processing/integer_polynomial_resultant/README.md) | 原始整数系数多项式的精确signed结式与公共根判定 | 6配置、1438帧/3353输入、22109个行列式项；174次立即reset/fresh |
| [polyline_frechet](../cores/image_processing/polyline_frechet/README.md) | 两条有序signed二维折线的精确离散Fréchet平方距离与完整逆序最优耦合 | 6配置、666帧/3248输入/2083输出、12132个DP格；119次立即reset/fresh |
| [signed_sssp](../cores/acceleration/signed_sssp/README.md) | 原始signed有向边的单源最短距离，区分不可达、有限和负无穷 | 6配置、451图/3565输入/1832输出、353次独立穷举交叉核对；131次立即reset/fresh |

四包当前均LINT_PASS/UNIT_SIM_PASS/HW_UNVERIFIED，结式与Fréchet另标
INTEGRATION_CANDIDATE。当前合格证据为23组固定数值配置、78条工具记录，
含22项预期非法参数拒绝（4/6/6/6），504次立即取消及完整fresh恢复。
最小示例只有语法与实例化证据。所有compiler/simulator子进程上限20秒，
没有综合、PnR、STA、上板、扩展回归或本批超时。

## 保留的修正与历史

分配器首次15条工具记录原样归档，独立审阅发现TB在blocked时提供dummy
source，随后未握手也未reset便撤回valid，不能支持合规source覆盖声明。
原始收据、原始状态和10份当时源码完整保存在
`history/qualification_001_source_protocol`，并明确标记资格已被替代。
只修正TB调度，改为提前提供真实的下一条冻结主命令，保持全部字段直至
其接受；加入保持及精确接受次数核对。生产RTL、oracle、runner、计划、
五组输入及输出图像哈希、4684主命令和20秒上限不变；同一15条矩阵重新
资格检查通过。包内LF策略原先遗漏，审阅后补齐，README明确其晚于首次
检查的时间顺序，没有声称从创建起就存在本地attributes。

Fréchet首次5条工具记录中，singleton仿真exit1：Icarus不接受$fscanf的
动态memory元素实参，RTL尚未得到数值验证，完成配置为零。只将TB解析
改为scalar临时变量，同一冻结计划、fixture哈希、RTL、runner及21条矩阵
检查通过。完整失败记录嵌入收据。随后root复核把原有scalar公式的默认
算术结果修正为402bit、默认总量2082bit；最大771/7459bit未变，仅文档与
证据元数据刷新，没有再次运行数值工具。

本批实际历史共98条包内工具记录，分为78条当前合格记录、15条分配器
已替代资格记录和5条Fréchet失败记录。没有隐藏历史、缩减fixture或提高
时限。合格后A、C及root只更新文档结果，tested/current哈希保留差异；
结式首次合格后未修改。没有为了发布而重跑任何包的数值矩阵。

## 接口、架构与独立证据

分配器支持ALLOCATE、精确RELEASE、QUERY、CLEAR和非法opcode拒绝。
长度不按alignment或二次幂向上取整；起点按2^order对齐，选择最低可用
地址，padding仍可再分配。释放必须匹配完整live base/length，禁止局部、
合并、重复和超范围释放；32bit输入先验证后窄化，base+length采用33bit。
返回命令完成后的free总数和最长连续空隙；无generation，调用者管理
旧标识生命周期。同步packed busy/head-length RAM串行扫描、写入和摘要，
无payload存储或组合全阵列读取。独立oracle维护已分配几何区间并求补集
间隙，另核每个unit的busy/head-length。116次非二次幂长度、434次非零
base分配；当前778771个非reset周期、20106个held周期。默认/最大metadata
512/2560bit，scalar170/218bit；响应有效保守界5N+8，默认328、最大1288。
reset取消部分写入并串行清除全部所有权，随后完整allocate/query/release/
query恢复；CLEAR不清payload。

结式核接收ascending整数系数，首次beat采样两个degree与tag，LAST封帧。
W1..16、最大degree1..3，runtime degree可为0，三bit degree端口先验证；
要求精确长度和非零最高系数。状态依次判bad degree、长度错误、零leading，
错误返回canonical零结式。两个非零常数的空行列式为1。以Sylvester
行列式和Heap排列计算N!项，复用一个W步移位加法乘法器，不用变量除法。
N最大6，阶乘服务成本明确。独立Fraction多项式Euclidean递推oracle，
Gaussian消元和交换符号恒等式另核；TB独立Lehmer rank与inversion parity
核全部排列无重漏。939个有效结果中502正、282负、155零/公共根；状态
0/1/2/3分别939/12/18/469。110507个factor、1215922主乘法步骤，六次真实
排队下一帧接受检查。结果宽默认38/最大107bit，声明总存储321/815bit，
完整quadratic默认保守tail1203、最大cubic/W16为87843周期。

Fréchet接收两个有独立KEEP的有序signed二维点列，共用LAST和首次tag；
空A/B和overflow A/B错误独立，9种可达组合均覆盖。错误输出距离、索引
和坐标规范化为零，饱和count和tag保留。W2..24、每列最大点数1..32。
滚动DP行、单个复用X/Y平方引擎和2bit predecessor RAM计算精确平方距离，
输出从末端到原点的完整单调最优耦合。相同最小前驱按diag/up/left优先，
不承诺全局字典序或最短见证长度。独立heap minimax图搜索与threshold BFS
上下界证书核最优值，并重建所有cell分数和确定性前驱路径。618有效/48
错误帧，152次与无序Hausdorff结果有差异、7968个前驱tie、422860主平方
步骤和2035次采集II1核对。最大24bit/32点已运行有限数值配置。每格tail
为2W+4，总tail为3+nA*nB*(2W+4)，默认7171/最大53251，错误1；输出II3。
RAM1680/6688bit，scalar402/771bit，总2082/7459bit。blocked source探针
均由reset取消，69周期单列；4600个held周期包含主与fresh事务。

有符号SSSP接受有向边更新，重复边最后赋值生效，可显式删除；源点和端点
均完整32bit验证，首token即使masked也拥有source/tag。FIRST、bad source、
bad endpoint三错误位全部8组合覆盖，错误完整drain后返回单条canonical
masked记录。正确图按顶点顺序输出不可达、精确有限或负无穷；只有从源
可达的负环及其下游标负无穷，不可达负环不污染结果。不输出parent/path。
N1..32、W1..16、tag1..32。双同步距离bank保留D_k的至多k边结果，按Jacobi
Bellman-Ford松弛，固定点可提前结束；第N轮改善播种，保留D_(N-1)并做
至多N-1轮单调传播。独立Floyd-Warshall和负对角可达性oracle，小图另以
简单路径及cycle穷举交叉核对，枚举235个负cycle。主结果607有限、553
不可达、624负无穷；154个负有限距离、95个正有限距离，183图存在可达
负环，其中65个有限顶点不受影响。579678次松弛、36562次传播、1351775
主周期；131次立即reset/fresh，451次精确首valid检查，六配置各有一图
达到完整K=N/P=N-1工作界。always-ready最终传输延迟为
4N+K*(N*(2N+3)+1)+P*(2N*N+1)，默认上界2159、最大132287；首valid提前
3N-2周期。RAM784/18880bit、scalar139/281bit，串行初始化避免阵列reset树。

四包均单时钟、同步高有效reset、普通ready/valid、无外部CE或CDC。
source保持到接受，held输出字段稳定；reset在目标观察后不再经历额外
active edge即断言，取消后完成新事务。源间隔和sink反压可无界，不能把
always-ready计算界当成系统无条件截止时间。有限探针不等于任意周期形式
证明。默认LOW/最大MEDIUM为结构风险判断；RAM推断、LUT/FF/BRAM/DSP、
Fmax、功耗、器件适配及板级吞吐均未测量。

实际RTL之前已读固定上游源码和完整license：rust-osdev/linked-list-allocator
`a1d90498ff82872c5eb89edef77a08b25b4f14c4`的hole/lib与MIT、Apache全文；
SymPy `fe935ceb303891d1f8bea4c03b19fd9ec9464b02`的euclidtools相关完整函数
与完整license；Boost.Geometry `f82eb32da79641697583a43be9988d7517d8553c`
的完整discrete_frechet_distance.hpp与BSL1.0全文；TheAlgorithms/Python
`574d100b7181956e9c8384552fd078165e4cc326`的bellman_ford.py与MIT全文。
各SOURCES记录具体文件、原始读取哈希及独立实现边界。已核实际相邻包的
语义去重，没有复制上游实现或运行外部脚本。生产闭包无新增sibling依赖、
ROM、生成表或网络需求；root Apache LICENSE/NOTICE已在支持清单，A另有
本地LICENSE。所有core均有明确files.f、参数和最小实例。

## 冻结、发布与恢复

累计68包中67包有明确有限UNIT证据。B14 weighted_interval_schedule仍仅
LINT_PASS，首N1仿真20秒终止，数值TIMEOUT_NOT_RUN、零完成配置及后续
NOT_RUN不变，不重试。B11面积开64x64数值超时、B12 GLRLM128x128、B13
GLSZM32x32、B14 GLDM128x128、B15 NGTDM128x128及B16 Hausdorff32x32
最大配置compile-only范围均原样保留，不将本次语法检查扩写为数值通过。

A审root、B审A（source协议与LF修正后reclose）、C审B、root审C（预算
算术修正后reclose），均CLOSED PASS。没有改动共享RTL或旧基础模块。

[B17清单](snapshots/source_20261105_b17.json)逐对象继承B16全部64包、12个
支持文件及原dependency map。新增56个包内文件，其中44个当前文件、
12个A历史文件；累计688个包内文件+12支持文件，共700个冻结文件。
68core+69example共137tops、144个唯一生产源；历史RTL仅归档，不进入生产
files.f。原EDT、SECDED及divider支持文件和固定来源提交不变，检查器未改。

源码冻结提交`51d677482dc0573ba6311d8854d6b207f16b84dd`，实际输出见
[冻结检查记录](snapshots/source_20261105_b17_check.txt)。唯一一次隔离Icarus
-tnull检查通过137tops/144sources，子进程上限20秒；没有运行数值矩阵。
21条timescale警告及其来源行与B16逐行相同，没有其他诊断。保存输出只做
CRLF至LF规范化。清单SHA256
`bd18c0454f00865a59fee560f895d9da526d72ae271fd4818bbce2bb7f5ba8d5`，检查
记录SHA256 `7bad86b84abb6ad86ac25975cc830c14baad4ea6e0455a64414fe703a2cc8961`。

功能提交：分配器`bc08b764f134b6b751048bd2b8483c5700c30620`；结式
`5442714d418c66f0fd74fed42dc18646380bae2c`；Fréchet
`f9fad1e2765f2222cf13cf2df4df3cdc5ec62a78`；有符号SSSP
`6ec3121d5ac90d3c16eefeb4c9bb0f7e646440ff`。完整ID与当前证据规则在清单内。

独立发布审计CLOSED PASS：只读核对全部700个冻结Git文件、B16全部64个
包对象和632个包内blob、12个支持文件、dependency map及未改动的检查器，
四项功能提交归属与生产闭包正确。复算23配置/78当前记录/22拒绝/504恢复，
确认15条已替代资格与5条失败历史完整保留，67有限UNIT与1仅LINT分开。
检查输出、两份SHA、21组既有警告、README及本文与实际证据一致。
审计没有重跑checker、compiler、simulator或oracle。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261105-b17 --manifest docs/snapshots/source_20261105_b17.json --compile
```

最终发布只暂存本文、README入口和真实检查输出，串行提交，无push。
原15项tracked修改/删除、21000未跟踪路径、goal.txt及原32个稳定引用受
保护。Goal继续active，本批是持续积累FPGA原生功能资产的本地检查点。

前批：[第十六批](IP_ASSET_BATCH_20261105_B16.md)。
