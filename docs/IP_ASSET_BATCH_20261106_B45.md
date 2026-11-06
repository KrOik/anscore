# B45：行情接收、双相干谱、透视纹理与 INT4 转置卷积

基线：`a0602fb2dac20db7c524297371a19f5f580980df`。本轮沿四个开发通道增加可组合的 FPGA 数据通路；用户的 ISP/视频、金融量化、DSP/测量、通信网络和低精度 AI 方向继续作为选题边界。

| 包 | 实际增量及入口 | 有限验证证据 |
|---|---|---|
| `cores/acceleration/int4_transpose3x3_stride2` | U8/INT4 3×3 stride2 转置卷积；两行缓存、四组邻域映射复用既有 subpixel/matvec/requantize；`files.f`，真实 RGB 解码组合为 `example/files.f` | 4 次准备、11 项 HDL、4 次仿真；35 次独立 direct-scatter 求值 |
| `cores/communication/soupbintcp_session_rx` | 有序、重组完成的 TCP 字节流上的 SoupBinTCP 服务器会话接收；MIT frame FIFO 验证后提交 payload；正式入口 **`followup01/files.f`** | 原准备通过、首语法失败并保留；独立声明顺序修正版 0 次准备、9 项 HDL、3 次仿真通过 |
| `cores/signal_processing/spectral_bicoherence` | 三频复数交叉双谱和精确能量归一化 Q16 平方双相干；共享串行乘法器、除法器；真实频谱帧选 bin 适配器 | 5 次准备、12 项 HDL、5 次仿真通过 |
| `cores/image_processing/perspective_uv_projector` | 正 reciprocal-W 的精确透视 UV 插值；原光栅覆盖→投影器→原索引纹理采样器 | 4 次准备、10 项 HDL、4 次仿真通过 |

本轮共 14 次数值准备，43 项 HDL 检查，其中 42 PASS、1 项保留的原始 FAIL，16 次成功仿真。不存在自动重试。SoupBinTCP 的修正采用独立审查、独立计划、独立执行锁；只前移既有声明，原模型、三份已生成向量、失败源码及日志均未改动。

每个包的 `DELIVERY.md` 和 `QUALIFICATION.json` 记录实际结果，并优先于冻结输入中的 SOURCE_ONLY 状态。源码、数值准备、测试台、依赖、执行器均经根审和独立同伴审；执行绑定精确源码/计划/审批哈希。子进程采用 20 秒执行、5 秒树终止、唯一 2 秒目标退出观察的边界。原始 PID、退出码和 stdout/stderr 先落盘，再解析结果；编译镜像留在原执行路径，禁止重新生成来替代原证据。

数值与接口测试覆盖各包列出的确定性样例、合法边界、反压与复位取消。覆盖范围以各包交付文件为准：最大参数编译、稀疏最大尺寸样例不能证明所有输入或完整最大帧吞吐。SoupBinTCP 不实现 TCP；双相干不是统计显著性或因果检测器；透视 UV 不实现近面裁剪或完整 3D 管线；转置卷积不提供训练精度证明。

成熟度为 `LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED`。综合、布局布线、STA、上板及 PPA 均未执行；不推测物理资源、时钟频率或功耗。

累计快照见 `snapshots/b45/source.json` 和 `structure.json`。继承的 176 个包对象及支持文件映射保持原样；本轮审计重新检查 canonical HDL 和四个新增包的正式文件、依赖与声明冲突。历史数值模型、回归、审计器未执行。旧提交树每条路径的 mode/type/OID 与本轮 raw/index/committed 字节的一致性，由精确暂存和独立 closeout 检查记录。保留的二进制镜像不进入 Git；既有自动清理拒绝记录继续保留，本轮没有删除动作。

首次静态快照审计因 C 回执不存在 `archive_complete` 字段而停止。其源码、计划、审批、退出码与原始输出全部保留。独立静态 followup01 只修正这一记录适配：通过与已封存源码清单完全一致的 25 项 current/archive 绑定证明归档完整；不修改原回执，不重新运行数值模型或 HDL。最终静态结果以 `structure.json` 及独立 closeout 为准。
