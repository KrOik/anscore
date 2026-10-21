# AWB div3 full-feedback simulation

2026-10-17：完整反馈仿真 PASS，独立只读审查无阻断项。仅本目录新增测试和小型证据；生产 `auto/stats/gain`、冻结 `awb_div3_20261017`、既有黄金均只读。未综合、PNR、打包或板测。

复现（仓库根目录）：

```powershell
python -B .\cores\system\common_scaffold\image\isp\sim\awb_auto_div3_20261017\run_feedback.py
```

runner 检查五个只读源码 SHA，在本目录唯一临时子目录中生成 `img_isp_awb_auto` 副本，唯一修改为 `gain_solver` 的模块标识：`img_isp_awb_autogain` → `img_isp_awb_autogain_div3_candidate`。auto 的其它字节、statistics/gains 实例及其连接不变。Icarus 使用 `-g2012 -Wall`；实际编译和执行命令留在 `compile_*` / `simulation_*` 日志。

先查阅的已有测试是 `image/pipelines/run_group_regression.py` 的 `pipeline_case` 与 `feedback_stream_case`，以及 v65 `tb_image_awb_selftest_25k.sv`。它们覆盖基础反馈，后者使用旧 16 位 solver；连续流允许 raw/balanced 任一输出或屏蔽最终 frame-id。没有重复运行这些旧回归；本目录补充混色多帧、精确提交来源、覆盖 mailbox 和完整 32 位关联。

`tb_awb_auto_feedback.sv` 仅产生输入和边沿 trace；`check_feedback.py` 使用独立无界 Python 整数 oracle。它从真实接收的原始 RGB 计算每帧统计，从 solver 实际接收统计时的 min/max 快照计算整数 floor/clamp gains；按 gain 级接收的 SOF 更新配置，再用 `(pixel*gain+128)//256`、上限 255 生成逐像素期望。三个 gain pipeline stage 的乘法/寄存器细节、divider recurrence 和固定 solver 延迟均未复制到模型。

模型检查每次 stats-valid 的原始 sums/count/lines/frame/overflow，每个 solver 结果及错误位、每个输出 valid 的 RGB/SOF/EOL（包括背压），以及每沿 latest/staged/applied gains、完整来源 frame、sticky error 与 update_pending。复位建立新 epoch，取消旧 FIFO 和 solver 请求，不允许幽灵结果。

| SUM_WIDTH | 输入像素 | 精确输出 | stats 接收 / 结果 | SOF 提交 | latest 覆盖 | 同沿旧 latest stage / 新结果保留 |
| --- | --- | --- | --- | --- | --- | --- |
| 48 | 264 | 260 | 86 / 85 | 65 | 2 | 1 |
| 8 | 264 | 260 | 86 / 85 | 21 | 1 | 1 |
| 16 | 264 | 260 | 86 / 85 | 65 | 2 | 1 |

各轮 4 个未输出像素和 1 个未完成 solver 请求由明确的 reset 取消；模型逐项计数。8 位产生自然饱和溢出并拒收错误统计结果，故有效 gain 提交次数较少。每轮均验证 invalid-config 结果不会替换已生效的非中性 gain，零通道 bit3 诊断结果仍可提交；solver 忙时改变外部 min/max 不影响已接收统计的快照。

| phase | 场景 |
| --- | --- |
| 1 | 48 个不同色度帧，每帧 2–7 像素，周期 CE 暂停和输出背压，统计边界阻塞，最后 flush |
| 2 | 填满像素弹性 pipeline，在配置 A 等待 SOF 时把新 SOF 留在 stats bypass；前帧 B 发布、当前帧 C flush，使 latest 自然覆盖 |
| 3 | 有效 gain 后的坏 min/max、忙时配置快照、黑帧 neutral（即使 clamp 排除 256）、零通道有效诊断、8 位真实统计溢出 |
| 4–6 | 32 位 frame 高位、进位、符号位跨越和回绕；结果与 applied 来源完整比较 |
| 7 | CE=0 复位取消在途 pixel/stats/solver/配置，stray 非 SOF 像素的透明旁路与协议错误，关闭帧 flush、source VALID 阻止 flush |
| 8 | 旧 latest 入 staged 与新结果同沿到达，新结果必须留在 mailbox；之后 SOF 分别提交正确来源 |

phase 2 的 48 位证据明确得到来源 frame 0、1、2 的结果，最终 SOF 提交 **0→2**，frame 1 被覆盖；phase 8 提交 **0→1→2**，验证同沿保留分支。输出期望使用实际 gain 输入握手及规则规定的 SOF 提交，未强制候选与较慢 v95 在相同外部帧应用同一增益。

每轮有 11 次异步复位检查：在 negedge 拉低 reset 后 `#1`、下一 posedge 前，断言外部输出和 stat/result valid、pending、applied gains/frame/error 已清零；释放 reset 后仍保持 CE=0，再恢复运行。cycle trace 同时验证 CE 暂停和输出背压保持。

32 位计数高位和回绕通过明确的 TB-only seam 在 reset 后空闲时 seed `statistics.frame_id` 为 `0000FFFE`、`7FFFFFFE`、`FFFFFFFE`，随后正常接收/发布/提交。这验证位宽和关联，不声称自然运行了 2^32 帧。phase 8 使用冻结 solver 的最后完成边界作为输出释放时机，仅用于命中可达并发分支；所有预期数据和来源仍由独立模型计算。没有 force 结果、内部 gain 或 statistics payload。

边界：这是 AWB auto 组件仿真，未包含完整 Bayer/CCM/显示链或真实摄像头；48 位累加器在本次真实像素流中只达到小帧总和，高位大数的算术测试属于此前冻结 div3/solver 回归。stats collector 正常发布帧的 count 始终非零，本集成测试未注入 count=0；该错误接口已由隔离 solver 回归覆盖。没有新侧信道、物理时序或板端资格结论。

`feedback_summary.json` 保存逐配置覆盖计数和全部结果/提交事件。`trace_feedback_w*.csv.gz` 保存可复核的完整 pre/post 边沿证据，raw CSV、VVP 和临时 wrapper 都由 runner 的临时目录在退出时清理，最终 VVP/PYC/临时目录均为零。保留证据约 0.5 MiB，无波形、网表或大型板级副本。准确文件 SHA 和字节数见 `FREEZE_HANDOFF.json`。
