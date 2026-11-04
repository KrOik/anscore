# 2026-11-04 第三批与累计十二项源码快照

本批新增四项原生能力。开发基线为 `ba0b98f`，开发分支继续使用
`development/ip-assets-20261104`。新稳定分支 `stable/source-20261104-b3`
及固定标签 `snapshot/source-20261104-b3` 收录三批累计十二项清单。
前两批标签保持原提交；[第一批](IP_ASSET_BATCH_20261104.md)及
[第二批](IP_ASSET_BATCH_20261104_B2.md)记录继续有效。

## 新增功能与实际证据

| 功能包 | 能力与独立增量 | 功能提交 | 有限检查 |
| --- | --- | --- | --- |
| [atomic_scratchpad](../cores/storage/atomic_scratchpad/README.md) | 单时钟共享字存储的原子读、交换、模加、逻辑、signed/unsigned min/max与CAS；返回旧值和写事件 | `3e77f24` | 4组参数4479命令，与独立整数内存模型比较；每组5个复位切点；最大参数仅编译，4非法参数拒绝 |
| [levinson_durbin](../cores/signal_processing/levinson_durbin/README.md) | 从自相关序列估计最终LPC与逐阶反射系数，提供明确逐步定点量化和失败语义 | `8f053ab` | 6配置137块/709个系数token，含47个预期错误块；8非法参数拒绝 |
| [streaming_binary_topology](../cores/image_processing/streaming_binary_topology/README.md) | 单遍计算FG4/BG8与FG8/BG4两种Euler特征、面积和cell-edge周长，O(WIDTH)存储 | `85d919d` | 7尺寸688帧，含2×2全部16种和3×3全部512种图像；独立图遍历及暴露边oracle；6非法参数拒绝 |
| [disjoint_set_union](../cores/acceleration/disjoint_set_union/README.md) | 通用节点集合FIND、UNION、SAME、CLEAR命令、代表元及分组计数；union-by-rank同步RAM架构 | `2510a69` | 7配置3876条独立partition模型命令，每配置14个复位取消切点；最大4096节点仅编译，4非法参数拒绝 |

四项均提供完整 `files.f`、最小实例化示例、离线确定性TB或其生成模板、
限时检查脚本、README接口与数值说明、结构风险、来源记录及
`verification.json` 实际命令/输出/源码摘要。每工具子进程限制15或20秒。
全部文本为LF，提交前核对源码哈希；生成TB、向量和模拟器二进制在任务临时目录
中创建并清理。没有将未运行检查记作PASS。

## 使用边界和结构审查

四项接口均为单时钟、同步高有效复位、标准ready/valid、无CE端口。
配置为静态参数；所有held结果遵守反压稳定性。CE-qualified旧接口需先适配。
详细顺序、时延、位宽和错误优先级见包内README。

- 原子存储器以READ、EXECUTE、COMMIT串行处理，提交前不接受第二条命令。
  复位重新逐字清零，初始化期间不接收访问。CAS比较失败不写；普通写操作即使值
  未变也返回写事件。加法按DATA_W位取模。默认8192bit存储，默认风险LOW；
  最大262144bit存储的目标适配风险HIGH，尚未映射。生产RTL明确一个同步写端口。
- LPC估计的通过范围是文档规定的逐阶段向零截断递推及一次能量乘积缩放。
  精确Fraction Toeplitz解只用于另行记录量化差异；没有放宽RTL比较容差，也未
  宣称与未量化解逐位等价或存在统一近似误差界。r0非正或量化反射绝对值越界
  时返回整块错误，仍发ORDER个全零token保持事务对齐。共享迭代乘除，ORDER≤8，
  默认结构风险LOW、最大宽度MEDIUM。
- 数字拓扑以一行bit RAM和带零边界的局部2×2统计直接得到
  `Euler4=foreground_components4-background_holes8` 与
  `Euler8=foreground_components8-background_holes4`。孔洞数不含连接帧外的背景。
  有符号Euler允许负值。帧按固定像素数推进，标记错误只置位。默认行存储64bit，
  风险LOW，目标RAM推断MEDIUM；不存整帧或逐像素标签。
- 并查集按rank选代表元，等rank取较低根ID；查询不压缩路径。初始化逐项建立
  singleton，union以单写端口依次LINK/PROMOTE。交叉审查促成显式写端口复用后，
  已重跑原7组有限检查。默认576bit，最大65536bit存储；风险分别LOW/MEDIUM。
  复位清空全部集合，拒绝ID不修改分组，CLEAR忽略输入ID。

风险标签来自结构审查，不是实测LUT/FF/BRAM/DSP、频率、功耗或板上吞吐。
所有内核状态为 **LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**；示例为
**INTEGRATION_CANDIDATE**。本轮未执行综合、布局布线、STA、上板或完整回归，
未借用旧资产硬件证据。未列出的参数、数据及控制组合不宣称通过。

## 累计稳定集合与离线检查

[累计清单](snapshots/source_20261104_b3.json)覆盖三批十二项能力、103个包内文本
文件、对应功能提交、依赖清单、示例及原始有限验证证据。前八项是选择性多播、
CDF5/3、SSIM、在线堆队列、有序完成缓冲、2×2求解、最大全前景矩形、稀疏行乘向量。
这是本次持续开发中已审查的清单，不表示整个历史仓库的资产均已重新验收。

功能提交后，本批冻结窗口仅处理源码完整性、依赖、命名、接口与索引。
[检查器](../scripts/check_source_snapshot.py)从固定Git内容核对文件摘要、有限
检查记录及其源码绑定，检查依赖和累计包间模块重名，再仅导出清单内文件到
隔离临时目录。十二个内核和十二个实例化顶层已在一次Icarus `-tnull`编译中
通过，不依赖未提交文件。输出保存在[冻结记录](snapshots/source_20261104_b3_check.txt)。

复查稳定快照：

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b3 --manifest docs/snapshots/source_20261104_b3.json --compile
```

该检查不重跑数值仿真，也不提升其证明范围。各有限单元检查入口见包内README。
没有外部RTL、include、ROM/权重数据、在线生成器或未声明构建系统依赖。
代码均独立原创Apache-2.0，完整稳定Git快照保留根LICENSE。外部预检的固定来源、
实际许可和未采用结论见SOURCES；未复制或改编候选源码。

本批已提交源码及必要依赖，任务临时产物已清理；原有未提交文件和删除记录未被
收录、覆盖或清理。整体Goal继续active，后续四通道在开发分支继续积累真实能力，
保留各批固定标签以便比赛前选取可追溯源码集合。
