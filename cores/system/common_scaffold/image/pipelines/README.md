# 图像处理流水线

`img_bayer_window_frontend_draft` 连接 RAW 流 → 同步双行窗口 → 外部窗口
Bayer 双线性核，输出裁边的 RGB888。尺寸为原图 W−2/H−2，支持 RAW
8/10/12 位；完成等待最后一个 RGB 像素被下游接受。具体配置、EOF 和
错误语义见同名 `.md`；小图组级参考回归已通过。

`img_color_pipeline_draft` 连接 AWB 增益 → CCM → 亮度/对比度 → Gamma。
`OUTPUT_YCBCR=1` 时再接 RGB→BT.601 全范围 YCbCr444，默认输出 RGB888。
`img_color_pipeline_auto` 已接硬件灰世界统计→求解→帧界增益，随后连接相同的 CCM、亮度/对比度、Gamma 和可选 CSC。手动入口保留。已完成组级编译/小图独立参考仿真，未综合或上板，资源与时序未知。

2026-10-17 生产 CCM 更新为四级弹性流水，Gamma 仍为一级同步 LUT 流水；相较旧 CCM，手动及自动色彩链的空闲端到端延迟增加三个 CE 使能沿，吞吐仍可达每个 CE 沿一个像素。每级仍通过 ready/valid 传递像素与标记，无需固定空白周期。独立模块和链路回归记录见 `../isp/evidence/production_ccm_v60_20261017/`。

所有像素和配置均使用共同 `clk_en`。数据传输为 `clk_en && valid && ready`，
SOF/EOL 随像素流动。各级独立的 `cfg_*_we` 和 `cfg_*_ready` 用于装载
影子参数；装载完后暂停输入（s_valid=0），保持下游可接收以排空管线，再
在独立周期握手 `cfg_commit_valid/ready`，使四级在各自下一个 SOF 接受时
提交。输入或任何一级仍有有效像素时提交 ready 为 0，避免各级选中不同帧。
提交后可继续送像素；本模块没有统一 frame-id 配置调度器。

Gamma 开启时，三个通道的完整影子 LUT 是全局提交的前提；没有完整表时
`cfg_commit_ready=0`。关闭 Gamma 的提交不要求装表。任何写入同周期均不
接受提交。`cfg_pending[0..3]` 对应增益、CCM、亮度/对比度、Gamma；
`cfg_error` 汇总 CCM/Gamma 粘滞配置错误，复位清除。没有完整命令应答
总线，控制器须处理 ready、pending 和 error，而不能只打一拍后假设成功。

自动入口的 cfg_awb_min/max_gain 在统计握手时取样，stats_flush 发布最后一帧；applied_gain/统计帧号反映实际 SOF 的应用值，awb_error 单独报告。求解有多周期延迟，连续视频可能跨多帧更新。最新结果邮箱防止无后续 SOF 时反馈死锁。auto 的 global commit 也检查 AWB 两级缓存的在途像素，避免配置越过旧像素。cfg_pending[0] 是内部 unity 增益级，自动增益状态另见 awb_update_pending。

运行 `python cores/system/common_scaffold/image/pipelines/run_group_regression.py`，脚本自动配置 OSS CAD Suite 路径，每次生成新的 build_group_时间证据目录。2026-10-15 结果为 ISP_GROUP_PASS：RAW8/10/12×四相、Bayer 标记/尺寸错误、AWB 求解与80帧连续反馈、多阶段色彩配置、CE/背压/输出稳定。日志、bench 和 JSON 均保留，不覆盖旧失败记录。这不是穷举验收，也没有证明整链满足 Tang 20K 的15K LUT/4 DSP预算。

去雾/HE/几何处理由其他 image 目录提供，需依据像素格式和带宽连接；本入口不自动创建任意处理图。依赖在 manifest.json 显式列出。旧 draft 文件名保留兼容。
