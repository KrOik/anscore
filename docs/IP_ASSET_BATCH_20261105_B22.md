# 2026-11-05 第二十二批与累计八十八包源码快照

本批基线 `1fcf2f92dbf763e3251bd2994a7b9fd940c43694`，开发分支
`development/ip-assets-20261104`。本地稳定分支为
`stable/source-20261105-b22`，附注标签为 `snapshot/source-20261105-b22`。
此前42个稳定引用保持原样；无push。

| 功能包 | 新增能力 | 当前合格有限证据 |
|---|---|---|
| [ram_sparse_assembler](../cores/storage/ram_sparse_assembler/README.md) | 任意顺序不可变word装配、同值幂等、冲突保留及完整后有序发布 | 5配置、9610主命令、10282输出、847266完整owned-row核验、110立即reset与1276完整fresh命令 |
| [affine_floor_sum](../cores/signal_processing/affine_floor_sum/README.md) | 四个unsigned标量的精确仿射整除和，无需逐项输入 | 6配置、4774主事务、7771轮证书、186立即reset/fresh、4960精确延迟 |
| [polygon_triangulation](../cores/image_processing/polygon_triangulation/README.md) | 保留共线边界点的凹简单多边形精确三角化，完整网格后发布 | 5配置、3873主事务、183满容量fresh、7334主/恢复triangle或error记录 |
| [directed_euler_trail](../cores/acceleration/directed_euler_trail/README.md) | 指定起点的有向多重图完整欧拉路径及原边身份见证 | 6配置、2824主事务、8916行、4577主输出、126立即reset及满容量fresh |

四包均有有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。当前合格原矩阵为22组参数、
137条工具记录（18/19/73/27），含22项预期参数拒绝（6/4/6/6）。605组立即reset
全部完成恢复，共1771个完整fresh事务/命令；装配核每组执行两对象恢复命令序列，
其余每组一完整事务。每个compiler/simulator子进程硬限20秒。没有综合、PnR、
STA、上板、继承矩阵重跑或扩展回归；示例只有语法/实例化证据。

## 实际计算、接口与架构

稀疏装配接受BEGIN/PUT/COMMIT/ABORT/STATUS。长度和offset均先检查完整unsigned64，
才窄化到本地RAM地址。首次PUT写入，同值重复只读并报DUPLICATE，不同值报CONFLICT
且保留首值。缺位COMMIT返回INCOMPLETE并保留partial对象；全部位置齐全才按索引
重放，最后数据真正被接受后关闭对象。单同步payload RAM与resettable ownership
bitmap隐藏未复位内容。独立oracle使用稀疏dictionary与排序键，不模仿RAM pipeline。
主流量逐响应核对全部public字段、完整owned payload、9610次精确latency/RAM首访问
及672次重放gap。22个立即reset目标覆盖所有8状态、各类held ACK及重放阶段；每次
恢复完成partial/incomplete、duplicate/conflict、完整提交、closed STATUS及另一个
singleton，真实退休。最大N256/D64实际运行。43891次command hold、34282次输出
hold均有实际逐字段核验。

整除和精确计算 `sum(floor((A*i+B)/M), i=0..N-1)`。输入W1..16，输出unsigned3W。
M0优先返回error/零，M>0/N0成功零；最大W16结果140733193420800超过32bit。
Euclidean降维复用W步移位加法乘法与2W步恢复除法，无数据乘除模算子或RAM。
每轮模数下降，n不增加；完整范围证明支持窄化与所有非负累计贡献。独立primary
oracle直接逐i整数相除，不使用降维递推。W1..3穷举16/256/4096个四元组；最大宽度
极值与Fibonacci深链实际运行。143960乘法步、188106除法步及7771轮有证书，4768个
真实下一token持续到接受。31个reset目标/配置及W1明确不可达alias均保留，恢复
事务held后实际退休；最大观察3831拍，安全界5511。

三角化输入signed2..12坐标、3..32容量，接受正反winding与forward-collinear边界，
拒绝重复、backtrack、非相邻闭段相交/接触、零面积及输入错误。每次选最小原ID
合法ear，输出N-2个正Cartesian面积三角形，保留原IDs和坐标。四个同步RAM银行、
一个源级最大13x13共享乘法表达式，先完整验证与缓存全部mesh，再输出。完整
Fraction全局diagonal visibility、midpoint winding与interval-DP作为独立参考；
网格另核正面积、面积守恒、边重数及不交叠。N3穷举729个ordered grid triples，
N4穷举3024个distinct ordered quads；后者首次HDL前固定四组756。N32四个满容量
stress及reset每组最多四目标也在首次HDL前拆分，没有运行后缩减。
主流量1638成功/2214 geometry/6 overflow/10 upstream/5 combined，主输入15090，
主输出5231；183完整fresh另输入2469/输出2103，总17559输入/7334输出。3860个真实
下一帧接受、866904次源保持、17727次输出保持、498646次同步bank读取与267718次
精确determinant均核对。40个global reset目标中N3精确排除17个不可达项，实际mask
`8bfbc030ff`；其余各配置mask `ffffffffff`。183条OBS逐ID与分组名单相同，全部
fresh使用该配置满容量多边形并退休全部三角形。最大主延迟33117、满容量fresh
31616；均在冻结界内。

欧拉路径接受unsigned32指定起点与有向边帧。masked行忽略端点，保留边按输入顺序
取得独立ordinal，self/parallel边不合并。输入错误sticky OR后drain到LAST。
同步边RAM、saved-current栈与逆序路径RAM串行执行Hierholzer；所有边已用且缓存
e+1记录后，再验证起点及每对相邻顶点的原始incoming-edge端点。完整证书通过才
发布；无解返回一条规范masked错误。空图成功返回请求顶点，孤立非起点无影响。
primary oracle为度差/弱连通定理，<=5边另直接排列枚举；N2/N3完整穷举长度0..3
有序多重图与全部起点。1753条主edge见证、50908次scan读取、2824个精确首valid
逐项核对。真实下一command/row提前排队，每条输出held两边；所有同步RAM read
核对。21个目标/配置立即取消后完整覆盖M个edge、M个stack、M+1个route位置，
恢复全部M+1输出真实退休。最大N16/M64/T32完成实际数值与完整恢复。

| 逻辑声明预算 | 默认/最大RAM(bit) | 默认/最大scalar(bit) | 内部首valid预算 |
|---|---:|---:|---|
| 稀疏装配 |512/16384|131/469|普通ACK0、新PUT1、duplicate/COMMIT2；重放接受间隔3|
| 整除和 |0/0|160/322|exact `R*(10W+8)-(2W+1)`；安全默认1479/最大5511|
| 三角化 |488/1378|302/428|默认29957/最大230469；后续无停顿接受间隔12|
| 欧拉路径 |712/1802|146/223|成功exact `2Q+8e+7`，安全默认4423/最大17031；空图7|

这些为源级声明和周期预算，不是LUT/FF/BRAM/DSP测量。装配/欧拉默认LOW、最大
MEDIUM；整除和LOW；三角化MEDIUM，均为定性结构判断。物理适配、内存推断、Fmax、
功耗和板级持续吞吐未测。所有核单时钟、同步高有效reset、普通ready/valid，无
CE/CDC；源保持至接受或reset，held输出全部字段稳定。reset在观察边界后、下个
active edge前立即取消，完整fresh真正退休。外部等待可以无界。准确契约及范围
证明见各README；CE-qualified stream需要明确adapter。

## 来源、固定矩阵与真实失败

四包在RTL前均做实际全cores语义去重，实际阅读相邻契约，以及固定上游完整相关
源码与完整许可证只读检查。装配参考lwIP commit
`77dcd25a72509eb83f72b033d219b1d40cd8eb95` 的ip4_frag.c与COPYING（BSD3）；整除和
参考AtCoder `864245a00b00dd008d1abfdc239618fdb7d139da` 的math.hpp、internal_math.hpp
及完整CC0 1.0 LICENSE；三角化参考Mapbox earcut
`1b942f01f4093afe8f9ba729c3850b229f69eb12` 的earcut.js及完整ISC LICENSE；欧拉路径
参考NetworkX `4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4` 的euler.py及完整BSD3 LICENSE。
各SOURCES保留固定URL、bytes/SHA与能力差异。root另独立全文读Mapbox source/license，
A另独立全文读NetworkX source/license。没有复制或执行上游代码，也没有引入外部
RTL、库、peer、ROM或网络依赖。全部files.f与完整实例闭合，可离线使用。

欧拉首次矩阵发生一次普通TB guard失败，非timeout：前4条PASS，第5条N1 main
FAIL，余22条NOT_RUN。新命令清edge_count，used_count直到INIT才取得新owner；
原TB在LOAD阶段把上一帧used_count与新edge_count比较。仅将此项比较限定到真实
求解/验证/prefetch状态，永久容量界继续全时检查。A只读复核并闭合修复范围。
完整原17个text文件（含原plan、source binding、raw receipt）保存在
history/attempt_00.json，SHA
`4a591a29ca62f1f2bd5dc7481b76240bdeb5b31703161f61f4e58ef1df646166`。
原receipt SHA `91bf98c3d2229083aa9b198b6690750e04885c634fa1147793301fa503d2d7a2`。
完整repair_01.diff SHA
`48e8fae6811bd1250e986245a9bbc2aebca2078fc00977a4a56d2755df1041e9`，仅TB guard、
runner归档/部分输出保留和README chronology。RTL/example/六fixture/plan逐字
未变；全部输入、oracle、reset目标、27children及20秒限制相同。原FAIL与NOT_RUN
保持原标签，归档副本不另计执行。修复后同矩阵27条合格，其余三包首次矩阵合格。
本批包内实际工具执行142条=137当前合格+5旧实际，不把22旧NOT_RUN当执行。
最长child为整除和1.437秒、三角化2.281秒、欧拉2.558713秒；装配每child20秒限制
及实际退出完整记录。没有超时重试、缩刺激或加时；合格后没有源码编辑或重跑。

| 当前收据 | SHA256 |
|---|---|
| 装配 |`494bb37bdf1cfda021749564f054256a00962f046bcd5a38845cf75bd2172cb7`|
| 整除和 |`22218a2e3b60a60d0d97b66333b6b26e19b4ed3ecaf57b9e2d8ab125de2fc93e`|
| 三角化 |`da252281fa4b351a0dfe8291e4b7ca5a4d91a29c86f19d0e0d04e31c8169ab7b`|
| 欧拉 |`b7a58486ea51954bea20b99f657ffa4b450a38509aab657d94f1a050af4b65f2`|

## 冻结、发布和恢复

累计88包为87个有限UNIT包与1个继承LINT-only候选。B14 weighted_interval_schedule
仍首N1 vvp20秒TIMEOUT_NOT_RUN、零完成配置，其静态TB修复没有重跑。B11
grayscale_area_opening的64x64仿真终止超时、其余7/8配置不变；B12 GLRLM128x128、
B13 GLSZM32x32、B14 GLDM128x128、B15 NGTDM128x128及B16 Hausdorff32x32的最大
compile-only边界全部保留，不能从本次语法检查外推数值通过。

四项环形互审A→root、B→A、C→B、root→C均CLOSED PASS。实际功能提交顺序为
欧拉 `ec76c2fbb72b8c2fa4ad2d42a5fd46a38ff2400c`，装配
`3a8afb197be54a6404150167d0897dfeeef9eb20`，三角化
`518f9d1c270f1964e7542a1ef8423d55b90e47ac`，整除和
`b8577d00fe91a93c77abdb070709bcc365e70ef6`。root只按精确路径串行暂存/提交。
未修改旧包或共享RTL。欧拉source-bound README一个EOF空行及原diff两个必需空
context前缀原样保留，静态检查逐项记录，未为风格检查改写合格证据。

[B22清单](snapshots/source_20261105_b22.json)完整继承B21的84个package对象、950
包内文件、12支持及dependency map。新增128文件（12/25/72/19），其中126当前
文件、2归档证据文件；累计1078包内+12支持=1090冻结文件。88core+89example共
177tops，184个唯一生产源。检查器、默认UNIT门槛、显式继承LINT-only规则及
SECDED/divider/EDT来源提交不变。清单SHA256
`0cf9d4b4940e2e572cf72c2256dae175d68d38ea9f66d65cf1c31cbb10847827`。
源码冻结为 `1ad3ea294a84d22ca77e0fd0eda4cd1738474267`。

唯一隔离导出检查exit0：177tops/184sources，compiler child固定20秒。实际命令为：

```text
python -B scripts/check_source_snapshot.py --ref 1ad3ea294a84d22ca77e0fd0eda4cd1738474267 --manifest docs/snapshots/source_20261105_b22.json --compile
```

[原始输出](snapshots/source_20261105_b22_check.txt)共148行/90PASS，SHA256
`8a2a623c916aee89df6234159cb751b81c5d2f55438ca7494d21321bfc0cf380`。
原B21全部50条诊断行保留，新增整除和/欧拉四个module的timescale warning/source
note共8行，总29组/58行；未隐藏诊断。包内两核各六次TB编译另有同类缺显式
timeunit提示；生产模块没有delay。外层checker stderr为空，输出只做CRLF→LF。
没有重跑任何包内或继承数值矩阵。

B最终独立发布审计CLOSED PASS，无剩余发现：1090个committed blob逐Git OID及
SHA256核对，84继承对象与962旧文件OID完全原样；新增128文件、4项feature scope、
完整失败归档及同刺激修复、所有真实记录/计数、原始编译日志与诊断均闭合。
独立重算22配置、137当前合格/142实际执行、605立即reset与1771完整fresh，
全部源码/资源/周期/离线依赖、7个本地链接及README/本文哈希引用正确。

A在最终冻结后的独立保护审计CLOSED PASS：42旧refs逐raw/type/peeled、原15项
tracked状态/binary diff、精确goal.txt raw SHA均不变。完整
`git ls-files --others --exclude-standard -z`非ignored清单仅排除本批指定checklog
后，原21000路径及trailing-NUL/LF双哈希保持原样；暂存区空。最终发布只提交
本文、README入口及真实检查输出，新建本地稳定分支与附注标签，无push。
Goal继续active，本批为可恢复的本地检查点。

前批：[第二十一批](IP_ASSET_BATCH_20261105_B21.md)。
