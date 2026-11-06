# B41：成交更正、相位稳定度、透明合成与全局池化

基线 `31a83135a22f845d85840524986895217567625c`，依照用户确认的
`goal.txt`，使用 root 与三个既有 Worker 的四个开发通道。以实际功能
去重为前置，外部固定官方源和许可证只读核验；所有实现离线可用，
不改成熟共享 RTL。

| 新包 | 功能增量与真实组合 | 有限检查 |
| --- | --- | --- |
| [trade_correction_ohlcv_state](../cores/storage/trade_correction_ohlcv_state/README.md) | BUST/CORRECT 后重算成交 OHLCV、VWAP 分子分母；实际 ITCH order state→成交统计 | 12 PASS，1 保留 FAIL，4 sim |
| [phase_allan_variance](../cores/signal_processing/phase_allan_variance/README.md) | 均匀相位样本的单 tau 重叠 Allan 方差；实际触发窗口→测量 | 10 PASS，4 sim |
| [rgba_porter_duff](../cores/image_processing/rgba_porter_duff/README.md) | 保留透明目标覆盖率的13种预乘 RGBA 合成；双实际索引纹理采样→预乘→合成 | 13 PASS，1 保留 FAIL，4 sim |
| [signed8_global_average_pool](../cores/acceleration/signed8_global_average_pool/QUALIFICATION.md) | 精确逐通道空间平均、一次 RNE；实际 INT4 两类分类 | 11 PASS，4 sim |

成交核保留全64位 match ID 的有限历史，BUST 保留 tombstone，避免已撤销
ID 被再次 ADD；只有 CLEAR 释放 epoch 容量。CORRECT 保留原 symbol 与
sequence。聚合只包含 active rows，open/close 按 `(sequence,match)` 全序，
价格和数量32位，volume38、notional70位精确。默认32/最大64条记录，224位
单口 RAM，另2N位状态，单32×32乘法分时共享。实际组合先执行原 ITCH
挂单更新，再记录 E 与 printable C 成交；统计失败会隔离整个组合 epoch。
BUST 不复活挂单，没有跨模块回滚，也不宣称全日行情容量或监管统计。
核心三配置1782核对响应、891个实际 future QUERY、10701保持拍及27复位。
实际组合89接受/84核对响应、42个 future QUERY、21个真实事件结果、
12次成交 ADD、3个隔离确认、6复位。

Allan 核计算 `S=Σ(x[i+2m]−2x[i+m]+x[i])²`，输出精确 S、K=N−2m、
`den=2m²K` 和 `RNE(65536*S/den)`。只支持单 m，无 sqrt、置信区间或
多 tau 扫描。调用者保证相位样本等时间间隔，源流握手空隙不代表物理
采样间隔变化。signed8..16、N3..4096、m1..64，单帧同步 RAM 默认512B/
最大8KiB；复用原串行乘法器和迭代除法器，不展开 m 或平方阵列。
实际 PRE0/POST255 触发捕获包含触发样本与后续255样本；处理期存在死区。
首跑4次独立 Python 准备、10个 HDL 子项全通过，184核对响应、248命令、
23992样本、68复位、4辅助算术故障及恢复、559保持拍与22476次输入 II1。
完整4096样本最大分子/分母均已运行；最长有限观察122935拍，不等同频率。

Porter–Duff 核输入已配对的预乘 RGBA8，包含 A 在内逐分量计算
`min(255,floor((S*Fa+D*Fb+127)/255))`。13种模式含 src/dst over、in、out、
atop、xor、plus；前置条件 RGB≤A，非法输入或模式产生保序错误 token。
plus 最大中间和130050，保留17位后饱和；不误用窄16位 `/255`。核心无
RAM，8个8×8乘法，三级全局停顿流水，源代码 II1。双实际纹理采样器组合
保持 alpha0/oob 透明 token，原子双发双收，完全排空 owned token 后才
转发管理命令。默认两个8×8纹理 RAM17408逻辑位；最大两个256×256为
1064960位，结构风险 HIGH，尚无物理映射证据。
四仿真9224核对输出、3306保持拍、1990输入空隙、14复位；两个核心配置
各检查全部130051个量化 total。首次归档准备还独立核对851968个 alpha/
mode 组合的3407872组极值及65536种预乘乘积输入。最大纹理规模只作语法
检查，实际组合仿真使用1×1与8×8。

池化核消费 NHWC 的 signed8 特征图，24位和精确覆盖65536个样本，保留
最小负值绝对值为 unsigned24，按幅值商余数 RNE 再恢复符号。只存每通道
和，默认384/最大1536逻辑位；输入同步读/加写 II2，共享一个24位整数
除法器，输出按 channel 排序。错误 LAST 立即取消，无输出、隐式 drain
或重放。实际四通道均值通过 XOR128/U8零点128 进入原 INT4 matvec，
权重为 `[1,1,0,0]` 和 `[0,0,1,-1]`，错误取消后重新加载 resident 权重。
首跑11/11 PASS、4 sim：143向量命令、136011输入、738核对输出、337
inexact、6裁剪分类值、133687次输入 II2、24复位与20个复位后新帧。
已跑65536像素单通道、64通道单像素；未跑最大4194304样本单事务。
输出延迟29拍和无阻塞通道退休间隔29拍属于静态源码推导，仿真专门测量
的是输入 II2；不把推导写成硬件实测速率。

所有新版本均为 HW_UNVERIFIED。每个 HDL 子进程20秒执行上限，进程树
终止5秒、排空2秒，失败立即停止，无自动重试。独立源码交叉审查覆盖
RTL、实际依赖、oracle、TB、runner 和明确有限计划；模型与 HDL 的调用
次数据原始 receipt 记录。未运行综合、PnR、STA、上板、PPA、合并编译或
继承回归。本批48个 HDL 子进程：46 PASS、2保留 FAIL、16成功仿真。

两个 FAIL 均立即停止，并以独立冻结计划修复。成交例原第11项失败：
重复成交隔离分支未复制失败子响应，导致 retained-entry 计数丢失；只在
该分支补 `capture_trade()`，再执行两项示例编译/仿真，未重跑三个成功
核心配置。合成核原第5项失败：首次全零 clear token 没有引发 `always @*`
系数块求值，RGBA 为 X；只改为保证 time0 求值的 `always_comb`，复用原
20份向量和算术审计，执行最大闭包语法与四组编译/仿真共9项，未重跑
旧核心语法变体。两个原 plan、失败 receipt、精确归档、日志及失败 VVP
均保留；两次恢复均未重新导入或执行 oracle，未改 TB/golden/数值容差。
Icarus 对 `always_comb` 常量选择给出扩大敏感集合的诊断，原始 stderr
保留；四个新仿真的 stderr 为空。

累计静态审计一次执行通过，保留160个父包对象与349份继承规范源，新增包
达到164；累计358份规范 HDL 源、360个模块声明，无模块命名冲突。本批
353份包内正式文件与4份快照/审计文档采用定向提交。
当前及历史失败源分别映射到实际执行归档，成功与失败映像单独校验；
快照的结构审计仅做读取、哈希与声明/依赖扫描，不导入旧 checker/model。

此前自动审批审查以“blocked by policy”拒绝临时文件删除，本批不绕过
该拒绝，也不再次尝试删除。成功 VVP 保留在任务目录并排除 Git；既有
失败映像及旧清理记录保持原样。持续开发目标保持 active。
