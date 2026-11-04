# 2026-11-05 第十八批与累计七十二包源码快照

基线 `eb16eee7848694a1a1cd50e567b5742352751c93`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b18`、注释标签 `snapshot/source-20261105-b18`；
此前34个稳定引用受保护，无push。

| 功能包 | 新增可复用能力 | 本批有限证据 |
|---|---|---|
| [ram_deadline_scheduler](../cores/storage/ram_deadline_scheduler/README.md) | 唯一ID的绝对deadline事件更新、取消、最早事件选择与到期领取 | 5配置、4504主命令、149976次slot图像核对、100次立即reset及400条完整fresh恢复命令 |
| [polynomial_real_root_count](../cores/signal_processing/polynomial_real_root_count/README.md) | 闭区间内一次至三次整数系数多项式的精确不同实根数量与端点根标记 | 6配置、3140主命令、23706次主乘法、210次立即reset及完整fresh恢复 |
| [minimum_enclosing_circle](../cores/image_processing/minimum_enclosing_circle/README.md) | 无序signed二维点集的精确有理最小包围圆与支撑点证书 | 5配置、529帧/2900输入、2489候选与6299次包含性核对、108次立即reset及完整fresh恢复 |
| [maximum_clique](../cores/acceleration/maximum_clique/README.md) | 原始无向边更新的精确最大团大小与完整顶点位图见证 | 6配置、349图/5914输入、67个全枚举小图、219次补图最小顶点覆盖交叉核对、96次立即reset及完整fresh恢复 |

四包均有明确的有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED；最小包围圆
另标INTEGRATION_CANDIDATE。22组固定数值配置、80条原始工具记录，含
26项预期非法参数拒绝（10/6/6/4），514组立即取消及完整fresh恢复。
各有限矩阵在首次HDL检查前冻结，全部首次执行通过，没有失败、超时或重跑。
每个compiler/simulator子进程上限20秒。最小示例只有语法及实例化证据；
没有综合、PnR、STA、上板或扩展回归。

## 接口、架构与独立证据

deadline调度器支持UPSERT、CANCEL、NEXT、TAKE、CLEAR和非法opcode
拒绝。UPSERT可在满表时替换同ID事件；选择顺序为(deadline,unsigned ID)，
TAKE只在最早deadline小于等于命令捕获的cutoff时删除并返回事件。时间为
无符号绝对值，不作模回绕排序，没有自主计时器、驱逐或generation；调用者
管理ID生命周期和时间epoch。SLOTS1..128，ID1..32、TIME1..64、DATA1..64、
TAG1..32；默认16/16/32/32/8。同步packed live/id/deadline/payload RAM串行
读取、消费并共享比较器，reset串行清除。独立Python字典/min oracle，另核
完整slot图像和ID唯一性。4504主命令全部实际接受并核精确首valid延迟，
323342次合规主source保持；包含恢复的trace共436385非reset周期、196083
次读取、2683次mutation写和5479次初始化写。100次reset后各完成四条新
命令，额外30个blocked探针周期由reset取消。成功mutation为2N+2拍，其余
扫描2N+1拍，CLEAR为N拍，bad-op为0；五配置N1/3/7/16/128分别达到
4/8/16/34/258拍。默认/最大RAM1296/20608bit、scalar393/781bit。

实根计数器接收单命令，输出闭signed整数区间中的不同实根数0..3及上下
端点是否为根。重根只计一次，重合端点若为根也只计一次；非零常数返回0，
零多项式拒绝。runtime degree0..MAX_DEG，MAX_DEG1..3、W1..16、TAG1..32；
高于实际degree的系数忽略。按degree、反向区间、零leading的顺序判错。
平方自由二次/三次使用闭式Sturm符号，重根用精确有理分支；不输出近似
根坐标。共享EW=5W+7的signed-magnitude移位加法乘法器，无数据乘除模
运算符、RAM或外部算术依赖。独立Fraction多项式square-free gcd及
Möbius/Descartes区间隔离oracle，与DUT闭式符号法分离。3140主命令中
2338成功、802错误；成功根数0/1/2/3为1385/796/141/16。主流程23706次
乘法和1481452次移位步骤，3134次真实排队下一命令接受；210次reset后
均完成解析可知的新事务。17个FSM状态及合法的op0..12均被观察。
六配置覆盖W1/3/4/8/8/16、degree上限1/1/2/2/3/3，最大参数已数值检查。
持久状态16EW+2W+TAG+clog2(EW)+46，默认828、最大1509bit；首valid界
22EW+100，默认1134、最大2014拍，实际最大1985拍。最大子进程4.672秒。

最小包围圆接收带KEEP的无序signed二维点列，返回正分母有理圆心、
radius_sq numerator/denominator²及确定性的1/2/3个支撑点索引。W2..12、
MAX_POINTS1..8、TAG1..32，默认8/8/8；重复点保留输入ordinal。masked
首token仍拥有tag，LAST封帧，计数饱和；empty=1、overflow=2时几何输出
规范化为零，保留的exhaustion=3按支撑圆定理不可达。依次测试点0单点、
字典序直径对、非共线非钝角三点。圆心在支撑集凸包中且包含所有点即为
最优证书；右角、钝角和共线情形由较早的直径对处理。单个MW=3W+5
移位加法乘法器与同步packed点RAM，无RAM reset、平行候选阵列或浮点。
独立递归Fraction/Welzl边界集oracle以Gaussian平分线求解圆；候选扫描
仅为次级编码与工作量证书，必须匹配独立最优值。514有效、6empty、9
overflow；有效支撑53单点/371点对/90三角，318个有理非整数圆心和318个
有理非整数radius²。616956次主移位步骤、13766次RAM读取、31740次signed
乘积及1925次采集II1核对。108次reset恢复完整，另有5次真实排队singleton
接受；held2515、blocked65周期的source均保持到接受或reset取消。
差分/叉积/圆心及平方范围证明在包内，完整乘积RW=2MW。默认/最大RAM
128/192bit、scalar1091/1548bit，总1219/1740bit。保守tail界为
2+C*(8+(16+4n)*(MW+2)+3n)，C至多85；默认129202、最大178162拍。
五配置观察最大延迟61/2010/14639/15027/27657拍。

最大团核接收原始无向边赋值及删除，固定顶点集包含孤立点；无边图最优
大小为1。N1..16、TAG1..32，默认8/8。32bit端点先完整验证后窄化，重复
边最后对称赋值生效，合法self-loop忽略。FIRST必须只在第一条接受token
出现，LAST封帧，masked首token拥有tag；错误bit0为端点、bit1为FIRST，
完整drain后返回canonical零mask/size。低候选优先DFS、递增选点，以
depth+popcount(candidate)<=best剪枝；输出精确最大基数及完整Nbit见证，
不承诺多个最优解间的全局tie顺序。单同步邻接RAM及同步parent-stack
RAM，边更新四拍串行RMW，无平行reset树。独立oracle穷举顶点子集并核
成对邻接，区别于DUT DFS；N<=4全部67张简单图和219次补图最小覆盖交叉
核对。295有效、54错误，四种错误值计数295/18/12/24；175个多最优解、
200个proper clique。2565次push与pop逐项配对，5425次SEARCH不变量、
22982次候选成员关系及788个见证顶点核对。349次精确首valid、321个held
和37520次合规主blocked/source保持检查，96次立即reset后完成fresh star。
六配置N1/2/4/6/8/16均用完整图达到合法最深栈；观察最大延迟
8/18/36/54/108/900拍。RAM3N²为192/768bit，scalar6N+3IW+2CW+TAG+9
为82/159bit。精确tail为2+6R+4E，其中R为chosen branch数，E为真实边
tail指示；保守界6*2^N，默认1536、最大393216拍，指数服务成本明确封顶。

四包均单时钟、同步高有效reset、普通ready/valid，无外部CE或CDC。
source保持至接受或reset，held输出及元数据稳定；立即reset探针观察目标
后不再经历额外active edge即断言，并完成新事务。源间隔与sink反压可以
无界，计算周期界不构成系统无条件截止时间，有限探针也不等于形式证明。
实根计数器资源风险定性LOW，其余默认LOW/最大MEDIUM；宽比较路径、
寄存器reset、RAM映射和指数/候选搜索成本均需使用者评估。这些是逻辑
预算和结构判断，LUT/FF/BRAM/DSP、Fmax、功耗及板级吞吐均未测量。

## 来源、冻结矩阵与元数据时间顺序

实际RTL之前已完成相邻能力语义去重，并读取固定上游源码及完整许可证：

| 包 | 固定技术参考 | 实际读取范围与许可证 |
|---|---|---|
| deadline | Tokio `695a07dd5e5baae82eb8b6931afa61029cd9b854` | 完整timer wheel mod.rs，MIT LICENSE全文 |
| real root | SymPy1.14.0 `fe935ceb303891d1f8bea4c03b19fd9ec9464b02` | rootisolation.py及完整LICENSE与notice |
| circle | Nayuki `9991ad3d402b98b8e377af1a2789b4a4b000ccfa` | smallestenclosingcircle.py、完整GPL3 COPYING与LGPL3 COPYING.LESSER，截断间隙另读补齐 |
| clique | NetworkX3.5 `4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4` | clique.py中完整find_cliques实现，BSD3 LICENSE全文 |

具体URL、文件和原始SHA256见各包SOURCES。均为独立本地实现，没有复制
或改编上述实现、引入其license文本或运行上游脚本；本地原创许可为Apache。
生产闭包无新sibling依赖、ROM、生成表或网络需求，root LICENSE/NOTICE在
12个支持文件中，deadline另带本地LICENSE。四core files.f及四个最小实例
完整；deadline和circle另有example/files.f，另外两包由清单明确列出example。

circle在首次HDL工具之前，root静态预审识别到B17已知的Icarus $fscanf
动态memory lvalue可移植性问题；C将读取改为scalar临时变量，冻结计划与
向量未变。该修改没有产生失败工具记录或失败历史。首次合格后，deadline、
circle及clique只刷新README实测结果，tested/current哈希及原收据恢复信息
均保留，没有重跑矩阵。

real-root合格后仅更正文档与证据元数据：SOURCES中既有相邻包名从
rational_polynomial_interpolation改为实际rational_polynomial_interpolate；
当前TEST_PLAN更新该来源文件哈希并注明文档修正。原执行计划SHA256
`3444e479fe1967754c86a890b03b525d41b4b3d7aa4bc948fd02dd9585b6ce8f`、原
收据SHA256 `fbfa11f12b084660e74dd8e52956e83ee6d5a8fa565695169a52c7460bd641f4`
和原SOURCES全文逐字嵌入当前收据；当前元数据计划SHA256
`ba6fdc909d6e711cbf8d1d09948bfdb4a13a79bf4f415d422d262321c9c23091`。
两计划只在source_hashes和明确的文档修正注释不同，矩阵、配置及fixtures
一致。为未改动的共享检查器补充canonical source_sha256别名，15个当前
非收据文件哈希与清单一致；保留原字段和历史恢复链，没有新工具执行。
嵌入的21条原工具记录与当前records完全相同，是同次执行的副本，不能
重复计数为额外21次。实际原始执行始终为A21+B21+C19+root19=80条。

| 当前收据 | SHA256 |
|---|---|
| deadline verification.json | `5244b6b8fcaf2a4e7118f709d7e385e1c87cfcf2ecf4a37bb6ff62d54cafc59d` |
| real-root verification.json | `8a9a3a85106ab35677fd2ad2453756befb60bbfc75743d890d3c6d6d2f62a164` |
| circle verification.json | `dcb865688c6dc5fed6226b3662f279296fc913a4dd4d2f63a452e7a7001f4a3b` |
| clique verification.json | `fc5bd1e96b650ff2eb57f90ce0df9e311abaa71f42a88c7b93aa27f6c91ad114` |

## 冻结、发布与恢复

累计72包中71包有明确有限UNIT证据。B14 weighted_interval_schedule仍仅
LINT_PASS，首N1仿真20秒终止，数值TIMEOUT_NOT_RUN、零完成配置及后续
NOT_RUN不变；静态TB修复未重跑。B11面积开仅7/8配置完成数值检查，
64x64编译通过但数值终止超时；B12 GLRLM128x128、B13 GLSZM32x32、B14
GLDM128x128、B15 NGTDM128x128及B16 Hausdorff32x32仍为compile-only。
保留全部历史，不以本次冻结语法检查扩大这些数值证据。

A审root、B审A、C审B、root审C，均CLOSED PASS。没有修改共享RTL或旧
基础模块。四个功能提交分别为：deadline
`698d556e737fc5915db5915a6fc23e6fabbd51f4`；real-root
`eda95786df525391c27adc8472a6140dc80ad815`；circle
`38c2065fb16b68b852791aaead423b44d50fa725`；clique
`7bd303096691d9cfff1a26b3c71cdc08aa9866e4`。

[B18清单](snapshots/source_20261105_b18.json)逐对象继承B17全部68包、
688个包内文件、12个支持文件及原dependency map。新增49个包内文件
（12/16/11/10），累计737个包内文件+12支持文件，共749个冻结文件。
72core+73example共145tops、152个唯一生产源。原SECDED、divider及EDT
支持提交不变，检查器未改，默认UNIT要求及既有显式LINT-only规则不变。

源码冻结提交`0e5b5c3fe1de210a8106dea43b2fe71a29a58b5f`，实际输出见
[冻结检查记录](snapshots/source_20261105_b18_check.txt)。仅运行一次隔离
committed-export检查，exit0，Icarus -tnull通过145tops/152sources，编译
子进程上限20秒；未重跑数值矩阵。实际23组timescale警告及来源行中，
前21组与B17逐行一致，另有两条：

- `polynomial_real_root_count/rtl/polynomial_real_root_count.sv:3`
- `polynomial_real_root_count/example/polynomial_real_root_count_example.sv:3`

两文件均继承`cores/storage/ram_deadline_scheduler/example/deadline16.sv:2`
的timescale，是无delay生产RTL缺少本地timescale时的警告；没有其他诊断。
保留真实输出与哈希，不补指令或重跑。保存输出只做CRLF至LF规范化。
清单SHA256 `4973aa8a4941b385d2b45e0a96f0e938bcc65dcd6b923d608620c4a13298d31a`；
检查记录SHA256 `ae3f2bf5ad6fd86af2aaf22b26e0324833c07e172bf85bea44b78664ebe32fb5`。

独立发布审计CLOSED PASS：只读核对全部749个冻结Git文件、B17全部68个
包对象和688个包内blob、12个支持文件、dependency map及未改动的检查器，
四项功能提交归属与冻结对象精确匹配。复算22配置/80唯一原始记录/26拒绝/
514恢复组，确认real-root嵌入的21条记录只是副本，原执行计划、收据和
SOURCES字节及元数据修正时间链完整。71有限UNIT与1仅LINT、历史超时与
compile-only边界分开保留。实际输出、两份SHA、23组警告、全部文档链接、
四份收据及功能提交SHA、README和本文均与证据一致。
审计未修改文件或重跑checker、compiler、simulator、oracle及资格矩阵。

实际唯一执行命令：

```text
python -B scripts/check_source_snapshot.py --ref 0e5b5c3fe1de210a8106dea43b2fe71a29a58b5f --manifest docs/snapshots/source_20261105_b18.json --compile
```

最终发布只暂存本文、README入口和真实检查输出，串行提交，无push。
原15项tracked修改/删除、21000未跟踪路径、goal.txt及原34个稳定引用受
保护。Goal继续active，本批是持续积累FPGA原生功能资产的本地检查点。

前批：[第十七批](IP_ASSET_BATCH_20261105_B17.md)。
