# 2026-11-05 第二十三批与累计九十二包源码快照

本批基线 `20e2db4aded8858ff63e132c2399fb416aa48ed0`，开发分支
`development/ip-assets-20261104`。本地稳定分支为
`stable/source-20261105-b23`，附注标签为 `snapshot/source-20261105-b23`。
此前44个稳定引用保持原样；无push。Goal继续active，本批为可恢复的本地检查点。

| 功能包 | 新增能力 | 当前合格有限证据 |
|---|---|---|
| [ram_region_guard](../cores/storage/ram_region_guard/README.md) | 持久优先规则的完整byte-span读/写/执行授权判断 | 5配置、9984主命令/响应、137286完整owned-row核验、110立即reset与2200完整fresh命令 |
| [exact_binomial](../cores/signal_processing/exact_binomial/README.md) | 完整unsigned64参数的精确二项式系数 | 6配置、7281主事务、1027088逐cell证书、150立即reset与满容量fresh |
| [point_delaunay](../cores/image_processing/point_delaunay/README.md) | 无序整数点集的完整精确Delaunay网格，含全局共圆决策 | 5配置、7929主点集、224立即reset与满容量fresh、14920主/恢复记录 |
| [suffix_array_lcp](../cores/acceleration/suffix_array_lcp/README.md) | 运行时符号帧的完整后缀数组和相邻精确LCP | 5配置、407主帧、2700主输出、105立即reset与2553满容量fresh输出 |

四包均有有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。当前原矩阵为21组参数、
294条合格工具记录（18/80/121/75），含22项预期参数拒绝（6/4/6/6），共189个
仿真子进程。A将预期拒绝明确标为EXPECTED_REJECT，其余三包用PASS加具名非零
退出证明；清单按实际returncode、错误marker及精确数量核验，没有更改原收据标签。
589次立即取消各完成一组恢复序列：A的110组共2200条fresh命令，其余479组各完成
一帧。不能把混合单位写成2679帧。每个compiler/simulator子进程硬限20秒。
没有综合、PnR、STA、上板、继承矩阵重跑或扩展回归；示例只有语法/实例化证据。

## 实际功能与结构边界

区间规则核支持SET/GET/DELETE/CLEAR/STATUS及CHECK。规则可重叠，最低编号且与
请求任意byte相交的live规则拥有决策权；必须独自包含完整范围并提供全部请求权限。
后续规则不能补足范围或权限，permission0是合法deny-all。完整64bit base、65bit
正长度与32bit slot先验证才窄化，66bit加法覆盖含整个2^64空间的边界。单同步规则
RAM加独立live map串行扫描，无并行CAM。primary使用无界半开整数区间与权限集合，
小地址另用实际byte集合交叉核验739次。9984次精确首valid和RAM schedule、53732次
命令保持及34642次输出保持均有实际检查。22目标/配置取消后完整20命令恢复并检查
全部owned rows。调用方必须绑定真实payload地址/长度/意图并协调policy lifetime；
该服务不自行访问或封锁总线，不宣称PMP兼容或系统隔离证明。

二项式核计算C(N,K)。输入N超过MAX_N先报错；合法N的K>N成功零，K0/K=N成功一，
包括N0/K0。其余取k=min(K,N-K)，单同步系数RAM按行、按列降序执行Pascal递推。
三拍read-current/read-previous/write保持前一行依赖，无数据乘除模或DSP。主oracle
用factorial quotient，小N另用subset bitmap计数；完整64bit优先级和极值不窄化别名。
61个最多128行的主分组在RTL前固定，另6个reset仿真。7431次精确延迟、29837次
初始化与最终行、2056944次计划读取和2099164次owned同步读均闭合。25目标/配置，
MAX1的19个、MAX2的2个不可达阶段显式alias保留。恢复使用满容量central系数，
最大C(64,32)=1832624140942590534及4755拍实际运行。7220个真实下一token保持到接受。

Delaunay核接受无序signed整数点，重复坐标保留首原ordinal，保留内部及共线边界点。
完整枚举非共线三元组，精确empty-circle筛选，先缓存全部mesh再发布正面积三角形。
全局概念lift `z_r=x_r^2+y_r^2-epsilon^(r+1)`，epsilon=2^(-(2C+5))，保留非零整数
determinant符号，零值由最小原ID负height cofactor决定；等价于每个空共圆面的最小ID
fan，避免各四元组独立选对角线。输入顺序可以改变合法共圆对角线。少于3个unique
或全共线是正常零mesh摘要，带unique/dimension。三个同步银行和一个最大27x26
共享乘法表达式执行几何，无浮点或host拓扑。55bit incircle累加覆盖完整C12范围。
低凸壳扰动与Euler证明T<=2U-5，最大fresh16点/27三角形实际占满triangle bank。

C的独立Fraction circumcentre/radius分组、boundary gift-wrap及fan oracle不复制RTL
translated determinant。精确rational clipping核正面积、不重叠、全部点、边重数、
边界细分及Euler等式。N3全729个ordered grid triples、N4全6561个ordered quads、
N8全部511个至多8点subset均进入原矩阵；N16每组至多2主点集/2reset在RTL前固定。
root另独立解析全部112夹具，以整数empty-circle和全局tie、canonical tuple、面积、
完整点/边界与noncrossing证书审查：32074主输入/12808主输出，1997fresh输入/2112
fresh输出。原取消候选另1955输入包含在固定分配中，不能算作完成事务。224条OBS
逐ID与事前名单一致，N1排除49目标、N3排除22，其余59目标全到达。8153次latency、
1220953次clocked-bank读取、3927374次共享product、77072次orientation和251504次
incircle实际检查；最大主/恢复首valid109600拍，纸面安全界267204。7879个实际下一帧
接受、2568797次源保持和44826次输出保持均闭合。

后缀核对kept符号序列产生完整suffix-start permutation及相邻最长公共前缀，短后缀
优先，不保留sentinel值，零和全一均为普通符号。首接受tag含masked首token；overflow
与upstream错误sticky OR后drain到LAST，只发一条规范masked错误。成功前所有ID/LCP
缓存完整。三单口同步银行服务serial suffix insertion和相邻LCP扫描，共18状态。
primary物化tuple suffix keys，独立rank证书计数更小suffix，LCP直接逐符号比较；
schedule只供操作/延迟证书。407主帧逐项精确首valid、18423次sort comparisons、
189964次sort字符对、16708次LCP字符对及441697次主RAM读检查全部一致。
399次真实下一帧排队、675178次源保持、5400次输出保持均实际发生。24个reset目标
在M1明确排除15个不可达项，共105次取消后满M全等fresh，核最大精确延迟、全部M输出
真实退休和三个完整RAM银行。LCP<=M-1，使用I=max(1,clog2 M)位，不采用更宽旧提案。

| 声明与周期预算 | 默认/最大RAM(bit) | 默认/最大scalar(bit) | 内部首valid及输出 |
|---|---:|---:|---|
| 区间规则 |1072/8384|186/392|SET1、live GET2、CHECK首相交i为2(i+1)/miss2S；最大32/128|
| 二项式 |544/2112|131/255|compute N+k+3+3U，U=kN-k(k-1)/2；最大1227/4755，special0|
| Delaunay |227/708|354/521|完整无停顿tail预算11316/267204；后续接受间隔12|
| 后缀/LCP |576/1792|94/146|全等达到安全界25982/191230；L1为4，空/错误1；后续接受间隔3|

后缀精确式为4+2A+4P+E+S+5(L-1)+4Q+F；边界和同步读均计入。完整公式及证明见README。
这些是源级声明/周期预算，不是LUT/FF/BRAM/DSP测量。A/B/root默认LOW、最大MEDIUM，
C为MEDIUM，均为定性判断；物理适配、RAM推断、Fmax、功耗和板级持续吞吐未测。
四核单时钟、同步高有效reset、普通ready/valid，无CE/CDC；payload RAM无reset sweep，
由新事务ownership遮蔽旧内容。held输出全部字段稳定，外部等待可无界。
现有CE-qualified stream需要明确adapter。

## 固定来源、普通失败与不可变证据

四包在RTL前均实际完成语义去重、相邻契约读取及固定上游完整相关source/license
只读检查。A参考Ibex `fab0d864c8f3f1edebe3ca50b2bd75627fb0e22c` 的ibex_pmp.sv及
完整Apache LICENSE；B参考Boost.Math `529f3a759d83aa9437613666ea6293c9336d4069` 的
binomial.hpp与parent Boost `199ef13d6034c85232431130142159af3adfce22` 的完整BSL许可证；
C参考Delaunator `80ac079775bbe52ffec51df1394561d0e6e6e4a9` 的完整index.js/ISC LICENSE，
并核robust-predicates固定源与完整Unlicense；root参考AtCoder
`864245a00b00dd008d1abfdc239618fdb7d139da` 的完整string.hpp/CC0 LICENSE。各SOURCES保留
固定URL、bytes/SHA与实际能力差异。A另全文独立核AtCoder，C另全文独立核Boost，
root另全文独立核Delaunator source/license。没有复制、适配或执行上游代码；无新增
外部RTL、库、peer、ROM或网络依赖。完整files.f与实例可离线使用。

C首尝试4PASS后在第5个child普通FAIL，非timeout：Icarus不接受$fscanf直接写二维
TB数组，尚未开始数值检查，余116个child为NOT_RUN。完整128原archive文件保留在
failure_archive/attempt_01，包括124个原source、原plan、verification、receipt及
NOT_RUN。原plan SHA `cadbd2738fefa04afb8be9796a02af3567747cb6ee93962ec6bcb410419bef50`；
原receipt SHA `35795c64dfbc01c8eafebd15d3d62abb8ed0f3ddd9514051671ad5c65599feaa`。
root在逐bytes核归档后仅授权scalar signed-longint读取再赋同一数组、runner显式普通
失败reseal和README chronology；RTL/ARCH/prepare/MATRIX/112fixtures、全部121commands
与20秒逐项不变。精确repair.patch SHA
`9e12d0c9c197d1adddf4f7f005669eca8cb1078f38b2783a9d6d6a90c34156bb`，原archive逐hash
由repair.json绑定。新plan SHA `62b2482764f43b18d98a43bc5d7359cbca3aff631656566e875b57a4aafdd8a4`。
root复核补丁及新封存后才授权同完整矩阵，121条全部合格；原FAIL/NOT_RUN保持原标签。
实际包内执行共299条=294当前合格+5旧实际，归档重复副本和116旧NOT_RUN均不算执行。
没有timeout重试、缩刺激或加时；所有PASS后零源码编辑/数值重跑。

| 当前收据 | SHA256 |
|---|---|
| 区间规则 |`22629d60133264fc32f0fb886197fb48497995ff7592ff97c3889a63e243a01c`|
| 二项式 |`bdd4b3b18732b9fa9cd2931e19ba819b2670f80887bc9cd08bc43301e73d6222`|
| Delaunay |`bdee4a4cef7dcb0e324fa484911f55577c8d013bdcac7922f23d3fe8d3e301be`|
| 后缀/LCP |`520c789f59e363e11830326da48086b2115e8aba762d01a7b40dd05744ed37b6`|

最长child依次为1.2878051/3.375/4.094/6.242296秒，均低于各自20秒硬限。
四项环审A→root、B→A、C→B、root→C均CLOSED PASS。实际提交顺序为后缀
`427cff622e89d5ac87faf8985d70a8e4041933f0`、规则
`8262900965282abeaa4d5fb4916c2a939587703a`、Delaunay
`b03914ee8a4d0a8db232f8e1d28c302fb5e7b1f8`、二项式
`0f6f0d9f379d4e2f5b3bfa48567f66257730d478`。root独占按精确路径串行暂存/提交，
未修改旧包或共享RTL。C精确patch第38/51/95行的必需空context前缀保留；未为风格
检查改写合格证据。A提交前保护审计先逐包由seal/receipt/repair表推导367个精确path，
核实际集合相等后逐项剔除，原21000个非ignored未跟踪path及双哈希保持原样。

## 累计冻结、隔离导出与恢复

累计92包为91个有限UNIT包与1个继承LINT-only候选。B14 weighted_interval_schedule
仍首N1 vvp20秒TIMEOUT_NOT_RUN、零完成配置，其静态TB修复没有重跑。B11
grayscale_area_opening的64x64仿真终止超时、其余7/8配置不变；B12 GLRLM128x128、
B13 GLSZM32x32、B14 GLDM128x128、B15 NGTDM128x128及B16 Hausdorff32x32的最大
compile-only边界保留，不能从本次语法编译外推数值通过。

[B23清单](snapshots/source_20261105_b23.json)完整继承B22的88个package对象、1078
包内文件、12支持及dependency map。新增367文件（12/80/256/19），其中239当前
文件、128原失败归档；累计1445包内+12支持=1457冻结文件。92core+93example共
185tops，192个唯一生产源。检查器、默认UNIT门槛、显式继承LINT-only规则及
SECDED/divider/EDT来源提交不变。清单SHA256
`4ce6e4d6e3675cc19529d38b415b23673cf9ab63de7d6bc3dc484418123be6c0`。
源码冻结为 `bb880a4a66694c5aab18161361b04e1ab9675239`，直接父为最后二项式feature。

唯一隔离导出检查exit0：185tops/192sources，compiler child固定20秒。实际命令为：

```text
python -B scripts/check_source_snapshot.py --ref bb880a4a66694c5aab18161361b04e1ab9675239 --manifest docs/snapshots/source_20261105_b23.json --compile
```

[原始输出](snapshots/source_20261105_b23_check.txt)共152行/94PASS，SHA256
`765cd106f4da84198881fe1205fc9e1554c9ab6bcd8560bd4b3c38f6036df5d5`。
B22的29组timescale warning/source note共58行逐字保留，没有新增诊断或隐藏提示。
相关旧DUT无data delay，缺timescale不等于时序验证。外层checker stderr为空，
stdout只做CRLF→LF。没有重跑任何包内或继承数值矩阵。

B最终独立发布审计CLOSED PASS，零剩余发现：1457/1457个committed blob逐SHA核验，
88继承package对象和1090旧file OID完全不变；367新增文件、四feature串行父链与
精确scope、294当前记录/22预期拒绝、原FAIL/NOT_RUN和同刺激修复完整闭合。独立
重算21配置、185tops/192生产源、589reset恢复序列及混合fresh单位，全部技术契约、
资源/周期预算、原始日志、7个本地链接和README入口均一致；零重跑或源码修改。

A最终冻结后的独立保护审计CLOSED PASS：44旧refs逐raw/type/peeled、原15项tracked
状态及binary diff、goal.txt raw SHA完全不变。四包367个精确path均已tracked且逐raw
等于HEAD blob。完整git ls-files --others --exclude-standard -z共21002路径，只剔除
本文和checklog两条精确path后，原21000路径及trailing-NUL/LF双哈希保持原样；索引空。
README仅前批标题与本批入口变化，三release文件UTF8/LF，冻结提交仅manifest一项。
最终发布仅提交本文、README入口及真实检查输出，新建本地稳定分支与附注标签，无push。

前批：[第二十二批](IP_ASSET_BATCH_20261105_B22.md)。
