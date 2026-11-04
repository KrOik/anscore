# 2026-11-05 第二十批与累计八十包源码快照

基线 `ff2aadf8ebdc8e5475b7022cd68d47e496b9f593`，开发分支继续为
`development/ip-assets-20261104`。本批本地稳定分支
`stable/source-20261105-b20`、附注标签 `snapshot/source-20261105-b20`；
此前38个稳定引用受保护，无push。

| 功能包 | 新增可复用能力 | 当前合格有限证据 |
|---|---|---|
| [ram_sg_range_map](../cores/storage/ram_sg_range_map/README.md) | 原子替换SG段表，按逻辑字节范围查询裁切后的物理片段 | 5配置，1901命令/1668段/3104输出，80立即reset与320条完整fresh命令 |
| [bounded_rational_approx](../cores/signal_processing/bounded_rational_approx/README.md) | 原始signed有理数在运行时分母上限内的全局最近有理逼近 | 6配置，5207事务/111平局，114立即reset及完整fresh |
| [qoi_decoder](../cores/image_processing/qoi_decoder/README.md) | 完整QOI文件验证成功后发布精确RGBA光栅 | 5配置，252文件事务/12911输入字节/1818像素及104错误token，197立即reset及完整fresh |
| [exact_graph_coloring](../cores/acceleration/exact_graph_coloring/README.md) | 任意小型无向冲突图的精确最少着色及完整最优分配 | 6配置，216图/1963输入，132立即reset及完整fresh |

四包均具明确有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。当前合格矩阵为
22组固定数值配置、86条工具记录（19/21/21/25），含26项预期非法参数拒绝
（8/6/8/4）。523个立即reset组全部完成恢复，合计763个完整fresh事务；
SG每组包含四条完整命令，其余每组一帧或文件。每个compiler/simulator子
进程固定20秒。当前合格矩阵没有超时；QOI两次先前普通失败的真实执行与
NOT_RUN完整保留，详见下文。最小实例只有语法和实例化证据。没有综合、
PnR、STA、上板或扩展回归。

## 实际接口、结构与独立证据

SG映射用LOAD事务原子替换任意(base,length)段表；先写inactive bank，
完成数量/地址范围/长度验证后才发布。失败LOAD保留旧active map，CLEAR
清空公开映射。QUERY(offset,bytes)按逻辑串接顺序裁切并输出物理片段；
物理重叠和倒序允许，零长段保留ordinal但不贡献字节。完整64bit范围在
65bit加法域预检后窄化。单所有权、独立command/entry源、held ACK/fragment
合同明确；没有payload搬运或外部存储事务。N1..32、地址1..64、段长1..32、
TAG1..32；两bank共一packed同步RAM，失败shadow内容永不公开。独立prefix
区间交集oracle核39457个active行、1901个精确首valid、1203个片段间精确
间隔，并对小域3213个字节映射逐项核验。80组立即reset后各完成
LOAD→QUERY→拒绝LOAD→QUERY，验证恢复及失败保留。

有理逼近输入signed numerator、unsigned denominator与运行时Q，输出在
1<=q<=Q内使绝对有理误差全局最小的约分p/q；平局取小q，再取小|p|，对
正负对称，负半整数向零。D0/Q0两bit独立错误，payload规范化零，合法零
为0/1。W2..16、QW1..8、TAG1..32；先恢复整数商，再用fractional
Stern–Brocot相邻上下界和递减残差，不做遍历q的RTL暴力搜索；共享移位
加法乘法器只执行择近交叉积及最终分子恢复。独立oracle枚举每个q的
floor/ceil候选并用Fraction比较，没有复刻硬件递推。5207主事务中4114成功，
其余为386个D0、638个Q0、69个同时非法；1959精确、2155近似、111平局。
5201个真实下一token保持至接受，5321次精确延迟含完整fresh，33014个
上下界证书、8538个完整乘积、39322乘法步和35351除法步均核对。

QOI从实际字节文件解析14字节header及INDEX/DIFF/LUMA/RUN/RGB/RGBA，
8bit通道严格模256；INDEX加载四通道，RGB/DIFF/LUMA/RUN保留previous alpha。
维度按完整32bit验证，channels3仍接受RGBA并保留alpha。64槽历史含透明
初值和hash覆盖。RAM缓存整文件与解码像素，准确核验像素数、run边界、
保留尾部、7个零加1标记及精确剩余长度后，才输出整幅像素。失败只产生
一个canonical错误token，没有提前泄漏的像素前缀。连续相同INDEX是格式
的encoder禁例，本地严格拒绝；不宣称与宽松C参考的坏文件接受域相同。
最大16x16、1302字节全RGBA文件实际数值运行，四通道均覆盖全部256字节
值。独立原始pixel→file编码器及手工opcode锚点提供期待像素；主fetch/
commit/index计数10026/1840/187。包含恢复和取消探针的clocked RAM核验
为18200 byte、195 index、2028 pixel、2280 hash。18状态和6类chunk均覆盖，
最大首valid按五配置为87/167/327/1095/4167拍。

精确着色处理原始无向边覆盖/删除，完整32bit端点先验证，masked首token
仍拥有tag。FIRST/端点错误粘滞并drain至LAST，返回零payload；固定N个
顶点包括孤点，合法范围N1..10、TAG1..32。约定忽略范围内self-loop，服务
对象为simple graph。按数值递增子集计算独立性，再枚举包含最小顶点的
独立颜色类，最小化1+DP[剩余子集]；保存首个严格最优类并backtrace，返回
完整零起始颜色和精确色数。单同步邻接RAM及packed independent/count/
choice RAM，没有递归硬件或乘除法。primary oracle直接分配顶点颜色，
N1/N2/N4另用边子集容斥色多项式计数交叉核验，共122次，覆盖这三个N的
全部67个simple graphs。180正确图和36错误图中，核839个输出顶点、886
原始边、22822个完整DP字、839邻接行、216个精确首valid。843478次候选
扫描和94941次互补DP读取均与独立证书一致；最大N10真实数值运行，
最坏观察135680拍。1976274个blocked source周期均核保持，1585个被保持
token最终真实接受。19状态在N>1全部可达，N1不可达阶段显式alias START。

| 逻辑声明预算 | 默认RAM / 最大RAM(bit) | 默认scalar / 最大scalar(bit) | 计算延迟边界 |
|---|---:|---:|---|
| SG映射 |1536 /6144|232 /440|QUERY首valid<=2N，即默认32/最大64拍；后续片段间隔见合同|
| 有理逼近 |0 /0|185 /371|默认40/最大300拍，六配置边界均达到|
| QOI |6832 /20656|382 /418|5+3B+3P，即默认1223/最大4679拍|
| 精确着色 |3392 /15460|125 /172|4*3^N+2N-2+4E，即默认26262/最大236218拍|

着色E=1表示尾token触发真实对称边更新，否则为0；B为文件容量，P为像素容量。
这些数字是源级时钟寄存/读数据/输出及RAM逻辑预算，不是LUT/FF/BRAM/DSP
测量。四包均单时钟、同步高有效reset、普通ready/valid，无CE/CDC；源保持
到接受或reset，背压时全部输出稳定。reset在目标观察后、下一active edge
之前立即取消，并完成完整fresh事务。外部等待可无界；延迟边界只计内部
计算，不能当作实测硬件吞吐。资源风险与限定域取舍见各README，所有
内存推断、物理适配、Fmax、功耗和板级吞吐均未验证。

## 来源及真实失败历史

四包均在RTL前做实际语义去重和固定上游完整源码/完整许可证只读检查。
参考分别为FreeBSD `e9e4115a0bb41416bf5e1277627fc6c565073972`的
subr_sglist.c与完整COPYRIGHT/BSD条款；CPython
`2dc476bcb9142cd25d7e1d52392b73a3dcdf1756`的Lib/fractions.py及完整PSF/
历史LICENSE；QOI `ffb2d2cb74a1de60819b21b939f7209aa53e91c1`的完整qoi.h及
MIT LICENSE；NetworkX `4fa222d2fb157e1b7f8c753c9f92e5907d1ddeb4`的完整
polynomials.py及BSD3 LICENSE.txt。各SOURCES记录URL、版本、具体原始SHA
和独立实现边界。没有复制、改编或运行上游实现。A另独立全文复核QOI
源码/许可证及strict acceptance差异；无新增sibling、ROM、网络或vendor
primitive依赖。所有core files.f和完整示例均保留，SG/逼近/QOI另有example
files.f，B的6份和C的5份冻结fixture可离线使用。root LICENSE/NOTICE在支持
清单内。

QOI第一次：version PASS后core_syntax普通FAIL，原RTL中十六进制常量紧接
三目问号产生lexer歧义；非timeout，TB和仿真尚未运行。原计划
`fb91d4e89bcca5fdc3c27588196e8f30ab05709709261ba27c7e63addbdea758`、原收据
`90007a85acb0e85d6148533dbcfe32a73952f00f1d8c9871035d0ebdcf47786b`、原14
源hash和9个非fixture完整原文及2实际/19NOT_RUN保存在attempt_01.json。
修复RTL仅加词法空格，同时补显式repair gate和INDEX alpha文档表述。

第二次：前四child通过，最小配置仿真在frame46发现两个预期错误。两条
28byte输入超过MAX_BYTES27；合同要求容量status1优先，旧fixture错误期待
ending status5及相应work。RTL行为正确。原计划
`c368adf288c462611086a00026096aae9d32241d0c171c4ef091211373e11939`、原收据
`68d21a2e0b111a6a5831c869bd9d923b825a75a90a266218e6f09c1e32a853bb`、原15
源hash、所有14个普通源码/fixture完整原文及5实际/16NOT_RUN保存在
attempt_02.json。按协调裁定仅修最小配置frame46/47的期待status/work，
generator对应分支及绑定元数据。fixture全文SHA因此改变，不能称全文未变；
root独立解析五份旧新fixture，确认全部252文件/12911输入字节的完整byte/
LAST/tag序列、各帧长度/顺序及1922个输出token数量精确相同。其余四fixture
全文逐字相同。第三次相同刺激/配置/21child矩阵全部PASS，最大child0.391秒，
无诊断或timeout。两个FAIL标签未改，无PASS后源变更。

精确着色25条工具记录首次全PASS，最大child14.219秒。PASS后仅README
实测段及两项审阅措辞修正；原README/SOURCES、计划和PASS收据逐字保存在
history/qualification_001_docs.json，执行计划6209977...、原收据050d821...
和全部25commands/profiles/totals可重构。原RTL/TB/runner/输入/oracle均未变，
无工具或oracle重跑。SG与有理逼近在第一次合格后无源码改动。

本批实际93条包内工具执行=86条当前合格原记录+QOI两轮旧记录2+5。
archive中的原PASS副本和原FAIL收据引用均不额外产生执行。当前合格计数
不冒充旧失败仿真已经完成；所有原普通失败及未运行尾部可追溯。没有任何
缩减输入刺激、提高20秒时限或继承数值配置重跑。

| 当前收据 | SHA256 |
|---|---|
| SG映射 |`38fcbc6f914fd6bf5d45f268c25ec55fb171db5e45304ad9ffcbfec502f94bfa`|
| 有理逼近 |`8515573bf217acddfe20768580004a7cd31c688c3e02c05dee10c285dff5c969`|
| QOI |`65e636e70502c6ce17f2c34ca97c65acebfd243385d06723479e33ab4dc5d655`|
| 精确着色 |`34c144d2d26f39fc7e61ff74b9f8bb59c6e37642a0a2faaacfff414cc39d7279`|

## 冻结、发布和恢复

累计80包中79包有明确有限UNIT证据。B14 weighted_interval_schedule仍仅
LINT_PASS，首N1仿真20秒终止、TIMEOUT_NOT_RUN、零完成配置及后续NOT_RUN
不变，静态TB修复未重跑。B11面积开7/8数值配置，64x64编译通过但数值
超时；B12 GLRLM128x128、B13 GLSZM32x32、B14 GLDM128x128、B15 NGTDM
128x128及B16 Hausdorff32x32最大配置compile-only范围完整继承，不把本次
语法通过扩写为这些配置的数值通过。

A→root、B→A、C→B、root→C均CLOSED PASS。功能提交依次为SG映射
`28b5f5f60fa5a5d7125efcae724f1a6620a3b633`，精确着色
`d94dfb8c1363751758a967e8f5fe8ea75f03e9be`，有理逼近
`fa2cfa0d35816fd2af18d7f8a0e6b401d030f7a5`，QOI
`aa6f9e3ce76e452a1e9729bf3a159c533fe4945f`。未改旧包或共享RTL。

[B20清单](snapshots/source_20261105_b20.json)完整继承B19全部76包对象、792
包内文件、12支持和dependency map。新增57文件（11/17/18/11），其中54
当前文件、3archive；累计849包内+12支持，共861个冻结文件，80core+
81example共161tops、168个唯一生产源。检查器及默认UNIT门槛和旧显式
LINT-only规则不变，SECDED/divider/EDT来源提交不变。

源码冻结 `b2933a0b4e81a43421a815b6d2db495627a5ad88`。唯一一次隔离导出
检查exit0，Icarus -tnull通过161tops/168sources，编译child仍20秒，没有
重跑数值矩阵。[实际输出](snapshots/source_20261105_b20_check.txt)132行，
含80条包PASS和两条最终PASS。25组timescale警告/source note与B19全部
逐行一致，没有新增警告或其他诊断；stderr为空。仅CRLF→LF规范化。
清单SHA256 `4c43e4dcd5c1d703cd8df3f0b02faa14069a69e593c3999691e0d5d671df0b2b`，
检查输出SHA256 `48d7f30ee0c9a264ed88dd7370a5cab292827b7f097ff5eee5aaf49639cfd6c4`。

独立发布审计CLOSED PASS，无发现：861个冻结Git blob、76个继承包对象、
792个旧包文件与12支持文件Git OID、57新增文件范围及4feature祖先均独立
核对一致。161tops/168sources、79UNIT+1旧LINT、22配置/86合格记录、26拒绝、
523reset/763fresh及7条旧实际记录合计93次执行均从原stdout/metadata复算。
C两轮失败的原文/长度/SHA/NOT_RUN和五份旧新完整输入不变证明、root原
PASS及文档修正的全文重构链全部闭合，归档副本未重复计数。132行/82PASS、
25组继承警告、全部文档链接、receipt/feature/upstream/manifest/log引用及
README一致。审计全程只读，未编辑、暂存或执行checker/compiler/simulator/
oracle。发布前仅按审计认可将本预留段替换为实际结论。

实际唯一执行命令：

```text
python -B scripts/check_source_snapshot.py --ref b2933a0b4e81a43421a815b6d2db495627a5ad88 --manifest docs/snapshots/source_20261105_b20.json --compile
```

最终发布仅暂存本文、README入口和真实检查输出，串行提交，无push。原15项
tracked状态、21000未跟踪路径、goal.txt和原38稳定引用均受保护。Goal继续
active；本批是持续建设FPGA原生功能资产的本地检查点。

前批：[第十九批](IP_ASSET_BATCH_20261105_B19.md)。
