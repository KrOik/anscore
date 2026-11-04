# 2026-11-05 第十九批与累计七十六包源码快照

基线 `897cf84f5861f5fada3c1a5d64127e64cdb9af92`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b19`、注释标签 `snapshot/source-20261105-b19`；
此前36个稳定引用受保护，无push。

| 功能包 | 新增可复用能力 | 当前合格有限证据 |
|---|---|---|
| [ram_read_gather](../cores/storage/ram_read_gather/README.md) | 原始地址帧的去重外部读、同帧数据/错误复用与原序回放 | 5配置、1184帧/6841输入/4820输出、2434次不同地址物理读、80次立即reset及160个完整fresh帧 |
| [nonnegative_least_squares2](../cores/signal_processing/nonnegative_least_squares2/README.md) | 原始signed样本行的精确两变量非负最小二乘 | 6配置、2470帧/8962输入、1432个原始行残差KKT证书、268次立即reset及完整fresh恢复 |
| [minimum_area_rectangle](../cores/image_processing/minimum_area_rectangle/README.md) | 无序signed二维点集的精确最小面积旋转外接矩形及支撑点 | 5配置、219帧/886输入、15790次主乘法、237次立即reset及完整fresh恢复 |
| [minimum_cycle_mean](../cores/acceleration/minimum_cycle_mean/README.md) | 原始有向加权图的全局精确最小平均环 | 6配置、352图/6010输入、261个最优环/势函数证书、168次立即reset及完整fresh恢复 |

四包均有明确有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。当前合格矩阵为
22组固定数值配置、79条原始工具记录（19/21/19/20），含26项预期非法参数
拒绝（8/6/6/6）。753个立即reset组全部完成恢复，其中gather每组恢复两帧，
合计833个完整fresh帧。每个compiler/simulator子进程上限20秒；无超时、
综合、PnR、STA、上板或扩展回归。最小示例只有语法和实例化证据。

## 接口、架构与独立证据

gather在LAST后才发外部读，对不同地址按首次出现顺序各读一次，将成功
数据或错误保存后按原输入次序输出；重复项含失败地址均复用首次观察，
错误数据规范化为零。同址跨帧重新读取，没有跨帧cache或原子快照保证。
地址是完整无符号标识，不自行定义byte/word单位或对齐。容量按保留项而非
不同地址计数。FIRST必须只在首次接受token出现，masked首token仍拥有tag；
overflow/FIRST错误先drain，格式错误和empty均不发外部请求。N1..32、地址/
数据1..64、TAG1..32，默认16/32/32/8。单同步packed address/error/data RAM
串行扫描更早已完成prefix，没有CAM、独立unique表或映射RAM。一个外部
请求在途，无ID/epoch；peer可在请求接受边界提供响应，但须保持至下拍
ready。**reset是核与peer共同取消边界**，peer必须丢弃已接受未应答旧读；
跨reset到达的旧无tag响应无法与新响应区分，合同禁止该行为，不静默drain。
独立Python有序地址字典oracle核2434次不同地址读和4820项完整输出，另核
4473行packed RAM、1184个精确延迟。四路source/request/response/output
保持检查为73246/1464/814/15302；总2644请求/2634响应的差10均为reset
取消未回答读。80次reset后两帧分别检查同址成功/错误与跨帧重新读。
默认/最大RAM1040/4128bit、scalar166/323bit；精确首valid为
2+3n+2C+2U+W，C为prefix比较次数，U为不同地址数，W为外部等待拍。
内部界n²+4n+2为322/1154，两个大配置实际达到；外部等待可无界。

NNLS2采集原始(a0,a1,b)行，求min Σ(a0*x+a1*y−b)²，x,y>=0。满列秩时
输出唯一精确非负有理坐标，共用正分母且不约分，附Gram行列式和严格
正坐标标志；不输出残差范数。W1..16、N2..16、TAG1..32，默认8/16/8。
empty=1、overflow=2、rank-deficient=3，错误保留count/tag，其余规范化零。
秩亏是服务域拒绝，不表示数学不可行。没有近奇异阈值或浮点容差。
单同步原始行RAM，一个signed-magnitude移位加法器共享每行5次W步乘法
和6次EW步宽乘法；EW=4W+2clog2N+4。Gram/RHS统计及行列式/两个坐标
分子均先证界后定宽，包含signed minimum；选择满足精确KKT的内部、单轴
或零解。独立Fraction通用Gaussian活跃变量子集oracle，以原始行残差核
原始/对偶可行及互补松弛，行列式另用Cauchy–Binet原始行对minor平方和。
1432成功、95empty、146overflow、797秩亏；正坐标mask0/1/2/3为
504/329/331/268，420个分数解。7186行RAM核对、31425次样本及13374次
宽乘法、573855步、2464次实际下一帧排队接受；268次立即reset全部完成
解析fresh。全部10状态、5样本op和6宽op覆盖。默认/最大RAM384/768bit、
scalar775/1337bit；非空未溢出帧含秩亏的精确tail为14+n*(5W+11)+6EW，
默认1094、最大1926拍，六配置上界均实际达到；empty/overflow为1拍。

旋转外接矩形枚举原始点对i<j的非零方向，规范为dx>0或dx=0且dy>0。
逐点计算u=x*dx+y*dy、v=y*dx−x*dy，返回四个极值、方向、正分母
D=dx²+dy²和area_num=(umax−umin)*(vmax−vmin)，面积为area_num/D。
极值支撑索引及生成点对可核包含性，包内给出精确有理角点/中心解码。
所有最优矩形方向中至少有一个平行凸壳边，因此原始点对枚举完备；严格
更小才替换，平局保留首字典序原始点对，极值tie保留首索引。重复点保留
ordinal；全重合规范axis(1,0)、D1、维数0，共线为合法零面积维数1。
W2..12、M1..8、TAG1..32，默认8/8/8，empty/overflow保留count/tag并将几何
置零。单同步点RAM、共享MW=4W+4移位加法器，交叉比较完整保留RW=2MW，
不截断比较乘积。独立单调凸壳+仅凸壳边Fraction oracle求最优值，另选
合同首点对编码；Gaussian消元独立核角点与中心。199成功、10empty、
10overflow；维数0/1/2为67/56/76，34个分数矩形。721个点对、4852次主
读取、622128主乘法步；全trace29286个完整signed乘积和1029672步。
214次真实排队接受、237次立即reset后完整解析fresh，M>1全部15状态及
9op覆盖；M1只经过可达单点状态。默认/最大RAM128/192bit、scalar1147/
1651bit，总1275/1843bit。保守tail为2+C(n,2)*(6+2n+(4n+5)*(MW+2))，
默认39986、最大56562拍；五配置实际最大2/724/2814/39910/56454。

最小平均环从所有正长度有向环中最小化Σweight/edge-count，无源点限制，
断连分量和self-loop均参与；无环与零平均环用has_cycle区分。N1..32、
W1..16、TAG1..32，默认8/8/8。完整32bit端点先验证后窄化，重复边最后
赋值生效，支持删除；masked首token拥有tag，FIRST/端点错误两bit独立，
完整drain后canonical零响应。结果为signed分子/正分母，不强制约分；这是
Karp差分商，不承诺该分子分母本身就是环权重和环长，不输出路径见证。
隐式零cost super-source使D0(v)=0，按同步RAM串行计算每个exact-k-edge
最短walk Dk，旧行不可变，然后求min_v max_k (DN−Dk)/(N−k)。另加显式
super-source的N+1顶点表征可推回本式，适用于任意断连图。一个signed
移位加法器依次计算两个CW步交叉乘积，无数据乘除模或近似策略迭代。
独立oracle以scaled负环阈值隔离den<=N的唯一有理值，最优环证书给上界，
使每条变换边非负的势函数给下界；小图另枚举elementary cycles，DP图像
仅为次级工作量证书。310正确图中49DAG、183负、57正、21零均值，41分数；
42错误、290次小图枚举交叉核对、261个最优性证书，含81个两点三态全枚举
图。核26259个DP store、710214次DP读、694315次邻接读、27878个完整
signed乘积、145098步；352次精确首valid，1615173次合规主source保持。
168次立即reset后完整ring及所有RAM单元核对。默认/最大RAM1512/41696bit、
scalar231/421bit；保守tail 2N³+6N²+5N+2CW(N²−1)+1为1953/84117拍，
六配置最大14/63/156/1304/1953/84117均达到完整reach界。最大工具子进程
19.000秒，在固定20秒内通过，不据此保证其他机器运行时间。

四包均单时钟、同步高有效reset、普通ready/valid，无CE或CDC。源保持到
接受或reset，输出背压时全部字段稳定，真实下一冻结token排队至接受；
reset目标观察后不再经历额外active edge即取消，并完成完整新事务。
有限探针不是形式证明。RAM推断、LUT/FF/BRAM/DSP、Fmax、功耗、器件
适配和板级吞吐均未测量；资源数字仅为逻辑声明预算。gather/NNLS2/平均环
默认LOW、最大MEDIUM，矩形在所限规模内LOW，均为结构判断。

## 来源与实际修正历史

四包均在RTL之前完成实际相邻能力去重和固定上游完整源码/full license阅读。
技术参考分别为：Vortex `48fc0069d24899fab280b8a2e388955e4296d46c`完整
VX_mem_coalescer.sv及Apache全文；SciPy
`0f1fd4a7268b813fa2b844ca6038e4dfdf90084a`完整_nnls.py、_cython_nnls.pyx
及BSD3全文；OpenCV4.12.0 `49486f61fb25722cbcf586b7f4320921d46fb38e`完整
rotcalipers.cpp及Apache全文，并单独读其源文件历史BSD header；Boost.Graph
1.88.0 `54a94911e68dccf5812b32d018566566700499f3`完整Howard cycle header，
及匹配Boost superproject `199ef13d6034c85232431130142159af3adfce22`的完整
BSL1.0。图子仓库LICENSE404后从匹配superproject补读，没有忽略缺失。
各SOURCES记录URL、具体文件、原始SHA及独立实现边界；没有复制、改编
上游实现或运行外部脚本。生产无新增sibling依赖、ROM、系数生成或网络
需求；root LICENSE/NOTICE在支持清单内。每包有core files.f和完整实例，
gather/NNLS2另有example/files.f。B的6份和C的5份冻结fixture完整保留。

矩形首次版本查询误选已安装但失效的Chocolatey Icarus shim，exit4294967295，
0.281秒普通失败，尚无RTL编译且未超时。修复resolver优先已有workspace
OSS CAD Suite，child PATH前置bin/lib后，同一19项矩阵全部通过。原计划
`7eb341d0ba79ca79276491b3bcc76496480487d8bd45d4e7acc715b5848fef8a`、原
失败收据`a15ab53a1e6b2b216638b46999938eb213323c6b94dc38fc3e8ae913235569ad`，
原runner和README逐字保存在history/attempt_01.json，其他原始源码哈希
一致。最终审阅补齐原README字节后，仅archive/计划/收据元数据重绑；
实际执行计划7f5c89...及PASS收据80a6f5...全文/哈希仍保留。矩阵、fixtures、
RTL/TB/runner及19条原始记录不变，没有再次运行。

平均环20条工具记录与独立数值输出验证均首次通过，但runner误取Icarus
追加的$finish位置行作为summary，原observed/totals为空。原runner、README、
计划和PASS收据全文/哈希保存于history/qualification_001_receipt_parser.json，
其他执行源码原样。修正唯一PASS行文本解析和history感知，从原stdout重建
统计；当前计划仅重绑文档/parser/archive哈希及明确修正说明。原执行计划
`c15c6f3bef3b0b11e54c0dba91f7cb15f38fb089e73d29dfb888a0ad70cabd7b`、原
PASS收据`1d27eae8b79dbe2721633505a8cdb0549761e684ce9e2ffc40cc1ee7fd4b2c3f`
均可逐字重构。原20条记录、RTL/TB、oracle/fixture/validation函数、输入、
DP及oracle哈希完全不变，无工具或oracle重跑。

NNLS2合格后仅刷新README实测结果与余量措辞，tested/current差异仅README，
原README和原PASS收据重构链保留；gather从冻结到合格后无源码变动。
本批实际80条包内工具执行由79条当前合格记录和1条矩形版本查询失败组成。
平均环、NNLS2及矩形收据中嵌入的原PASS记录是同次执行副本，不能重复计数。
没有隐藏失败、缩减fixture、提高时限或重跑任何继承数值配置。

| 当前收据 | SHA256 |
|---|---|
| gather | `93c62825ecf053173d1337206120eb8d8e465457c5242c584a4d5b3a23882310` |
| NNLS2 | `cb4cd3a4255938c77e03dfefa5322a426606136efe3958575eff1f70ebc923d3` |
| rectangle | `8bf07941515c63f065b7a0bbd550c432e06e9121faf609800ce5c5297e218636` |
| cycle mean | `843dbfb170b54a8384348db14db6537e0e94dbee63f4425c77a640bddabac2a1` |

## 冻结、发布与恢复

累计76包中75包有明确有限UNIT证据。B14 weighted_interval_schedule仍仅
LINT_PASS，首N1仿真20秒终止、数值TIMEOUT_NOT_RUN、零完成配置及后续
NOT_RUN不变，静态TB修复未重跑。B11面积开7/8数值配置、64x64编译通过
但数值超时；B12 GLRLM128x128、B13 GLSZM32x32、B14 GLDM128x128、
B15 NGTDM128x128和B16 Hausdorff32x32最大配置compile-only范围完整保留。
不将本次语法通过扩写为这些配置的数值通过。

A审root、B审A、C审B、root审C均CLOSED PASS；两个原README恢复字节
补齐后重闭环。功能提交：gather `6d67d6a40faef3cbe272a6ccd54135a068b96ae0`；
NNLS2 `5655e471191b99e04d9f1409d7ec3b205e549ed8`；rectangle
`d40d8a8ea14d7d73b3f8d50821cadb3bd1cc4a8c`；cycle mean
`7f99defe9f685d874163395f412d631098ea23fa`。没有修改旧包或共享RTL。

[B19清单](snapshots/source_20261105_b19.json)逐对象继承B18全部72包、737个
包内文件、12个支持文件及原dependency map。新增55文件（11/17/16/11），
其中53个当前文件、2个archive文件；累计792包内文件+12支持，共804个
冻结文件。76core+77example共153tops、160个唯一生产源。SECDED、divider
及EDT固定来源提交不变；检查器、默认UNIT要求和既有显式LINT-only规则不变。

源码冻结`cf88189b1ab56dfafa1455ef98058dc26cf22f4f`，唯一一次隔离导出检查
exit0，Icarus -tnull通过153tops/160sources；编译child20秒，未运行数值矩阵。
[实际检查输出](snapshots/source_20261105_b19_check.txt)共76条包PASS及两条
最终PASS，25组timescale警告中前23组与B18逐行相同。仅新增矩形core及
example第2行两条警告，均继承
`cores/signal_processing/nonnegative_least_squares2/example/nonnegative_fit16.sv:2`
的timescale。两者为无delay生产RTL，没有其他诊断；保留实际输出，不补
指令或重跑。输出仅CRLF至LF规范化。清单SHA256
`6562766098cfc3ca99162c148d2237496fd485a9109cd83a9ef52b043880efae`，检查
记录SHA256 `8c7157402c0e6b8011ba4835c4edb4b42a4631651b22cb56ce9b5c7cd37c0c68`。

独立发布审计CLOSED PASS：全部804个冻结Git blob、B18全部72包对象及
737包内/12支持文件逐对象继承、四feature祖先和55新增文件范围一致。
离线闭包153tops/160sources、76包成熟度、22配置/79合格原始记录加1条
普通失败共80实际执行、26拒绝/753reset组/833fresh帧均独立复算一致。
原始收据副本未重复计数，C失败与元数据补全、root summary解析修复的
全文/SHA链均可重构。78条PASS、25组实际警告及其来源、两份SHA、全部
文档链接与收据/功能提交引用、README和本文均与实际证据一致。
审计全程只读，没有编辑、暂存或重跑checker、compiler、simulator、oracle。

实际唯一执行命令：

```text
python -B scripts/check_source_snapshot.py --ref cf88189b1ab56dfafa1455ef98058dc26cf22f4f --manifest docs/snapshots/source_20261105_b19.json --compile
```

最终发布只暂存本文、README入口和真实检查输出，串行提交，无push。
原15项tracked修改/删除、21000未跟踪路径、goal.txt及原36稳定引用受保护。
Goal继续active，本批是持续积累FPGA原生功能资产的本地检查点。

前批：[第十八批](IP_ASSET_BATCH_20261105_B18.md)。
