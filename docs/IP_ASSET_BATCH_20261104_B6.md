# 2026-11-04 第六批与累计二十四项源码快照

本批开发基线为 `cf23435dbaca0dc895e2c0b5470418fb9e56c046`，继续使用
`development/ip-assets-20261104`。新稳定分支 `stable/source-20261104-b6`
和固定标签 `snapshot/source-20261104-b6` 绑定累计二十四项能力；前五批
十个稳定引用保留原提交。

| 功能包 | 独立增量与组合价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [ecc_scrub_scratchpad](../cores/storage/ecc_scrub_scratchpad/README.md) | 复用旧SECDED编解码，实现地址存储、读修复、受保护字节写与整RAM巡检 | `45eb766` | 5配置8576条记录、7470响应、2111018次原始码字比较；39个单错位置逐组覆盖，双错共865组含全部741种两位组合；最大4096字实际仿真；每配置8个阶段复位探针 |
| [symmetric_eigen2x2](../cores/signal_processing/symmetric_eigen2x2/README.md) | 对称实2×2矩阵的有序定点特征值、精确PSD/重根标志；复用旧迭代平方根 | `a8a56e9` | 7配置1347矩阵，含全部576个signed2/3矩阵、250个饱和命令、158个PSD及82个重根；独立integer-inertia oracle；63次阶段取消及7次初始化复位 |
| [polygon_raster_mask](../cores/image_processing/polygon_raster_mask/README.md) | 半整数像素中心精确奇偶填充且含边界；实际连接旧凸包得到ROI掩码 | `7ea1468` | 9配置1077事务、19388像素，含729个三点有序路径和24个方形点序；Fraction垂直射线与Jarvis凸包双参考；44次即时阶段取消；实际默认64×64已测 |
| [smith_waterman_affine](../cores/acceleration/smith_waterman_affine/README.md) | 双符号流的仿射缺口局部比对，返回精确最大分数和确定性终点 | `f90c147` | 8配置566序列对、220401个参考DP单元，含全部225个长度0..3二元序列对及24个超长错误对；最大256字符/65280分实际仿真；每配置8个阶段复位探针 |

本批共29组实际仿真配置，120条工具调用记录，含38项预期非法参数拒绝
（四包分别4/8/12/14项）。每个工具子进程限时15或20秒。实际RTL、最小
实例、完整接口与数值契约、独立有限测试、当前源码/依赖hash、语义去重和
只读外源许可检查均随包保留。没有下载或运行未知外源构建脚本。

## 调用边界与结构风险

- ECC存储为32位payload/39位码字，使用32位字节地址，须对齐且在本地范围内。
  单错修复在应答前写回；双错不改码字，partial write整笔拒绝，全字覆盖可恢复。
  零strobe不检测或修复。scrub串行扫全RAM，计数可达DEPTH并返回最低失败地址。
  复位取消事务并每拍清一字，清完前阻塞命令；scrub接受到summary valid为4×DEPTH周期，输出停顿另计。
  默认/最大RAM为9984/159744bit，风险LOW/MEDIUM。三位及以上错误可能漏报
  或误纠；控制器和codec自身不具备容错保证。
- 特征值输入为有符号整数对称矩阵。两个结果按真实数值升序，数学floor量化后
  独立饱和；PSD和重根标志取自原矩阵。旧sqrt的RNE候选通过完整平方比较恢复
  精确floor/ceil，避免近零小特征值被误判。无特征向量或一般非对称矩阵功能。
  一个迭代shift/add乘法器共享三次平方，无阵列存储；默认/最大风险LOW/MEDIUM。
  参数最大W/FRAC=24/24、RESULT_W=64已有限仿真，未宣称全域证明。
- 多边形按顺序闭合，奇偶填充支持凹形、自交、重复边；边界包含，不做抗锯齿。
  少于三顶点或任一capture错误均发布完整全零帧，超容不发布prefix多边形。
  每帧恰有WIDTH×HEIGHT个row-major像素；无ring/hole层级输入。点RAM默认/
  最大768/2048bit，一套14×14/18×18共享有符号乘法表达式，每有效像素串行
  处理全部边，风险MEDIUM/HIGH。两组65536像素几何只编译，未做全帧仿真。
  凸包组合还包含旧hull的额外存储/延迟，两级可持有前后两帧并按序背压。
- 局部比对使用MATCH奖励和OPEN≥EXTEND≥1的仿射缺口成本；输出最大分数及
  最早A主序/B次序终点。没有traceback、起点或CIGAR。两输入独立握手/结束，
  任一超长需排空两侧尾部并整pair返回零分错误；空侧为合法零分。硬件将负gap
  截零仍保持H结果，oracle则显式枚举所有缺口长度。默认/最大数组974/16416bit，
  一套DP单元每cell两拍，风险LOW/MEDIUM；不承诺连续逐拍序列吞吐。

四核心均单时钟、同步高有效复位、无CE，普通ready/valid与CE-qualified接口
需要明确适配。保持输出直到接收，复位可取消部分事务；各自恢复/排空规则见
README。全部核心为 **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**，组合与
示例为 **INTEGRATION_CANDIDATE**。风险只来自结构审查；未运行综合、布局
布线、STA、上板或扩大回归，没有实测面积、频率、功耗或器件适配承诺。

## 交叉审阅与证据边界

A审局部比对、B审ECC存储、C审特征值、root审多边形及凸包组合，最终冻结
版本均无实质问题。审阅核对了数值位宽、错误时整事务语义、依赖、held输出、
参考模型独立性和复位探针。阶段探针均在观察到目标边界后立即调用reset_now，
不额外跨越一个active edge；这不构成任意周期复位证明。

特征值自审曾发现EMIT探针在取消前多等三拍，已在正式提交前将下一offer提前
至计算期间，并在观察到EMIT时立即取消。同七组有限检查重新通过，生产RTL
没有因此改动。旧包证据和前五批快照没有被改写。

本批所有外源只作技术参考，均未复制实现。具体固定提交、实际源码/许可证
SHA256与本地依赖决策见各包SOURCES.md。Parasail引用是带附加引用条件的
Battelle自定义宽松许可，不标作BSD-3；LAPACK和scikit-image参考为BSD-3，
OpenTitan参考为Apache-2.0。新代码及复用本地代码按根LICENSE/NOTICE记录。

## 累计离线冻结

[B6清单](snapshots/source_20261104_b6.json)绑定 **218个包内文本文件和9个
共享支持文件**。旧sqrt和两个SECDED文件加入精确支持闭包，原hull直接引用
既有包文件，均未复制或改写。两个原先未跟踪的codec只纳入必需RTL，单独提交
为 `6d1ec5a`；没有带入其旧工具输出或其他未跟踪文件。根LICENSE/NOTICE与
已有backend说明/许可记录继续导出。

冻结检查在 `60ad57ef0018c80a2556bc3488f950fd75441043` 通过：**24个内核+
25个示例，共49个top、54个唯一生产源文件**，从仅含清单已提交字节的隔离
目录一次Icarus `-tnull` 编译通过。检查包含文件hash、有限记录和源码/依赖
证据绑定、路径闭包及module重名。它不重跑全部数值仿真，也不扩大有限证据。
原始输出直接保存在[冻结记录](snapshots/source_20261104_b6_check.txt)。

检查脚本现在同时保留成功编译的诊断。本次有18条timescale继承警告，来自
未显式声明timescale的无延时生产模块；没有其他编译诊断或错误。警告原文留在
冻结记录，不以清除警告为由改写旧RTL。此前日志和固定引用保持原样。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b6 --manifest docs/snapshots/source_20261104_b6.json --compile
```

后续发布提交只补本记录、实际检查输出及README入口，冻结源码/清单/检查器
不再变化。仅本任务路径暂存并由root串行提交，无push。原有未提交修改、删除
及其他未跟踪资产保留。Goal继续active，本快照是持续开发的进展检查点。

前批记录：[第一批](IP_ASSET_BATCH_20261104.md)、[第二批](IP_ASSET_BATCH_20261104_B2.md)、
[第三批](IP_ASSET_BATCH_20261104_B3.md)、[第四批](IP_ASSET_BATCH_20261104_B4.md)、
[第五批](IP_ASSET_BATCH_20261104_B5.md)。
