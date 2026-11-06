# B42：仓位预留、谐波测量、光学黑校正与子像素上采样

基线 `2e7a6fb51f32e525c1026c28d1f2f45e36545ebc`，按用户确认的
`goal.txt`，保持 root 与三个既有 Worker 的四个开发通道。开发方向对应
金融风控、DSP 测量、图像 ISP 和低精度 AI。root 实际实现上采样 RTL。
外部固定版本源和许可证只读核验，作为设计参考；未导入执行外部代码。
新包离线依赖完整，复用成熟模块，不改共享 RTL。

| 新包 | 功能增量与真实组合 | 有限检查 |
| --- | --- | --- |
| [position_limit_reservations](../cores/storage/position_limit_reservations/QUALIFICATION.md) | 分侧仓位预留、ticket 部分成交/撤销；实际风险门控 IOC 撮合 | 12 PASS，1 保留 FAIL，4 成功 sim |
| [spectral_harmonic_quality](../cores/signal_processing/spectral_harmonic_quality/QUALIFICATION.json) | 自动基波搜索、派生不重叠谐波窗、功率比；实际 IQ 功率输入 | 10 PASS，4 sim |
| [raw_optical_black_rows](../cores/image_processing/raw_optical_black_rows/QUALIFICATION.json) | 同行光学黑测量、裁剪与实际黑电平扣除 | 11 PASS，4 sim |
| [int4_subpixel_upsample2x](../cores/acceleration/int4_subpixel_upsample2x/QUALIFICATION.md) | resident INT4 逐像素映射与 2× DCR 重排 | 10 PASS，2 保留 TIMEOUT，3 成功 sim；完整最大行未验证 |

仓位核为每 context 保留 signed64 仓位和独立 unsigned38 买/卖 outstanding。
RESERVE 分别检查两个方向端点，反向订单不相互抵消；ticket 使用全64位 ID、
方向与剩余32位数量。部分 FILL 同时更新仓位和预留，CANCEL 只释放剩余量。
有预留时不允许 CONFIG/reconcile；普通拒绝不改状态，内部一致性故障使状态
失效。默认8 context/32 ticket、最大16/64，RAM 有效载荷5504/11008位。
实际组合先预留请求全量，再转发原撮合器的真实 fill，完成后按实际成交更新
仓位并撤销未成交预留。异常时隔离，没有跨模块回滚。核心三配置1718命令、
10308保持拍、651实际 future GET、18复位；示例21订单、19完成、8 fills、
4复位及2隔离确认。

首次示例失败保留原测试、日志和映像。独立重算确认：旧测试在仓位+1且卖侧
预留5时请求卖2，会得到端点−6，越过下限−5，RTL 正确拒绝。只把请求量2
改为1，并把无成交后的预期剩余量2改为1；此时端点−5合法，而限价10仍不能
成交 bid9。未改 RTL、oracle、其他预期或容差。独立冻结计划只执行该示例
编译和仿真两项，均通过，零新增模型调用，也未重跑成功核心或语法检查。
冻结修复说明中的日志 `Time 5375000` 按1ns/1ps对应5375ns；资格记录注明此
单位更正，未改归档证据。

谐波核只处理 FFT 正频率内部 bins，屏蔽后按最早最大值找基波，生成
`h*k0 ± radius` 的互斥窗口。输出各阶、基波、谐波、残余的精确功率，以及
RNE Q16 的 THD(F)²、SNR 和 SINAD 线性功率比；零分母以 valid 位表示。
不计算 sqrt/log/dB，不将残余功率无条件解释为纯噪声。N16..4096、阶数2..8、
半径0..2，默认512B/最大8KiB RAM，复用 peak_search、band monitor 和迭代
除法器；实际 IQ wrapper 复用 mag_squared。四次独立准备及10项 HDL 全通过：
262命令、214响应、8912样本、52复位、4故障注入、1070保持拍、8718次输入
II1。完整4096样本已运行，最长输入后等待2263拍，仅为有限仿真观察。

光学黑核依据传感器物理列奇偶分别测量合格遮光边界，采用共享17步除法器
进行正数 half-up 均值。count≤32、sum≤131040、舍入分子≤131056。缓存单
活动行，默认1280/最大6144位；实际 frontend 复用原 raw_black_level_stream
完成扣除与限幅，处理奇数裁剪起点的 CFA/offset 重排，并在 owned token
完全排空后更新行配置。调用者保证边界物理遮光，故障前输出均为 provisional。
逐行 capture/replay，不承诺连续传感器输入 II1。首次准备审查2837040算术
案例；11项 HDL 全通过，4仿真9898输出、160命令、144 DONE、20复位、
16取消、508行检查、3199保持拍与6366输入空隙。

子像素核对 NHWC U8 输入像素调用未修改的 resident int4_weight_matvec 及其
量化模块，生成4*Cout结果，按 `(2*dy+dx)*Cout+c` 做 DCR 2×重排。上扩展行
直接输出，下扩展行写入同步10位 RAM 后重放，包含 signed8 值、clip/inexact。
Cin1..64/default8、Cout1..16/default4、宽高1..1024/default64；下行有效存储
默认5120/最大327680位，无整帧 RAM。标记错误取消并清权重；错误1/2保留
配置，完成计数依据实际接受输入和退休输出。具名8→3 fixture 仅语法检查；
核心实际矩阵集成在有限仿真中运行。

首次最小/奇数配置成功，最大配置20秒超时。独立审查的后续计划不改生产
RTL、原 TB、oracle 或原向量：只按原字节记录分成其余25帧和完整第17帧，
并给 TB 增加进度日志。字节重组等于原记录。其余25帧通过，1024×1、
Cin1/Cout16 的完整最大行再次20秒超时。停止前日志仍显示进展，到输入842、
输出26936，未报告数值失配；这不能证明超时原因，也不能证明完整行正确。
该范围明确标为 **NOT_QUALIFIED_TIMEOUT**，没有继续拆分、加时或重试。
成功范围含64Cin/16Cout单像素，共77向量帧、3237输入、3080核对输出、
18复位。后续同一编译映像同时用于成功和超时仿真，两者证据均保留，
不能按映像数量推导仿真数量。

本批46个 HDL 子进程：43 PASS、1保留 FAIL、2保留 TIMEOUT，15个成功仿真。
11次原始数值准备，另一次字面记录切分不属于 oracle。每个 HDL 子进程
20秒执行上限、进程树终止5秒、排空2秒，失败立即停止，无自动重试。
源码交叉审查覆盖 RTL、实际依赖、模型、TB、runner 与有限计划。原失败和
超时源、计划、日志、向量、工具和映像保持可追溯。

所有新版本均为 HW_UNVERIFIED。未运行综合、PnR、STA、上板、PPA、合并
编译或继承回归。累计快照保留164个父包对象和358份继承规范 HDL 源，
新增后168包、368份规范源、370个模块声明；静态审计与提交结果见本批
结构快照和 closeout。这些计数仅用于离线依赖管理，不代表性能或成熟度。

此前自动审批审查以“blocked by policy”拒绝临时文件删除，本批不绕过或
重试删除。成功、失败及共享用途的 VVP 均保留在任务目录并排除 Git；
持续开发目标保持 active。
