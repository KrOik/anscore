# 2026-11-05 第二十四批与累计九十六包源码快照

本批基线 `b6af9a4c6b843924c6eb4d45b2fdf362dcc8b333`，开发分支
`development/ip-assets-20261104`。本地稳定分支为
`stable/source-20261105-b24`，附注标签为 `snapshot/source-20261105-b24`。
此前46个稳定引用保持原样，无push；Goal继续active。

| 功能包 | 新增能力 | 已完成有限证据 |
|---|---|---|
| [ram_byte_write_coalescer](../cores/storage/ram_byte_write_coalescer/README.md) | 帧内按byte最后写入合并、完整校验后输出稀疏strobe并逐项等待ACK |6配置，960主帧，132立即reset与完整fresh，1446主/1505fresh外部写请求|
| [exact_binary_permanent](../cores/signal_processing/exact_binary_permanent/README.md) | 运行时0/1矩阵的精确永久式，即完美匹配计数 |6配置，742主帧，192立即reset与完整fresh，336576逐subset证书|
| [grayscale_isocontour](../cores/image_processing/grayscale_isocontour/README.md) | 灰度半整数等值线弦图，精确有理边交点及双线性分支判定 |9配置，2736主帧，226立即reset与完整fresh，329659完成记录|
| [min_cost_flow](../cores/acceleration/min_cost_flow/README.md) | 任意容量有向多重图的指定量最小费用流与全部原始边流量 |6配置，1775主帧，317立即reset与满容量fresh，1900完整流最优性证书|

本批27组有限参数配置、612条当前合格工具记录（24/213/143/232），含32项具名
预期参数拒绝（10/4/8/10），共485个仿真子进程。6213主帧和867组立即取消/完整
恢复各有明确边界；本批每组恢复各完成一帧。所有compiler/simulator子进程硬限20秒。
原失败另实际执行7条（A4/C3）；当前及原失败共619次包内矩阵工具执行。原A20/C140条
NOT_RUN不算执行。四包均有有限UNIT证据，全部HW_UNVERIFIED。无综合、PnR、STA、
上板、继承矩阵重跑或扩展回归，示例只具备语法/实例化证据。

## 功能、表示及工程边界

字节合并核使用完整unsigned64 byte地址；keep有效时先验证地址域再窄化。同一
byte最后接受值获胜，按首次出现的aligned beat顺序发布，每个distinct beat只发
一次请求，未激活lane为零。完整LAST以前没有外部写作用；FORMAT/RANGE在drain
期间继续累积，容量溢出后仍校验输入。非法帧规范零结果且不写；合法帧即使某次
ACK失败仍继续剩余写，最终给出issued-beat错误bitmap，不重试。仅适用于普通
幂等RAM，不承诺MMIO顺序、帧写原子性、coherence或rollback。reset取消未完成
peer ACK需由系统协调；此前已接受的写作用可能保留。主/恢复共1092响应，954真实
下一帧接受、1104首valid检查、9752269 owned-row核验均来自固定原矩阵。

永久式核按原始行序接收恰好N个kept二进制行，用两个同步单口RAM服务ascending
subset DP。每个subset依赖少一个bit的prefix minor；0/1乘法是选择加法，无数据
乘除。N<=12且12!=479001600，最大29bit。独立Ryser/Mobius oracle与小规模直接
排列计数校验不复制DUT RAM调度。742主帧、192满容量fresh、934精确延迟、336576
minor证书及同数整bank核验、1935179 RAM reads均闭合。654真实内部跨帧接受；
N12主job各一帧，没有内部跨帧接受；六配置合计42个held-reset offers取消后，由完整
fresh恢复。

等值线核在首像素捕获t+1/2和tag，固定W*H像素收齐后才发布。SOF/EOL/upstream
错误独立sticky，错误只发规范零summary。输出节点为共享grid-edge ID及未约分
num/den，同一边在邻接cell中逐bit一致。四交点cell以完整Q判分支；Q0使用统一
level+epsilon极限断开高值区域。输出是精确边交点之间的直线弦，不宣称等于曲线
双线性等值线；没有全局loop排序、面积或polygon接口。独立Fraction临界点及
完整边界/内部degree、非交叉证书与原2736主图/226恢复图逐项一致。完成主输出
34601、fresh输出295058，共329659；另25284个取消owner的已退休prefix须随reset
丢弃，不能计作完成帧或完整输出。855120 reads、339486 products、169715 deciders
及2962精确tail检查均已执行。stored fixture总记录并非完成输出数量。

最小费用流核的原始费用均非负，内部残量反向边允许负价。完整unsigned32命令
source/sink/limit及边端点在窄化前检查，保留平行、反向、自环及零容量原始ordinal。
F=min(target,maxflow)，短缺正常；完整求解及cost累加后按原ordinal发布全部边流量。
不承诺某个字典序最小的最优流向量。三个同步单口packed bank服务串行Bellman-Ford、
父路径回溯及独立replay，最后复用一个最大8x8乘法累加费用。距离宽度覆盖所有
relaxation临时链，不能仅按最终简单路径缩位。独立oracle先做无权可行流，再全局
负简单环消除；每个实际流向量另以全部source-side cuts、容量/守恒/费用和
Floyd-Warshall残量无负环证书核验，1520主例另穷举全部流分配。主6178/fresh3769
记录全部退休，1721真实下一命令接受、317满容量恢复、1900合法流证书、9947记录
均闭合；反向残量读取983次、反向augmentation写8次，实际最大首valid25643拍。

| 源级结构 | 默认/最大RAM bit | 默认/最大scalar bit | 周期及风险 |
|---|---:|---:|---|
|byte coalescer|1088/4352|153/296|单同步packed bank，零backend read；LOW/MEDIUM|
|binary permanent|4160/118928|87/159|tail=3+(2^N-1)(N+3)+2E，默认/最大4856/110580；LOW/MEDIUM|
|isocontour|2048/49152|202/302|summary tail=3+11cells+2segments+4ambiguous，最大75414；LOW/MEDIUM|
|minimum-cost flow|699/1530|297/349|串行整数augmentation保守界默认9794334/最大81022262；latency HIGH|

这些是声明/周期预算与定性风险，不是LUT/FF/BRAM/DSP、Fmax、功耗或适配测量。
四核都采用单时钟、同步高有效reset及普通ready/valid，无CE/CDC。payload RAM不
bulk reset，由新事务完整所有权覆盖。外部停顿可无界，现有CE-qualified stream需
独立adapter。每包都有完整files.f及实例化示例，生产闭包无需网络或Python依赖。

## 原始失败与封存

A原首轮4条工具均rc0/空stderr，p0 TB已完成160主帧和15恢复；严格runner因Icarus
最后的`$finish called at ... (1ps)`通知未识别而总FAIL，后20 child NOT_RUN。完整
原24源、计划、seal、receipt及原p0文本汇编产物都已保留。root先审归档，再限定
runner只接受固定路径/行317、唯一、位于PASS后最后一行的通知，并增加原归档/
hash/24commands/20s守卫和沿革。RTL/TB/prepare/12fixtures/原plan不变；具体diff
核验后唯一attempt2全24 child通过。原FAIL仍为FAIL。

C原首轮version/core语法通过，example编译rc0但缺自身timescale导致警告；严格
零诊断规则判FAIL，其后140 NOT_RUN。原77源及plan/receipt/NOT_RUN完整81文件封存。
root核验原归档和具体diff后，只授权example增加一行timescale、runner守卫/reseal
和README沿革，原DUT/TB/prepare/MATRIX/66fixtures/143commands/20s全部不变。
唯一修复尝试全通过；原FAIL不被覆盖。

A归档`failure_archive/attempt_01/artifacts/p0.vvp`是120959字节UTF-8 Icarus文本汇编，
含3757个CR、无NUL，SHA256为
`0b6b3747d90b739ba53d5022b2a252db99e5e157ca1476441555fb31a2ee4fd3`。
为保留原归档字节，root只在本地`.git/info/attributes`加入唯一精确路径的`-text`，
没有修改任何PASS包。raw/filtered Git OID均为`74549c2e6753ed8d49c2eada9d5113c32063a726`。
该路径因既有`**/artifacts/`忽略规则而被精确显式纳入；没有force-add其他未授权目录。
此本地属性不随clone继承；commit blob、`git show`及`git archive`保留逐字节原始内容，
在新checkout重新add该证据前需配置同一精确`-text`。这不是生产依赖或新工具执行。

四向只读环审A→root、B→A、C→B、root→C封存后闭合。不得因发布而重跑任何数值矩阵，
也不得修改已PASS的实现、测试或原始失败归档。具体hash、固定来源完整文件/许可证、
接口和有限覆盖边界见各包SOURCES、README、plan、seal、receipt及累计清单。

A收据的原始总标签为`PASS`，其余新包为`UNIT_SIM_PASS`。累计清单只对A显式指定
`status_alias={raw:PASS,maturity:UNIT_SIM_PASS}`；checker硬白名单仅接受这一精确两键
映射，并要求原收据标签严格等于PASS及required maturity严格为UNIT_SIM_PASS。
随后仍无条件检查原equal.status、完整totals、24children、10具名reject、6数值完成
marker、6profile和全部committed source hashes。未改写原收据，无alias旧分支不变。
纯Python格式检查通过实际A及canonical分支，10个错误alias/原标签/缺记录或marker/
错totals负例全部拒绝；C对具体checker diff独立只读审查通过。没有重跑数值矩阵。

## 累计闭包与发布检查

累计96包=95份有限UNIT证据加1份继承LINT-only候选。清单逐对象保留B23的92包、
1445个包文件、12份support和原依赖映射；本批新增664包文件=56/219/162/227。
累计2109包文件+12 support=2121个冻结文件。既有终止TIMEOUT、compile-only及
LINT-only边界不变。新包均无跨包生产依赖。

实际串行feature提交顺序如下。每次只stage本包的精确路径，完整核验index blob的
SHA256后提交并恢复空index，没有目录级误纳入。

| 功能包 | Feature commit | 文件数 |
|---|---|---:|
|minimum-cost flow|`ed82cbc7f67843d56fb27ea5e28c8a8d7837880c`|227|
|isocontour|`3ddca4185daa4cba09b9e3805b28e7164c7f5823`|162|
|binary permanent|`8cdc05fe97ccefd24b4821313c03dbe70635f65c`|219|
|byte coalescer|`1ec4619f513f0be4722f120fc9e91dd1efc39964`|56|

源码冻结提交为`a7dec1eba94f585d230220a42dcfd6d96b332448`，仅提交累计清单及
已独立审查的checker标签兼容分支。checker SHA256为
`7be567021d705c49ff0c90b55d4f8f0bc870ec55e0b60b1989ea8fab1607713f`。
唯一隔离检查实际执行：

```text
python -B scripts/check_source_snapshot.py --ref a7dec1eba94f585d230220a42dcfd6d96b332448 --manifest docs/snapshots/source_20261105_b24.json --compile
```

退出0、总计16.813秒，156行中98行PASS；外层stderr为空。隔离编译覆盖193个top和
200个唯一生产文件，compiler child仍硬限20秒。58行既有timescale诊断与B23逐行
相等，没有新增诊断。未重跑B23或任何旧数值矩阵。

- 累计manifest SHA256：`3fbf847f794caf0d2581fa36e0353600378ff8dd9a00ee96a76aa18a1fa65a6c`
- 原始check log SHA256：`cc4d599c6f802ba33d8b5333df0c1359b03576b9ba25f19f5020501e463e525d`
- A当前seal / receipt：`81641e0377ad761421d180615dbbcf09859f8166c82d9f528730c5d445b2aad5` / `27216e397c88d81eef0f7c156653e4858b177da8b07d3c4a39052f9c3fcdaa8b`
- B当前seal / receipt：`c1f3a114d2efab2f16aecf02195c97385e98d29e16b797f6ca1d0e3cbf11022e` / `bb8e169f335855cffeec4aef561c79f7ee6e68cb5de0652bfd77042e5b2a191d`
- C当前plan / receipt：`31a04ea2e3cfb3e3b2cee46233745689fadd1a8f8cfb38bf2ae80ec59a952efc` / `d5ed190df655904c87f2aa97930c358f1b66d9daca6c8a77f9078f05483f680d`
- Root当前seal / receipt：`f5120a9525a674ac3d587cccd25d12b5b3cc2430ee765bc5d6c86cc6ed197158` / `efb654b3d02fe2336d8e523692cb3ddea159974364976f50eb1191b974ac4a34`

最终release直接继承上述freeze，只增加本页、README批次入口和原始check log。
新stable分支和附注tag指向该release，旧46引用的raw object/type/peeled commit保持
不变。原goal、15项用户tracked改动及原21000非忽略untracked路径的NUL/LF双hash
受保护；无push，Goal继续active。
