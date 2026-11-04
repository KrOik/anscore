# 2026-11-04 第十二批与累计四十八项源码快照

基线 `d35ce742b34ffa7afebffe0b9f6705a825f469e1`，开发分支为
`development/ip-assets-20261104`。本批稳定入口为
`stable/source-20261104-b12` 和 annotated tag `snapshot/source-20261104-b12`。
此前十一批二十二个稳定引用保持原提交；直接前批为B11。

| 功能包 | 本批实际新增能力 | 当前合格有限证据 |
| --- | --- | --- |
| [multiflow_token_shaper](../cores/system/multiflow_token_shaper/README.md) | 多流独立描述符队列、运行时桶配置、实时时钟补充与eligible轮询整形 | 5配置，18969时钟，1574描述符及68配置；216908次逐流ledger/queue核验；75次立即取消与完整fresh恢复 |
| [ks_histogram_distance](../cores/signal_processing/ks_histogram_distance/README.md) | 两组原始频数的精确经验CDF最大距离、双向极值和最早key见证 | 6配置，5226帧/12844输入，4371次row与10420次product核验；108次立即取消与解析fresh恢复 |
| [streaming_glrlm](../cores/image_processing/streaming_glrlm/README.md) | 真实灰度raster的四方向最大等灰度游程长度矩阵，无frame RAM | 9配置，900帧/21702像素/132656稠密结果，39338次extension与900次精确tail检查；89次立即取消与完整fresh矩阵恢复 |
| [directed_reachability](../cores/acceleration/directed_reachability/README.md) | 有向图全点对reflexive可达性、SCC成员与代表、双向reach计数及cycle/DAG标志 | 6配置，695图/30806输入/3910输出，含全部512种N3有向矩阵；124次立即取消与完整fresh空图恢复 |

四包共26组固定合格仿真配置、97条已完成合格工具记录，包含33项预期非法
参数拒绝（分别10/8/11/4）。合计396次立即取消，每次随后完成fresh恢复。
本批没有超时或缩减超时fixture重跑。GLRLM最大128x128按首次工具前确定的
范围仅做语法编译，数值仿真NOT_RUN；128x1与1x128实际仿真，不可推断最大
方形也已仿真。B11灰度面积开最大配置的TIMEOUT/NOT_RUN记录原样保留。

功能提交分别为整形器 `163a091`、KS `d59597c`、GLRLM `27d9515`、有向图
`afc7756`；完整提交ID在清单各feature_commit字段。四包共41个UTF-8/LF文件。

## 接口、算法与可用边界

- 整形器每流有一个独立描述符slot；数据与cost/tag保持到真实输出握手，
  已选owner仍占有slot，只有退休时扣credit并前移RR。全局QUANTUM按真实
  时钟运行，held输出期间仍补充；tick先饱和加，再退休扣除。选择仅使用
  edge-before credit，低credit流不阻塞其他eligible流。零cost或大于capacity
  的描述符以BAD_COST退休且不扣token。配置target有pending时等待；配置
  response ACK才提交，target ingress在事务期间阻塞，其他流继续。
  unsigned32非法flow、initial/rate超capacity或enabled零capacity被拒绝。
  配置commit优先于同edge tick。rate0且cost>initial的合法pending可以永久
  等待，也阻止其target配置；只能协调reset恢复，不能声称无条件活性。
  无payload队列、分组边界、字节速率或物理时间频率承诺。
- KS输入是共同signed严格递增key流及两组unsigned原始频数，不是已算CDF。
  以共同分母TA*TB输出精确绝对及正/负极值；相等绝对极值保留最早key，
  零距离用首kept key、方向0。无p值、阈值决策、约分或舍入。四种错误
  emptyA/emptyB/order/overflow独立；任错全部统计和见证为零，保留bounded
  prefix bins/TA/TB诊断。超容drain仍检查每个kept key的顺序，零/零bin
  也参与顺序与见证索引；超容mass不能修复prefix空总体。同步单读口RAM与
  共享TW步shift/add乘法器完成分母和逐bin交叉乘积。最大product46bit、
  signed contrast47bit。每正常帧精确tail为TW+2+n*(2TW+4)，最大6425周期；
  错误为1周期，均在所列fixture检查，不是硬件频率结果。
- GLRLM按MSB量化为2^GRAY_W灰度，0也是普通灰度；水平、垂直、主/副对角
  分别统计最大连续等灰度run，单像素方向保留。稠密输出direction/gray/
  实际length，包含零bin和每direction总run数；每方向Σlength*count=N。
  固定N次输入，首tag，SOF/EOL错误独立sticky；任错drain完整帧并输出完整
  全零矩阵，不发布prefix纹理。三条同步line history，无frame RAM；每个
  prefix先增新长度bin，再减原长度bin，因此边界无需额外flush。D缓存
  覆写前的旧word，A预读x+1；row/column边界排除旧前驱。四独立histogram
  bank分时RMW，无RAM读写冲突模式依赖。输入II5、输出II2、tail5周期；
  连续服务间隔5N+2D+HDEPTH是结构推导，未当作实测benchmark。
- 有向图的ordered edge最后presence赋值生效，支持删除及显式self-loop；
  全部N1..64静态顶点含isolates。unsigned32端点先检查再截断，任一kept
  错误整图只发一个canonical masked错误。正常输出每node可达与SCC bitmap、
  最小顶点代表（不是dense编号）、size、全局SCC总数、含self的前/后向reach
  计数、正长度cycle与全局DAG标志。reflexive对角线恒真，显式self-loop另
  存，删除loop不删除零长度self路径。同步row-RAM串行Warshall后扫描互达
  关系与summary RAM，全部global信息完成后输出。非self输入RMW为II3，
  held完整结果不变，后续记录always-ready每3周期；首valid只核保守界
  4N²+6N+8，不宣称精确全域延迟。

四包均单时钟、普通ready/valid、同步高有效reset，无CE/CDC。连接原CE流需
adapter。reset gates ready/valid并取消所拥有事务，恢复的内存初始化/覆盖
范围见各README；没有跨reset继承旧句柄或部分结果的承诺。所有示例只具
语法证据，标为INTEGRATION_CANDIDATE。

资源预算属于结构判断：整形器全部flow state默认428/最大3632bit，scalar/
control/output另158/312bit；KS RAM1280/8192bit；GLRLM RAM28544/127488bit；
有向图RAM816/9920bit，scalar/read/output另263/741bit。均无外部RAM、厂商
硬核或新sibling依赖。默认LOW、最大MEDIUM是定性风险，未测LUT/FF/BRAM、
DSP、Fmax、功耗或器件适配。全体仍为HW_UNVERIFIED；没有综合、PnR、STA、
上板或扩展回归，也没有继承旧资产历史硬件证据。

## 交叉审查与证据边界

A审root有向图，B审A整形器，C审B统计核，root审C游程矩阵。检查范围包括
实际RTL、参数/位宽、同步RAM时序、held所有权、reset、独立oracle、离线
manifest、来源license、声明存储预算及hash绑定。没有为交叉审查扩数值矩阵。
四组交叉审查及独立发布审计均PASS；审计另核旧对象不变、当前文件与功能
提交一致、显式证据规则、离线闭包和实际冻结输出，没有新增工具或数值重跑。

整形oracle用无限精度逐时钟ledger、每流FIFO历史与modular rank选eligible；
TB比较每流全部token/config/queue及控制结果。KS oracle对完整归一化mass
map独立查询每个key，用Fraction计算，1510例另以展开raw sample和bisect
交叉核验，不镜像RTL prefix乘法引擎。GLRLM oracle从几何边界抽取完整line
并groupby最大等值段，不使用prefix增/减或streaming history；全部2x2双bit
与3x3 binary图穷举。有向图oracle用BFS、iterative Kosaraju和Kahn判定，
不用Warshall；检查每bit/字段，90次same-final-graph确定性回放。

reset均在观察到完整目标后立即断言，没有先走另一个active edge。包括
配置ACK前后、zero-rate pending、held正常/错误输出及真实blocked source、
乘法中点/return、histogram同步更新、内存clear中段、闭包pivot中段与SCC
reverse scan。每次完整fresh恢复的预期由独立oracle或解析式给出。主fixture
与恢复事务分开计数；stall计数具体是否含probe以各包回执为准。有限探针
不等于任意周期形式证明。

开发历史单独保留：整形首轮TB在reset后额外等待一拍造成reference phase
差一，仅修TB开始驱动时机；KS和GLRLM首次使用SystemVerilog保留字bins
导致语法失败，仅重命名内部变量。保留历史失败命令与旧source hash，原定
矩阵通过后才发布当前PASS，不混入97条当前合格记录。本批无timeout重试。
root有向图原定矩阵首轮全部完成。

各SOURCES.md包含实际语义去重、固定外源文件、完整license只读预检及hash：
verilog-axis MIT、SciPy BSD3、PyRadiomics BSD3、NetworkX BSD3。未复制、翻译
或执行上游代码；新实现按root Apache-2.0 LICENSE/NOTICE，整形另附独立
LICENSE。离线使用无需下载或上游Python包。

## 累计冻结与恢复

[B12清单](snapshots/source_20261104_b12.json)逐包绑定功能提交、全部文件hash、
当前证据及source hash、明确的有限scope与例化入口。B11旧44个package对象、
support files及dependency commits逐对象保持，尤其保留面积开7/8仿真范围
与未完成检查。源码检查只从committed bytes导出，不读取未跟踪工作区资产。
累计闭包为**457个包内文件与10个支持文件**。

冻结提交 `e9bb0ff3b49e4be69aba510aa1a890a7e15b592e`，真实编译结果见
[冻结记录](snapshots/source_20261104_b12_check.txt)。
一次Icarus -tnull核验累计48内核+49示例、97tops、103个唯一生产源文件；
没有重跑旧数值测试。20条旧timescale继承警告原样保留，无其他诊断，没有
为消警告改旧源码。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b12 --manifest docs/snapshots/source_20261104_b12.json --compile
```

最终发布只补本文、实际输出与README入口，冻结源码/清单/检查器保持。root
精确暂存任务路径并串行提交，无push。原有15项tracked修改/删除、其他旧
未跟踪资产、goal.txt及此前二十二个稳定引用保持。Goal继续active；本批是
持续资产积累中的稳定检查点。

前批：[第十一批](IP_ASSET_BATCH_20261104_B11.md)（含此前批次入口）。
