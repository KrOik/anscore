# B46：OUCH 订单回报、频谱延迟、覆盖率双线性与 INT4 通道激励

基线：`50b8d36a3ce65cae5c4b3ab4604fa24f3567204b`。本批沿金融协议、DSP 测量、图像渲染和低精度 AI 四条通道开发；用户指定的 ISP/视频、金融量化、DSP/测量、通信网络与推理加速继续决定选题。

| 包 | 新增能力与实际组合 | 有限检查入口 |
| --- | --- | --- |
| `cores/communication/nasdaq_ouch42_server_rx` | OUCH4.2 S/A/U/C/E/J 六种服务器消息；80 字节缓存及长帧排空；组合原 SoupBinTCP 与帧 FIFO，完成回复原子联结 | 原 `files.f` 与 `example/files.f`；修正测试台与有限计划位于 `followup01/` |
| `cores/signal_processing/spectral_group_delay_fit` | 连续 FFT bin 相位展开后的全精度 OLS 延迟 Q16、相位线性拟合残差；复用串行乘法和除法，真实 I/Q→atan2→拟合 | 原 `files.f` 与 `example/files.f`；独立复位测试台修正版位于 `followup01/` |
| `cores/image_processing/rgba_bilinear_coverage` | 保留 straight-alpha×color×双线性权重全精度，最终一次 RNE 输出预乘 RGBA；实际索引纹理四邻域读取→过滤→Porter–Duff | `files.f` 与 `example/files.f` |
| `cores/acceleration/int4_squeeze_excite_frame` | NHWC S8 帧缓存→GAP→两级 resident INT4 matvec/ReLU→精确 hard-sigmoid→帧通道缩放；真实 RGB 引导配置组合 | 核心 `files.f`；示例正式清单 **`followup01/example/files.f`**；合格测试台位于 `followup02/` |

本批共 15 次数值准备、57 项 HDL 检查，其中 53 PASS、4 项原始 FAIL，19 次成功仿真。四个包均取得 `LINT_PASS / UNIT_SIM_PASS / INTEGRATION_CANDIDATE / HW_UNVERIFIED`；独立修正计划没有重新生成向量。

各包的 `DELIVERY.md` 与 `QUALIFICATION.json` 给出实际成熟度、边界和证据位置，优先于执行前冻结 README/manifest 的 SOURCE_ONLY 描述。所有原始失败输入、控制、向量、子进程记录和 raw 输出保留原字节；修正以独立源码、独立计划、独立双人审查和独立执行锁完成，复用原向量，不执行旧模型或旧 helper。

已保留的失败均属于检查入口或测试台：SE 的嵌套文件清单递归、SE 与 OUCH 的 fscanf 尾部返回值兼容、频谱拟合测试台撤销复位后未等待组合信号稳定。失败不计为成功仿真；具体通过数量以最终静态快照与各包交付记录为准。单个执行子进程限 20 秒，树终止 helper 限 5 秒，目标退出观察最多使用唯一 2 秒区间；PID、退出码和原始输出哈希先持久化，再解析计数。

所有数据通路具有实际 RTL、完整离线依赖、接口契约和最小组合示例。覆盖范围包括确定性算术、错误回复、复位取消、背压与所有权；最大参数语法检查及稀疏最大尺寸向量不构成完整最大帧吞吐证据。OUCH 只是协议子集且无交易账户状态；带宽 OLS 不是任意非线性相位的逐点群延迟；图像最大纹理仅稀疏查询；SE 未运行同时最大像素与通道规模的整帧。

成熟度维度保留 `HW_UNVERIFIED`；综合、布局布线、STA、上板、PPA、历史完整回归与全仓 HDL 合并编译均未执行。默认资源预算与风险标签来自源码审查，没有物理资源、时钟频率或功耗实测。旧提交路径的 mode/type/OID 以及新增 raw/index/commit blob 字节一致性由独立暂存与 closeout 验证，保留二进制不进入 Git。既有自动清理拒绝继续保留，本批没有删除动作。

为保留已执行 CRLF 原始证据，暂存使用 `hash-object --no-filters` 与 `update-index --index-info`，随后逐字验证 blob。Git 子进程以空属性树、禁用自动换行与全局/系统属性的临时参数核对本批路径，并检查相关属性均未指定；不改永久配置，不设置 assume-unchanged 或 skip-worktree。工作区干净状态限定于该原始字节检查作用域。
