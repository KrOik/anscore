# 2026-11-04 第十三批与累计五十二项源码快照

基线 `fcd2beef77f998da54801b91d74ce47946bee17c`，开发分支仍为
`development/ip-assets-20261104`。本批本地稳定分支为
`stable/source-20261104-b13`，annotated tag为 `snapshot/source-20261104-b13`。
此前十二批二十四个稳定引用保留原目标，直接前批为B12。

| 功能包 | 独立新增能力 | 本批合格有限证据 |
|---|---|---|
| [ram_prefix_table](../cores/storage/ram_prefix_table/README.md) | 运行时可变RAM前缀绑定，exact PUT/DELETE及最长前缀LOOKUP | 5配置6739主响应、238886主物理slot核验；70次立即取消与fresh恢复，额外743条已核setup/recovery命令 |
| [wilcoxon_signed_rank](../cores/signal_processing/wilcoxon_signed_rank/README.md) | 从原始配对signed样本求精确Wilcoxon双倍符号秩和、tie/zero诊断 | 6配置5004帧/15712输入，11484次rank、56016次比较、5004次精确tail检查；120次立即取消与解析fresh恢复 |
| [grayscale_size_zone](../cores/image_processing/grayscale_size_zone/README.md) | 等灰度最大4/8连通区域的gray/size频数矩阵，含灰度0 | 9配置948帧/12112像素/59872稠密输出，948次精确tail；172次立即取消与完整非恒定fresh矩阵 |
| [directed_dominators](../cores/acceleration/directed_dominators/README.md) | 从入口到节点的全路径必经点、immediate dominator、树深和被支配子树 | 6配置1759图/14608输入/6053输出，含全部1536种N3有根图；164次立即取消与完整fresh链恢复 |

本批共26组固定仿真配置、93条当前合格工具记录，包含30项预期非法参数
拒绝（分别8/6/12/4）。合计526次立即取消及随后完成的fresh恢复。所有
预定矩阵首轮通过，无失败、超时或fixture缩减。GLSZM最大32x32从工具前
即固定为compile-only，数值NOT_RUN；最大单轴32与最大面积16x12实际仿真。
主有向图N64固定8图及完整reset/fresh矩阵实际通过。B11面积开最大配置的
TIMEOUT/NOT_RUN及B12 GLRLM最大方形compile-only范围原样保留。

功能提交分别为前缀表 `c8bdba1`、符号秩 `a4fc312`、区域矩阵 `290c5b6`、
支配核 `8ba1344`，完整ID见清单feature_commit。

## 语义、架构和调用边界

- 前缀表的identity为unsigned MSB `(canonical_key,length)`，host bits忽略，
  /0与full-width均合法。PUT替换exact identity或最低空slot插入，满表仍能
  替换；DELETE只删exact identity，LOOKUP在包含key的绑定中选最长前缀。
  不会产生重复identity，相同长度命中同一key必为同一identity。PUT/DELETE
  对unsigned32 length先检查再窄化；LOOKUP/CLEAR忽略length。响应返回找到的
  **原value**及identity、found/inserted与操作后occupancy，新插入或miss时
  原字段为0。FULL/BAD_LENGTH不改变表。mutation在响应呈现前完成，held
  响应对应已提交表；CLEAR/reset均串行覆写完整RAM，下一命令等待整个操作
  与响应退休，没有rollback或持久化承诺。共享同步READ/CHECK扫描替代并行
  CAM，无host生成trie image或外部依赖。TB只核2*SLOTS+4保守首valid界。
- 符号秩核输入原始unordered signed `(x,y)`，显式W+1扩位求d=x-y，丢弃
  精确零差（Wilcox约定），非零abs(d)按升序平均rank。返回双倍W+/W-和
  min两者、被tie组覆盖的成员数；无p值、正态推断或Pratt/zsplit变体。
  容量按全部kept pair含zero计，RAM仅压紧保留非零项。超容drain不改变
  prefix诊断，不能修复“无非零样本”错误。任错rank/tie结果0，保留
  kept/nonzero/zero/positive/negative诊断及首tag。同步单读口RAM逐target
  比较所有非零magnitude，rank2=2*less+equal+1，按sign累加；无排序器或
  运行时乘除。最大差幅32bit，rank2 8bit、秩和13bit，最大总mass4160。
  正常tail精确2+n*(2n+3)，错误1周期；最大所测8386，逐主帧核验。
- GLSZM按输入MSB量化后，对完整矩形内等灰度的最大连通区域计数P[g,s]。
  static4/8连接，灰度0正常保留，无ROI/background忽略。输出全部gray与
  size1..N的稠密bin、全局zone数，满足Σs*P=N及每灰度面积守恒。固定N次
  SOF/EOL输入，首tag，marker错误独立sticky；错误帧完整drain后返回完整
  全零矩阵。packed gray/visited同步RAM、N项FIFO和histogram RAM分时工作，
  mark与enqueue同edge，避免重复入队；行列bounds先于neighbor读。CW可表达
  full-N queue/zone计数，只有已证明<N的地址才截断。正常tail精确
  (K+4)N+2R+3Z+1，R是全图in-bounds有向degree和，错误1周期；TB从独立
  union/geometry oracle核全部工作计数。输入II1、稠密输出II2；全域tail
  上界默认7561/最大30985，是结构计算而非实测频率。
- 支配核使用ordered presence赋值与删除，first root/tag在masked首token也
  捕获。unsigned32 root/edge检查后才窄化，独立错误任一个即整图单masked
  canonical错误，无prefix解。正常所有静态节点都有输出，不可达节点的
  祖先/子树mask及局部计数0，global reached count仍有效。root有self-only
  dominators，无有效parent，parent canonical0；非零root也如此。reachable
  非root的immediate parent是最深strict dominator，深度=domcount-1。
  predecessor/集合/summary三同步RAM，reachable bitset扫描后，domsets
  从reachable全集单调求交到稳定。simple avoiding-path证明两种sweep各
  <=N轮，观测max恰为1/2/3/7/16/64。ancestor链候选扫描独立于numeric ID，
  同时扫描列构造dominated subtree。首valid只核2N³+7N²+6N+12保守界；
  N64所选最长536838<553356，不是全域精确最大值或硬件频率承诺。

四包均单时钟、普通ready/valid、同步高有效reset，无CE或CDC；旧CE流需要
adapter。held全部字段保持，reset门控ready/valid并取消所拥有工作。恢复
必须按各契约重放，没有跨reset保留部分结果的承诺。示例仅语法检查，均
为INTEGRATION_CANDIDATE。

逻辑预算：前缀RAM默认2272/最大17408bit，scalar/read/output另257/486bit；
符号秩RAM272/2112bit；GLSZM RAM13056/109568bit；支配核RAM992/13568bit，
scalar/read/output另291/863bit。所有默认LOW、最大MEDIUM定性风险，均无
外部RAM/新sibling依赖、厂商硬核或动态乘除。未测LUT/FF/BRAM、DSP、Fmax、
功耗和器件适配。全体保持HW_UNVERIFIED，未运行综合、PnR、STA、上板或
扩展回归，没有继承旧资产历史硬件证据。

## 独立验证、审查与计数范围

A审root支配核，B审A前缀表，C审B符号秩，root审C区域矩阵。审查覆盖实际
RTL、参数/位宽、memory schedule、reset/所有权、独立oracle、资源预算、
许可证、离线清单及当前字节hash，不增加数值矩阵。
四组交叉审查均PASS；仅有下述两处文档措辞修订，无功能阻断。

前缀oracle以canonical区间dictionary筛选包含关系，排序选最长，不镜像RAM
slot扫描或RTL mask生成；每主响应后还核完整物理表、无duplicate/extra。
符号秩oracle排序并groupby，用Fraction平均ordinal rank，不镜像nested
less/equal扫描；含995个半整数stat、2344个tie帧、5473个tie成员、3588个
retained zero pair和2452个signed极值pair。GLSZM oracle全图相等gray边
union后聚合component-size频数，无visited/FIFO；穷举256种2bit2x2与512种
binary3x3图，独立核10816次seed/pop、62400次neighbor决定、42400次in-bound
及4026次histogram increment。支配oracle删除每个候选点后BFS重算可达性，
不使用predecessor求交；parent链再核ancestor set，100次确定性回放、1580
个unreachable记录及751个depth>1记录逐项匹配。

526次reset均在完整目标观察后立即断言，不多走active edge。覆盖同步读写
之间、commit/clear、rank双层扫描中段/末段、FIFO新/旧邻居与full-N边界、
dominator sweep/summary中段及真正held正常/错误输出与blocked source。
每次fresh完整核验：前缀多操作insert/replace/delete/fallback，符号秩解析
极值/tie，GLSZM亮角点/暗背景全矩阵，支配图全链ancestor/descendant/parent。
这些有限阶段探针不等于任意周期形式证明。

前缀表587836 trace clocks、515471 source-blocked和33530 held周期包含所有
非reset probe/setup/recovery/main活动；6739响应与238886 slot项只属main。
其743额外setup/recovery命令另列。符号秩与GLSZM主work/stall计数排除恢复；
root主frame/output计数排除恢复，stall/write/pass统计含恢复。两处只改文档
的审查修订分别澄清此前缀计数范围及“35个capacity-bounded random样本不
保证有非零差”的含义；更新README/report hash与packaging说明，未改生产
RTL/TB/runner/vector、未重跑数值。当前没有历史失败或超时记录。

SOURCES.md分别记录实际fixed源码与完整license只读预检：cidranger MIT、
SciPy BSD3、PyRadiomics BSD3、NetworkX BSD3。未复制、翻译、执行或分发
上游实现；新贡献用root Apache-2.0 LICENSE/NOTICE，前缀另附完整LICENSE。
实际semantic去重排除固定CAM/trie-step、独立样本MWU/KS、距离变换/CCL/
GLRLM与可达性/最短路/无向割点等近似命名能力。离线无需上游软件包或网络。

## 累计冻结与恢复

[B13清单](snapshots/source_20261104_b13.json)绑定每包feature_commit、完整
文件hash、当前有限证据规则和离线路径。B12旧48个package对象、support
files和dependency commits逐对象保持，旧超时与compile-only范围不变。
累计为499个包内文件与10个支持文件；本批新增42个严格UTF-8/LF文件。

冻结提交 `9e75eef4c5ff4f70a013e3208355fdcdc38c4913`，实际输出见
[冻结记录](snapshots/source_20261104_b13_check.txt)。
一次从committed bytes隔离导出的Icarus -tnull检查累计52内核+53示例、
105tops及111个唯一生产源文件，没有重跑累计数值测试。保留旧timescale
继承警告20条，无其他诊断，不为消警告改旧源码。
独立发布审计PASS：逐项核499+10个committed文件、42个新文件的功能提交
归属、全部旧对象/依赖不变、证据规则、105/111闭包及真实检查输出；未重跑
checker、compiler或数值测试。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b13 --manifest docs/snapshots/source_20261104_b13.json --compile
```

最终发布只增加本文、README入口与真实检查输出，冻结源码/manifest/检查器
保持。root精确暂存任务路径、串行提交，无push；原15项tracked修改/删除、
旧未跟踪资产、goal.txt及此前24个稳定引用保持。Goal继续active，本批是
持续功能资产积累中的检查点。

前批：[第十二批](IP_ASSET_BATCH_20261104_B12.md)（含此前批次入口）。
