# 2026-11-04 第八批与累计三十二项源码快照

本批开发基线为 `99b5c8c1b3530775bb9dca0e5b4d1df07a014f68`，沿用
`development/ip-assets-20261104`。稳定分支 `stable/source-20261104-b8`
和固定标签 `snapshot/source-20261104-b8` 绑定累计三十二项。前七批十四个
稳定引用保留原提交；B8清单的直接前批明确为B7。

| 功能包 | 新增能力与复用价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [buddy_pool_allocator](../cores/storage/buddy_pool_allocator/README.md) | 幂次大小地址池分配、精确释放、递归合并、clear/query及空闲摘要 | `ab956de` | 5配置11723条记录，含10975响应及748复位标记；独立区间oracle、6809359次unit/head检查；71次立即阶段取消 |
| [chi_square_gof](../cores/signal_processing/chi_square_gof/README.md) | 频数流Pearson统计量，复用旧迭代除法，逐项RNE与共同总量检查 | `bc9c26a` | 6配置5078主oracle帧、18192输入拍，577有效结果；7次tie-up/216次tie-down，246有效帧不同于总和单次RNE；48次立即取消后各检一个fresh-empty结果 |
| [block_shi_tomasi](../cores/image_processing/block_shi_tomasi/README.md) | 梯度块精确结构张量、最小/最大特征值及阈值，复用旧eigen/sqrt | `28f158b` | 7配置558块、8959输入；signed2平面全部256种有序梯度对；独立整数惯性二分oracle；84次立即阶段取消 |
| [budget_knapsack](../cores/acceleration/budget_knapsack/README.md) | 精确0/1预算选择，value/cost/bitmap并列顺序，按原序回放每项选择位 | `97e1996` | 8配置692帧、3633输入/2917输出；507次穷举子集交叉；最大64项/255预算实际仿真；96次立即阶段取消 |

本批26组实际仿真配置、95条工具记录，包含33项预期非法参数拒绝，四包分别
4/8/11/10项；每工具子进程限时15或20秒。四包共40个本地文本文件，均为
可严格解码的UTF-8和LF。每包具备实际可综合RTL、依赖清单、最小实例、
明确接口/数值/错误/复位/反压契约、独立有限测试、当前源hash、架构风险评估、
语义去重与实际外源源码/许可证预检。临时向量和模拟器产物已自动清理。

## 调用边界与架构风险

- 地址池只管理元数据，实际payload RAM及地址单位换算由调用者负责。默认
  64个基本单位，范围1..1024；分配最低可用对齐地址，释放必须精确匹配live
  base/order。清空或复位丢弃全部旧ownership；没有generation，释放后重用
  同一base/order不能分辨陈旧请求。同步单读单写树在拆分时初始化两子，完成后
  才读取或下行；FREE/
  ALLOC祖先屏蔽旧节点，合并后更新最大空闲order。默认/最大元数据635/12282bit，
  不含payload，风险LOW/MEDIUM。序列化服务不承诺每周期一次分配。
- 卡方输出是 `sum(RNE((O-E)^2*2^F/E))`，每项最多半个输出LSB误差，整和误差
  不超过active/2 LSB；并非精确总和的一次RNE。0/0跳过，positive/0、总量不等、
  active<2、空帧及超容分别报告独立错误，错误帧统计量归零。count/active/mass
  描述前MAX_BINS个kept前缀；positive/0谓词还检查drain中的全部kept输入。
  df为无拟合参数修正的active-1，仅成功帧有统计含义；不输出p值或显著性。
  最大W24/M256/F24，mass32位、统计80位，平方乘法器和旧迭代除法时分复用，
  无数组或外部存储；风险LOW/MEDIUM。
- Shi–Tomasi采用uniform梯度块sum，不产生像素梯度、Gaussian窗口、滑窗或NMS。
  `STAT_W=2*GRAD_W+ceil(log2(MAX_SAMPLES))<=24`保留精确张量；默认signed9、
  64样本。复用旧对称特征值核心及sqrt，输出独立有符号饱和值、精确重复根标志、
  count及trace。corner比较的是**饱和前floor(Q*lambda_min)>threshold**；可以与
  直接实数阈值在一LSB内不同。最小值正饱和时仍正确判true，包括threshold为
  输出最大值的情况。超容拒绝整块，不发布prefix。共享一个梯度乘法器，每个
  保留样本三次乘法，无sample RAM，风险LOW/MEDIUM。
- 预算选择允许零cost/value/capacity；目标依次为最大总value、最小总cost、最小
  numeric bitmap。预算倒序及写前两次同步读使零cost仍只用一次；精确并列保留
  不含新最高bit的旧record，保证最小mask。每个原item都回放一次，选中与否由
  selected区分。首32位capacity在截断前检查，超容/非法capacity拒绝整帧并只发
  一个masked状态token；空帧也发一个状态token。正常首valid延迟为
  `C+2*K+3*sum(C-cost_i+1 for cost_i<=C)+4`，逐帧独立检查。默认/最大逻辑RAM
  3072/28672bit，无乘除法、外部RAM或厂商原语，风险LOW/MEDIUM。最大value和
  1073741760实际验证，没有饱和或截断。

四核心单时钟、同步高有效复位、无CE；旧CE-qualified流须明确适配。反压时
完整结果保持，复位取消当前工作与held结果。风险标签是结构判断，没有器件
资源、频率、功耗或RAM推断测量。状态为 **LINT_PASS + UNIT_SIM_PASS +
HW_UNVERIFIED**；最小实例/组合为 **INTEGRATION_CANDIDATE**。实例仅有语法
证据，组合核心仿真包含实际实例化的旧算术。没有综合、PnR、STA、上板或
扩大回归，也不把旧依赖的历史物理验证迁移到新组合。

## 独立审查与证据范围

A审预算选择、B审地址池、C审卡方、root审Shi–Tomasi，最终冻结版均无剩余
实质问题。审查覆盖内存所有权、位宽/符号、最低地址与合并、mask并列归纳、
逐项舍入及误差界、PSD与饱和前阈值、held字段和立即阶段复位。

地址池审查发现来源说明标题混入GBK分隔字节，已精确替换为ASCII并刷新该
文档hash，生产RTL/TB/runner未变，不需要重复仿真。四包最终全部严格UTF-8。
最终文档审查还将地址池拆分顺序准确写为先标父SPLIT、再初始化两子、完成后
才读取或下行；单事务控制保持部分更新私有，reset使根FREE。此文档修正提交
为 `fb8acd7`，没有生产实现改动，清单已绑定更新后的文档/回执hash。
卡方自查补强held结果与pending-source共存的EMIT复位探针，并补满容量后的
masked尾用例；相同六组有限检查重跑通过，生产RTL未变。共299个立即阶段
取消探针，观察到目标边界后直接reset_now，没有额外active edge；这不是任意
周期复位证明。地址池的748个向量复位标记另计，不与阶段取消混为一个数量。

地址池oracle用几何live区间和对齐候选，不镜像树；TB另检查可达节点及精确
block grouping。卡方oracle用Fraction及原生有理RNE，并逐有效帧检查误差界。
Shi–Tomasi以PSD/负定矩阵惯性二分确定整数特征值界，不复写RTL判别式/root
校正。预算选择oracle使用exact-cost字典与复制阶段，再对小K穷举全子集，
不镜像预算倒序原地DP；完整bitmap、回放及首valid延迟都核验。

固定外源见各包SOURCES.md：buddy-malloc为MIT，SciPy和scikit-image为BSD-3，
OR-Tools为Apache-2.0。实际源码与完整许可证均在实现前只读检查，没有复制、
翻译、执行或分发上游实现。新RTL/测试/文档按根LICENSE/NOTICE记录；地址池
另有独立Apache许可证。全部依赖已在本地，不需在线构建系统或运行下载。

## 累计冻结与离线恢复

[B8清单](snapshots/source_20261104_b8.json)绑定 **296个包内文本文件和10个
共享支持文件**。保留B7的28包及全部hash；四新包复用的divider、eigen、sqrt
均已在前批闭包，字节不变，不增加支持文件或复制算术模块。根LICENSE/NOTICE、
旧backend说明和许可记录继续导出。清单覆盖本轮审查的三十二项，不表示整个
历史仓库或每一种合法配置重新验收。

冻结检查提交 `bd223e1e193b8704db9edb44c3ea09b4bc4f918a` 通过：**32内核+
33实例，共65个top、71个唯一生产源文件**，只导出清单所列提交字节，在隔离
目录一次Icarus `-tnull` 编译成功。检查包/支持hash、源/依赖证据绑定、有限
记录、路径闭包及module重名；不重跑累计数值测试。实际输出直接保存于
[冻结记录](snapshots/source_20261104_b8_check.txt)。

成功编译仍保留20条已知timescale继承警告，没有其他编译诊断或错误。未为
消除警告改写既有无延时源码。最终发布提交只补本记录、检查输出和README
入口；冻结源码/清单/检查器保持不变。复查命令：

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b8 --manifest docs/snapshots/source_20261104_b8.json --compile
```

root仅暂存任务精确路径并串行提交，无push。原有未提交修改、删除及其他未
跟踪资产保留。Goal继续active，本批是持续开发的稳定检查点。

前批：[第一批](IP_ASSET_BATCH_20261104.md)、[第二批](IP_ASSET_BATCH_20261104_B2.md)、
[第三批](IP_ASSET_BATCH_20261104_B3.md)、[第四批](IP_ASSET_BATCH_20261104_B4.md)、
[第五批](IP_ASSET_BATCH_20261104_B5.md)、[第六批](IP_ASSET_BATCH_20261104_B6.md)、
[第七批](IP_ASSET_BATCH_20261104_B7.md)。
