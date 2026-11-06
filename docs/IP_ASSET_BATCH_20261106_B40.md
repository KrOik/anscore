# B40：多来源报价、脉冲时宽、色度抑制与量化残差

基线 `a68ca46815777c15c638c42a03899c83385bf052`，继续按用户确认的
`goal.txt` 和五类应用方向，以 root 加三个 Worker 的四通道开发。

| 新包 | 独立功能增量与真实组合 | 有限资格 |
| --- | --- | --- |
| [multi_venue_quote_state](../cores/storage/multi_venue_quote_state/README.md) | 多来源完整报价替换、来源 epoch/sequence、禁用与同价数量合计；两份实际 L2→报价合并 | 11 PASS，4 sim |
| [pulse_fraction_timing](../cores/signal_processing/pulse_fraction_timing/STATUS.md) | baseline/极性归一化、峰值邻近分数高度交点与 Q16 脉宽；实际触发环缓存→测量 | 10 PASS，1 保留语法 FAIL，4 sim |
| [chroma_median_suppress](../cores/image_processing/chroma_median_suppress/QUALIFICATION.json) | 保留 Y，由亮度局部极差门控 Cb/Cr 中值；实际 RGB→CSC→色度核→逆 CSC | 11 PASS，4 sim |
| [quantized_residual_add](../cores/acceleration/quantized_residual_add/QUALIFICATION.md) | 双路独立反压、逐通道非对称缩放，精确和后只舍入一次；实际 signed8 残差组合 | 11 PASS，4 sim |

报价核保留最多32 symbols×8 venues。价格 unsigned32、每来源数量
unsigned38，同价合计41位；锁定/交叉报价原样保留。全64位 epoch/sequence
采用非模严格次序；禁用整来源，重新启用需更大 epoch，旧行不会复活。
PROBE 是只读检查，外层 owner 保证其到 UPDATE 间没有穿插。真实双 L2 例
先检查，再提交本地簿，再发布绝对 BBO；本地或后续提交错误先禁用来源，
没有回滚承诺。默认/最大 RAM17408/69632逻辑位，宽 RAM 打包风险 MEDIUM。
这不是 UTP wire parser、监管 NBBO、撮合或自动 liveness 服务。
核心2252核对响应、1126实际 future QUERY、13512保持拍、24复位；真实例
71接受/66核对响应、33 future QUERY、21核对 L2 操作、2来源禁用、6复位。

脉冲核缓存 signed8..16 波形，按调用者 baseline 和极性找最早全局正峰，
从峰向两侧找最近的精确 `peak*F/256` 交点。阈值平台取贴峰的端点；缺侧
保留另一侧有效位置，width0。原串行乘法只计算一次阈值，原共享 divider
完成两次 RNE 插值。每侧数值舍入误差不超过半个 Q16 LSB，宽度不超过一个
Q16 LSB；不等同物理到达时间精度。默认/最大样本 RAM3072/65536逻辑位。
实际 PRE64/POST191 环缓存允许早触发和过量前史回卷，回放/测量期间有死区。
四仿真核对202记录、246命令、19998样本、48复位、4辅助算术故障恢复和
17943输入 II 检查；4096样本最长扫描有限观察8294拍。

色度核的候选中值和亮度门控均来自原始3×3窗口；中心 Y 始终保持，整圈
边界、薄帧和 disable 时保持全部分量。真实链配置原有两份 CSC，公共完成
还须等待最终 RGB 输出退休。复用原窗口和两份 median network，不改共享
RTL。窗口为 fabric register：默认行数组6288位，最大61620位；两中值网
另2560/3200数据位，门控旁路另250/310位，双 CSC 另计。最大风险 HIGH。
四仿真15264逐像素输出比较、7936 applied、2384 changed、4292保持拍、
136命令、128核对 DONE、16复位；最大几何只作语法检查。

残差核计算 `(A-za)*Sa+(B-zb)*Sb` 的精确和，再作一次 RNE、加输出零点
和 activation clamp。两个独立输入槽按次序配对，共享一个9×17乘法器，
27位和保留大数抵消；未在逐分支量化处提前饱和。原 requantizer 使用28位
输出避免加零点之前截断。默认/最大 metadata1232/4928位，无帧缓存。
LAST 错误不输出坏 pair，之前输出前缀由失败 completion 判为无效；没有
隐式 drain/重放。四仿真6684输出、58复位、5643保持拍，5485次核对后到达
输入至输出退休10拍、5324次无阻塞 pair II11拍。已跑4096 pixels 单通道
和64 channels 单 pixel，未将最大262144 pairs 合成一个事务运行。

全部44个 HDL 子进程留下43 PASS、1 FAIL，16次成功仿真；无自动重试。
脉冲示例最初 `-f files.f` 在 Icarus 的包含目录语义下递归引用自身，语法
检查失败后立即停止，没有产生失败 VVP。独立修复只展开三个既有依赖路径，
复用原四份向量，执行9个明确检查；已过的 default syntax 未重跑。
原 plan/seal、源、向量、stderr 和失败 receipt 均保留，失败类型明确为
`NO_IMAGE_SYNTAX_CHILD_FAILURE`。报价例一个不可达复位切点在首跑前静态
审查时由10改为实际写响应态9，重新冻结，没有先跑后改测试门槛。

交付审计纠正脉冲包的 Git 包装属性，避免 CRLF 证据被 clean 转换：当前
`.gitattributes` 改为 `* -text`，作为唯一主执行输入的非功能元数据例外。
两份旧归档属性原字节改用 `.gitattributes.executed.txt` 数据文件名，显式
`archive_path_aliases` 保留旧路径到新路径的映射。原 receipts/plans/seals、
所有 RTL/TB/oracle、日志及其他归档字节均未改，也未因此重跑 HDL。

CSC 头文件原工作树 CRLF 与基线 Git LF 的差异单独记录：执行 raw SHA、
checked archive、baseline blob OID/SHA、clean OID 和仅 CRLF→LF 的证明
分别校验，不修改共享文件。新增包来源检索只读固定官方版本/许可证，
没有复制或执行外部源码。全部依赖闭包可离线使用。

累计160能力包、349个规范 HDL 文件、351个 module 声明，无声明冲突。保留父
快照156个包对象、全部规范源基线字节，检查新列表/include/声明冲突及全部
当前/归档源、plan、vector、raw、tool 和成功 compile/sim 映像配对。
所有新版本均为 HW_UNVERIFIED，不运行综合、PnR、STA、上板、PPA、合并
编译或旧回归；不 push、不新建 tag，持续目标保持 active。
