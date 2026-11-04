# 2026-11-04 第十批与累计四十项源码快照

本批基线 `e2ccd5380052e92a5430e97b6fdbf0621a17503c`，开发分支继续为
`development/ip-assets-20261104`。稳定分支 `stable/source-20261104-b10`
和固定标签 `snapshot/source-20261104-b10` 绑定累计四十项；前九批十八个
稳定引用保持原提交，清单的直接前批为B9。

| 功能包 | 独立能力 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [dma_2d_burst_plan](../cores/storage/dma_2d_burst_plan/README.md) | 有符号行步长的二维字节矩形，整区预检后输出对齐且不跨4KiB的burst计划及精确mask | `548516f` | 5配置、2971描述符、77796输出；404716字节枚举、1385416行检查、1548穷举组合、304次page分割；70次立即取消及fresh单字节恢复 |
| [mann_whitney_u](../cores/signal_processing/mann_whitney_u/README.md) | 交错两组有符号样本的精确wins/losses/ties与U2，RNE量化rank-biserial效应 | `d161a22` | 6配置、5434帧/23065输入，4413正常/1021拒绝；121679次scan检查、5434次精确tail时序检查；55次立即取消及fresh恢复 |
| [label_adjusted_rand](../cores/image_processing/label_adjusted_rand/README.md) | 对齐标签raster的精确有理Adjusted Rand Index、无序pair计数和分区等价标志 | `d529ccb` | 8配置、966帧/149702像素，495负ARI/229零ARI；2x2全256双图、3x3共512分区对；95次立即取消及fresh singleton恢复 |
| [min_cost_assignment](../cores/acceleration/min_cost_assignment/README.md) | 稀疏有符号代价的方形最优完整分配，成功对偶证书与不可行Hall证书 | `fc1129a` | 6配置、267图/20092输入/1445输出；204成功证书、45Hall证书、193次小域排列交叉、47次确定性回放；108次立即取消及fresh完整对角分配恢复 |

本批25个实际仿真配置、100条工具记录，含39项预期非法参数拒绝，四包分别
10/8/12/9项。每个编译/仿真子进程限时15或20秒。四包40个本地文件严格
UTF-8/LF，包含真实可综合RTL、离线清单、最小实例、数值/接口/错误/复位/
反压契约、独立有限测试、源码hash、语义去重、实际固定外源源码及完整许可
预检、定性结构风险判断。任务向量与模拟器产物使用自动清理的临时目录。

## 功能边界与结构预算

- 二维DMA只生成地址计划，不搬运payload或实现完整AXI主机。每行的起点是
  base+row*stride，stride支持负数、零和重叠；不合并重复字节。row_bytes为
  unsigned32，rows为unsigned16，stride为signed ADDR_W+1。非空描述符先用
  16周期shift/add和端点极值证明每一行的全部字节均在地址域内，错误后行不会
  泄漏正常前缀。EXT_W=max(ADDR_W+18,34)保留窄地址配置下的巨大无符号长度。
  每burst取满足最大beat数和4KiB界的最大行前缀，首尾mask精确。任一维零给
  EMPTY；非空越界给RANGE，均为canonical masked状态。默认/最大内部scalar
  429/621bit，输出寄存器175/351bit，无数组、运行时乘法器或外部存储。
  最大row_bytes=0xffffffff的合法描述符仅检查首prefix再取消，未宣称完成
  全部输出；默认配置的65535行描述符实际完整结束。
- 两样本统计明确采用A>B为正方向，U2=2*wins+ties；保留前MAX_LEN个kept
  样本，每个新样本扫描全部旧样本，仅异组比较计入统计。精确计数不舍入，最终效应为
  RNE((wins-losses)*2^FRAC/(nA*nB))，绝对误差最多0.5输出LSB，正负1可精确
  表示。不提供p值、显著性或临界阈值。缺A/缺B/超容独立置位；任一错误
  拒绝整帧统计，保留首tag及有界prefix诊断计数。默认/最大同步sample RAM
  544/4224bit，复用已跟踪且与B9逐字节相同的fp_div_iter，最大39迭代位。
- ARI将标签0视为普通类别，需用共享keep排除背景；同ID可断连，任意重命名
  不改变分区关系。每两个kept像素形成一个样本pair，与空间邻接无关。输出
  num=2*(P*J-B*C)、den=P*(B+C)-2*B*C，不约分、不除法、不量化；空、单点及
  零den规范化为1/1。SOF/EOL及kept标签范围独立检查，固定WIDTH*HEIGHT计数
  不被错误marker重定界；整帧拒绝数值归零。K² joint与两个K项marginal
  同步RAM先读旧计数再写增量，kept II2、masked/drain II1。共享串行乘法器
  计算三个乘积；默认/最大逻辑RAM3744/88704bit，最大num80/den79位。
  1024²最大几何仅语法编译，实仿包括默认64²和1024长行/列。
- 分配核限N1..32方形问题，成本signed1..24。pair重复采用最后赋值，allowed0
  删除；kept的32位索引在截断前检查，错误整帧拒绝。标准串行整数Hungarian
  以sign-XOR平移成本使初始约化成本非负，以finite位表示不可达slack，不用
  伪无穷大。成功输出按row排序的完整置换和精确总成本；U+V<=cost、匹配边
  等号及sum(U)+sum(V)=total共同证明最优。失败Hall集合满足|R|>|C|且R的全部
  邻居在C中。未承诺词典序最小或矩形问题。审查补齐最后失败root的位宽证明，
  并把累计工作寄存器加宽至PW，原六组有限检查复核通过。默认/最大matrix
  1088/25600bit，scratch数组762/4186bit，另计scalar、read与output寄存器；
  无变量乘法或除法。大selector与约化成本加减比较路径仍需未来物理验证。

四核均为普通ready/valid、单时钟、同步高有效reset、无CE/CDC；连接旧CE流
需要adapter。一次只拥有一个事务，held输出全字段稳定。清表、RAM或算子
串行调度限制持续服务能力，无每周期一个图求解/帧/描述符的声明。风险均为
默认LOW、最大MEDIUM，是定性判断。状态为 **LINT_PASS + UNIT_SIM_PASS +
HW_UNVERIFIED**；示例仅语法检查，保留 **INTEGRATION_CANDIDATE**。没有综合、
PnR、STA、上板、PPA或扩大回归，也没有继承旧依赖的硬件证据。

## 独立审查与证据范围

A审root分配、B审A二维DMA、C审B两样本统计、root审C分区指标，冻结版均无
剩余阻断项。DMA oracle枚举所有行起点及实际字节/beat占用后分组，不镜像
RTL端点证明和head容量算法；TB另检查首/后继valid、mask、offset及held稳定。
统计oracle采用合并平均秩、值频数直方图和Fraction，不复写样本逐pair扫描。
ARI oracle用样本索引bitset分类所有后继pair，独立Fraction expected-index
归一化，不构造contingency递推；TB核对精确tail时序及中间符号扩展界。
其开发中仅修复了TB等待COLLECT未计K²清表的probe上限，生产RTL未变，原八
配置重跑通过，回执保留说明。分配oracle为独立Bellman-Ford残量最小费用流，
N<=5再穷举排列，输出逐项核验全部primal/dual/Hall条件；首valid检查保守界，
不误称精确周期断言。

合计328次立即阶段取消；检测目标边界后直接reset_now，无额外active edge。
覆盖清表、输入、同步读/写、算术中点、错误drain、augmentation及真正held
正常/错误输出与blocked offer等适用阶段。各包随后按自身契约检查fresh恢复：
DMA为单字节描述符，统计为fresh样本帧，ARI为singleton raster，分配为完整
零成本对角图。主fixture计数不含恢复事务，服务周期是否含probe以回执为准。
这些是有限状态探针与证书检查，不是任意周期/全部参数的形式证明。

外源固定提交与实际hash见各SOURCES.md：verilog-axi为MIT、SciPy与
scikit-learn为BSD3，均实际只读检查源码及完整许可证，没有复制、翻译、运行
或分发上游实现。新代码按root LICENSE/NOTICE；DMA附独立Apache许可证。
两样本统计唯一sibling依赖是已在累计导出中的recip_div.sv，其他三核独立。
无需在线构建系统、厂商库或新增共享支持源。

## 累计冻结与恢复

[B10清单](snapshots/source_20261104_b10.json)绑定 **376个包内文件与10个共享
支持文件**。B9的36个package对象和support逐对象保持不变。冻结检查提交
`1ad412c26eae9f7b3832930a8f75c29b9e63dd6c`：**40内核+41示例，共81个top、
87个唯一生产源文件**。仅从清单所列committed bytes构建隔离目录，一次
Icarus `-tnull` 编译通过；核验全部hash、源证据绑定、有限记录、离线路径
闭包和module重名，没有重跑累计数值测试。实际输出保存于
[冻结记录](snapshots/source_20261104_b10_check.txt)，保留20条已知timescale
继承警告，无其他诊断；未为消警告改写旧无延时RTL。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b10 --manifest docs/snapshots/source_20261104_b10.json --compile
```

最终发布只增加本记录、实际检查输出和README入口，冻结源码/清单/检查器
保持不变。root精确暂存并串行提交，无push。原有未提交修改、删除与其他
未跟踪资产保留。Goal继续active，这是持续积累中的稳定检查点。

前批：[第九批](IP_ASSET_BATCH_20261104_B9.md)（含第一至第八批入口）。
