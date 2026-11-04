# 2026-11-04 第十一批与累计四十四项源码快照

基线 `c778301aa12d1b9bf4290b1a982f4c6325713fcd`，开发分支继续为
`development/ip-assets-20261104`。本批稳定分支 `stable/source-20261104-b11`
与固定标签 `snapshot/source-20261104-b11` 绑定累计四十四项；前十批二十个
稳定引用保持原提交，清单的直接前批为B10。

| 功能包 | 新增能力 | 功能提交 | 当前合格有限证据 |
| --- | --- | --- | --- |
| [range_lock_manager](../cores/storage/range_lock_manager/README.md) | 字节区间shared/exclusive锁，非阻塞获取、带owner/generation释放、原子替换及快照 | `4cba748` | 5配置1595命令；27213次全表/528120项观察、7675次byte-set交集、18次满池替换、103次替换回滚、9次generation退休；110次立即取消及fresh恢复 |
| [theil_sen_slope](../cores/signal_processing/theil_sen_slope/README.md) | 全部有限pairwise slopes的精确有理中位数，偶数population取两中位项平均 | `99d925e` | 6配置5200帧/15858输入，4429正常/771拒绝；5200次首valid检查、2426偶数population、1826个不同中位端点；155次立即取消及fresh恢复 |
| [grayscale_area_opening](../cores/image_processing/grayscale_area_opening/README.md) | 真实灰度raster的精确4连通面积开运算，保留达到面积阈值的上水平集结构 | `c385a03` | **7组当前仿真**，2501帧/43555像素，45366次scan、25023次pop、15534次回写，2501次精确tail检查；124次立即取消及single-bright恢复 |
| [graph_cut_structure](../cores/acceleration/graph_cut_structure/README.md) | 无向simple graph的割点、桥和删除每个顶点后的精确全局分量数 | `f32a3bb` | 6配置233图/19832输入/2627输出；独立删除每点/边核验，332个cut记录、106个含桥图、91次确定性回放；100次立即取消及fresh空图恢复 |

本批24组当前合格仿真配置、88条已完成合格工具记录，包含28项预期非法参数
拒绝，四包分别10/6/8/4项。另有灰度面积开运算最大64x64当前仿真的一项
**20秒TIMEOUT/NOT_RUN**及一次中断尝试，均不计PASS；最大配置语法编译通过，
没有缩小其RTL合法参数域。清单显式要求矩阵状态INCOMPLETE_TIMEOUT及这两项
独立记录，不能以主UNIT_SIM_PASS标签推断最大配置已通过仿真。

所有compiler/simulator子进程限制15或20秒，没有延长超时时限。四包40个新
文件严格UTF-8/LF，具真实可综合RTL、离线清单、最小例、接口/数值/错误/
reset/反压契约、独立有限oracle、当前字节hash、实际语义去重、固定外源
源码和完整license只读预检，以及定性存储/算子预算。

## 实际能力与约束

- 区间锁不是地址分配器或认证模块。共享读锁允许重叠；任一重叠exclusive
  阻止获取/替换，响应带完整冲突bitmap。REPLACE排除自身，失败保留旧锁，
  满池也能在原slot升级/降级/换区间。命令决策后只有响应ACK才修改表，held
  response仍对应未提交前状态；SNAPSHOT按命令接受时采样。slot采用最低
  可复用编号，generation不绕回，达到最大值后释放的slot退休，直到协调reset。
  reset可重用同一handle tuple，因此所有owner必须共同丢弃旧epoch句柄；
  owner字段不是身份认证。无阻塞waiter队列、公平性、自动超时或payload搬运。
  默认/最大表656/6208bit，内部scalar/read/write-stage为326/756bit，输出
  147/313bit。交叉审查修正了最初内部寄存器加总多100bit的文档错误，RTL未变。
- 鲁棒斜率输入为signed W-bit散点(x,y)，不要求x有序；相同x的pair排除。
  输出精确斜率分子/正分母、两个中位端点、有效/同x pair计数，不提供截距、
  CI、p值或舍入效应。无有限斜率与超容独立报错，任错整帧数值为零，保留
  bounded prefix诊断count和首tag。W1..16、MAX_LEN2..12；单读口样本/斜率
  RAM和插入排序复用一个W步shift/add乘法通路，比较交叉乘积及偶数平均均
  显式扩位。最大输出signed34/unsigned33；逻辑RAM默认892/最大2562bit。
  原定最大配置实际完成，最长已选tail延迟70522<=保守界79817，不是实测
  频率或全域最大值。旧未跟踪fraction_compare排除，未复制或更改它。
- 灰度面积开定义为g[p]=max({0}与所有l<=f[p]且4连通上水平集component面积
  >=A的l)。边界不wrap；0是普通灰度，矩形全域在阈值0连通。A1为identity，
  AN为全图最小值；无近似、固定footprint或外部marker。固定WIDTH*HEIGHT
  握手，首area/tag冻结，SOF/EOL/config错误独立sticky，任错完整输出N像素
  零raster而非部分过滤图。source/output/visited/queue四同步RAM，先mark再
  enqueue，逐个occupied正阈值BFS，达到A后replay该component。COUNT_W容纳
  N，level多一位可越过255；默认/最大RAM32768/143360bit。32x32已实仿，
  64x64当前增强TB只语法通过，仿真TIMEOUT。精确首valid式为
  max(f)+3+Σ(4N+7V+R+2Q)，独立图计数逐帧核验；17*N*L为工作量上界，
  没有视频速率声明。后续输出II2，reset后新输入覆盖src/out、每level清visit，
  queue只读当前已写prefix，无并行RAM reset。
- 图结构服务的全部N1..64静态顶点包含isolates。重复或反向pair为同一无向
  edge的最后presence赋值，0删除；self-loop忽略，不支持parallel multigraph。
  kept的32位端点在截断前检查，任一错误整图只发一个canonical masked状态。
  成功每node给出dense component ID、原始全局C、删点后C、degree、cut标志、
  bridge-neighbor bitmap和全局bridge总数。割点等价于删点后C增加；删除孤立
  点使C减少一而非割点。桥在两个端点各有一位，总bit数=2*bridge_count。
  parent+next-cursor隐式DFS栈和lowlink按序扫描，lowchild>discparent判桥，
  >=判separating child；root/nonroot删点公式分别C-1+children与C+separating。
  两N² bit同步RAM的镜像更新、桥双向写与输出读均分时；默认/最大memory
  512/8192bit，scratch数组544/3072bit，另计scalar/read/bitmap/output寄存器。
  全64种N4图、最大N64实际仿真；首valid仅检查3N²+7N+8保守界。

四核均普通ready/valid、单时钟、同步高有效reset，无CE/CDC。连接旧CE流需
adapter；一次只拥有一项命令/图/帧，held字段保持。定性风险为默认LOW、最大
MEDIUM，不是测得的LUT/FF/BRAM、Fmax、功耗或器件适配。全体保持
**HW_UNVERIFIED**；**LINT_PASS/UNIT_SIM_PASS**只适用于各自明确列出的有限
检查，灰度包尤其受七组scope限制。示例为仅有语法证据的INTEGRATION_CANDIDATE。
无综合、PnR、STA、上板或扩展回归，未继承旧库的历史硬件结果。

## 交叉审查与未完成检查

A审root图结构，B审A区间锁，C审B鲁棒斜率，root审C灰度面积开，冻结版无
未记录的实质阻断。锁oracle用独立dict/真实byte集合及half-open区间，TB另查
完整live table/ledger在ACK前后原子变化。斜率oracle按x分组作交叉y列表，
用Fraction频数分布与累计rank/L1中位条件，不镜像到达顺序pair枚举/插排。
灰度oracle降序激活union-find及pending成员首次达A赋值，不镜像逐level FIFO；
还核anti-extensive、idempotent、A1/AN。图oracle删除每点/边后独立set-union，
不用DFS/lowlink；逐项核所有字段、桥对称和分量影响。

合计489次当前立即阶段取消，每次随后完成fresh恢复；观察到完整目标后
直接reset_now，无额外active edge。锁含ACK前的pending mutation，斜率含
五种乘法role中点/return，图含半个镜像/桥写入，灰度含真正held正常/错误
像素及blocked下帧输入。灰度fresh使用single-bright/A1，强制清visit、入队、
replay且用暗点核覆写。主fixture不含这些恢复事务，服务计数是否含probe
以各回执为准；有限阶段探针不等价任意周期证明。

开发历史单独记录：斜率首轮TB变量声明顺序导致编译失败，仅修TB后原六组
通过，四条旧命令不混入当前21项。root图结构最大reset探针等待界漏算完整
输入捕获周期，仅修TB等待界，原六组通过，生产RTL未变。灰度初版零fresh
曾八组通过，但不覆盖visit/queue/replay恢复；增强fresh后只前七组通过，
最大64x64 vvp按20秒停止。一次试图缩减最大fixture的尝试已中断，原24幅
最大fixture恢复，不再执行数值重跑；该尝试不提供合格最大结果。八个独立
非法参数静态编译随后实际完成，不是对超时数值检查的重试。回执显式保留
incomplete_checks与interrupted_attempts，主矩阵为INCOMPLETE_TIMEOUT。

各SOURCES.md记录固定版本、实际source/full-license hash和许可决策：Linux
range helper为GPL2只读比较，SciPy/scikit-image/NetworkX为BSD3只读比较。
均未复制、翻译、运行或分发上游实现；新贡献按root LICENSE/NOTICE，锁附
独立Apache许可证。四包无sibling RTL、在线构建系统、外部RAM或厂商库依赖。

## 累计冻结与恢复

[B11清单](snapshots/source_20261104_b11.json)绑定 **416个包内文件与10个支持
文件**。B10旧40个package对象、support及dependency commits逐对象保持。
冻结检查提交 `7d20667b54c4894f2756243805a70e952e27a7ef`：**44内核+45示例，
共89个top、95个唯一生产源文件**。只导出committed bytes，一次Icarus
`-tnull`通过，核验hash、源证据绑定、显式超时范围、离线路径和模块重名。
没有重跑累计数值测试。实际输出在[冻结记录](snapshots/source_20261104_b11_check.txt)，
保留20条旧timescale继承警告，无其他诊断；没有为消警告改写旧源码。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b11 --manifest docs/snapshots/source_20261104_b11.json --compile
```

最终发布只增加本记录、实际检查输出及README入口，冻结源码/清单/检查器
不变。root精确暂存并串行提交，无push。原有未提交修改、删除与其他未跟踪
资产保持。Goal继续active，本批是持续资产积累中的稳定检查点。

前批：[第十批](IP_ASSET_BATCH_20261104_B10.md)（含此前批次入口）。
