# ISP RTL

本目录提供 Bayer、Gamma、自动白平衡、CCM、亮度/对比度和 RGB↔YCbCr 算术。已完成小图组级编译和独立整数参考仿真；Bayer、亮度/对比度、CSC 的限定组合已在 Tang 25K 完成板测；v60 CCM/Gamma 诊断候选也完成了限定输入板测；v65 AWB 候选完成了小宽统计、增益求解和自动反馈的限定输入板测；当前默认48位统计/求解器已精确回写v95并通过8套独立生产源测试和ISP组回归，v95四像素统计链与v91高48位ROM求解器分别完成三次独立SRAM/UART验证。整条流水仍未完成上板验收，不代表穷举验收。完整 RAW 入口为 `../pipelines/img_bayer_window_frontend_draft.v`，自动色彩链为 `../pipelines/img_color_pipeline_auto.v`。未改动现有板级顶层或 UART 合约。

## 统一像素接口

- `clk` 为唯一时钟，`rst_n` 异步低有效复位；`clk_en=1` 的时钟沿才更新协议状态。
- 输入传输条件为 `clk_en && s_valid && s_ready`，输出传输条件为 `clk_en && m_valid && m_ready`。两端必须共用相同的 CE。**本接口不是可直接连接任意 AXI Stream 接收端的接口**，不共享 CE 时需要适配器。
- 除 Bayer 原始输入外，`s_data[23:16] / [15:8] / [7:0]` 为 R/G/B，输出同理。色彩转换的 YUV 模式改为 Y/Cb/Cr，均为 8 位 4:4:4。
- `s_sof` 标记帧首像素，`s_eol` 标记每行末像素；必须与对应像素一起保持到输入传输发生。没有隐含的空白周期或自动 EOF。
- 亮度/对比度具有三级弹性流水，空闲且无阻塞时延迟三个 CE 使能沿，最大每个 CE 沿接受一个像素；配置在输入 SOF 接受时选择并随像素传递。AWB 增益同样为三级弹性流水；CCM 具有四级弹性流水、Gamma 为一级同步查表流水，其余像素单元输出具有一个可背压的像素寄存器。`m_valid && !m_ready` 时，数据及 SOF/EOL 保持。数据只在 valid 时有效；Gamma RAM 数据寄存器没有复位值，以保留同步 RAM 推断空间。
- 亮度/对比度已拆分为输入/配置捕获、26位有符号乘积、舍入限幅三段；CCM 拆分为配置/输入捕获、九个有符号乘积、三行求和、舍入/偏置/饱和四段，二者均保持 II=1。AWB 增益拆分为输入/配置捕获、8×16 无符号乘积、舍入饱和三段，II=1；CSC 等仍采用直接算术表达式，未完成全组时序、DSP 复用或资源约束优化。不能据此推断任意 ISP 顶层满足 Tang Primer 20K 集成预算。

## 帧边界配置

除 AWB 统计模块外，配置使用 `cfg_we` 写影子寄存器，`cfg_commit` 提交，`cfg_ready` 表示配置接受能力。仅在 `clk_en && cfg_ready` 时接受写入/提交；提交后 `cfg_pending=1`，阻止继续改动影子配置。

影子配置在**后续被接收的 SOF 像素**上成为活动配置，且该首像素已经使用新参数。提交必须早于目标 SOF 至少一个被 CE 使能的时钟沿；同沿提交/SOF 将等到下一帧。SOF 被背压时不会提前生效。普通寄存器模块允许同沿写入和提交；Gamma 为确保最后一个 LUT 写入已记账，要求写入与提交分开周期。

没有 SOF 时 pending 保持，旧配置继续生效。没有强制帧中切换和自动超时。`cfg_error` / `error` / `protocol_error` 均为粘滞状态，由复位清除。

## 模块与当前能力

| 模块 | 当前代码能力 | 参数或配置 | 尚缺能力 |
|---|---|---|---|
| `img_isp_bayer_interpolate` | 外部 3×3 邻域双线性插值；RAW 入口由 pipelines 的同步双行窗口提供 | RAW_BITS=8/10/12；四种排列；EXTERNAL_WINDOW 默认1 | RAW 前端裁去一圈；无边界填充、缺陷像素或高级去马赛克 |
| `img_isp_gamma_lut` | RGB 三通道双缓冲 256×8 LUT，同步读、背压、完整装载检查 | 通道、地址、值、enable/commit | LUT 曲线生成、RAW 高位宽表、多点插值 |
| `img_isp_awb_stats` | RGB 总和、像素数、行数、帧序号，RGB 一段旁路；计数器按 nibble 分组，统计输出背压 | SUM_WIDTH 默认 48，要求至少 8 位；flush | 白点筛选、分区统计、场景切换抑制 |
| `img_isp_awb_autogain` | 统计捕获后分级求和/target，再以共享迭代除法器求 Q8.8 增益，夹紧和异常响应 | 每笔统计采样增益上下界 | 无白点/场景分类 |
| `img_isp_awb_auto` | 统计→求解→SOF 提交增益，最新结果邮箱解耦连续帧 | SUM_WIDTH；flush；实际应用增益及统计帧号 | 求解多周期，连续视频反馈可跨多帧 |
| `img_isp_awb_gain` | 独立 RGB 增益、四舍五入和 0–255 饱和；三级弹性流水、II=1 | 无符号 Q8.8，复位 1.0 | 高位宽 RAW 增益 |
| `img_isp_ccm` | 有符号 3×3 矩阵、偏置、舍入、0–255 饱和；四级弹性流水、II=1 | 16 位有符号 Q6.10 系数；16 位有符号整数偏置 | 校准参数生成及高位宽格式 |
| `img_isp_brightness_contrast` | 以 128 为中心的对比度与 RGB 亮度偏移 | 无符号 Q8.8 对比度，10 位有符号整数亮度 | 独立亮度通道模式、曲线型对比度 |
| `img_isp_colorspace` | RGB ↔ 近似 BT.601 全范围 YCbCr 4:4:4 | `cfg_yuv_to_rgb` 方向 | BT.709/2020、有限范围、4:2:2/4:2:0、HSV/Lab |

### Bayer 使用边界

默认 `EXTERNAL_WINDOW=1` 使用窗口核。旧设置 `EXTERNAL_WINDOW=0` 显式拒绝：`unsupported=1`、`error_code=1`、`s_ready=0`、不产生有效输出；检测到输入 valid 后置位 error。RAW_BITS 非 8/10/12 时 error_code=2，同样不接收像素。

双线性窗口由上游提供；完整 RAW 流使用 `img_bayer_window_frontend_draft`，其 W×H 输出 (W−2)×(H−2)，不填充外圈。`s_window[n*RAW_BITS +: RAW_BITS]` 按 n=0..8 从左到右、从上到下排列；s_data 为权威中心值，窗口索引4不参与运算。中心原图坐标奇偶、窗口、SOF/EOL 与 s_data 同属一次传输。

`cfg_pattern`：0=RGGB，1=GRBG，2=GBRG，3=BGGR。排列描述原图偶行偶列起始位置；裁剪后须同时调整坐标相位或排列。算法仅为双线性插值，未包含方向自适应插值。

### Gamma 装载

复位进入旁路，不会读取未初始化 LUT。所有写入仅作用于非活动 bank。`cfg_channel=0/1/2` 分别写 R/G/B，`3` 同时写三通道；每个通道必须按地址 0→255 连续装载，可以在通道之间交错。乱序或重复地址置 `cfg_error`，该笔写入被忽略，不推进地址计数。广播写入要求三个通道的下一地址均匹配。

`cfg_lut_complete[2:0]` 分别是 R/G/B 完整标志。三个通道完整后，在独立周期令 `cfg_commit=1,cfg_enable=1`；后续接受 SOF 时切换 bank。完整性不足或写入同周期提交会置 `cfg_error` 且不提交。`cfg_enable=0` 的独立提交可在帧界切回旁路，不切换 bank。每次实际提交后重置装载计数；下次启用必须重新完整装表。Gamma 数值曲线由软件计算并装载，RTL 不实现幂函数。

### AWB 统计与自动反馈

`img_isp_awb_stats` 从接受 SOF 开始累积，接受下一 SOF 时将上一帧统计送至 `stats_*`。`stats_valid` 在 `stats_ready` 握手前保持；统计输出被阻塞时，下一帧首像素会背压，防止覆盖结果。

最后一帧没有下一 SOF 时，外部在停止提供像素（`s_valid=0`）后保持 `stats_flush`，直到 `stats_flush_ready` 接受。flush 仅关闭统计帧，不丢弃尚在输出寄存器中的像素；再次接受像素前应发送新的 SOF。首个 SOF 之前的像素仍原样通过，但不计入统计并置 `protocol_error`。累加器及计数器溢出时饱和，并随帧发布 `stats_overflow`；帧序号自然回卷。

`img_isp_awb_autogain` 用硬件共享迭代除法器计算 `target=floor((sum_r+sum_g+sum_b)/3)`，`gain_c=clip(floor((target<<8)/sum_c),min,max)`，输出 Q8.8。上下界在统计握手时采样。只有原始三通道总和为零才按黑帧返回中性256；非黑帧总和为1或2时 target 虽为零，非零通道仍按公式夹紧，零通道返回上界并报诊断。空统计、溢出或边界颠倒返回错误。结果保持至 gain_ready。当前 v95 实现采用字节迭代求和/除法和四位组借位前缀，延迟随数值和参数变化；17项 SUM_WIDTH=48 向量从统计接受沿到首次 gain_valid 的延迟为1–772个 CE 使能沿。统计与错误结果按握手对齐，不能按固定像素延迟消费求解结果。历史 v65 的83沿案例仅适用于其旧 SUM_WIDTH=16 实现。

`img_isp_awb_auto` 已连接统计→求解→帧界增益，无需主机计算。最新结果邮箱允许覆盖尚未排队的中间结果，使求解器不会因下个 SOF 尚未出现而死锁；已提交等待 SOF 的结果保持。求解具有多周期延迟，连续视频更新可能跨多帧，不能保证紧随统计发布的那帧使用新增益。applied_gain 和 applied_statistics_frame 只在增益实际应用时更新。

error_code 位0=空统计，1=溢出，2=增益边界非法，3=非黑帧零通道，4=统计协议错误，7=内部异常。位0/1/2/7的结果不替换有效增益；位3饱和结果允许应用。80 个单像素帧及长期无 SOF 的挂起更新已纳入组级回归。

### 数值约定

- AWB：`out = clip((pixel * gain + 128) >> 8)`。
- 亮度/对比度：`out = clip((((pixel - 128) * contrast + 128) >>> 8) + 128 + brightness)`。
- CCM：`out[row] = clip(((sum(coeff[row,col] * pixel[col]) + 512) >>> 10) + bias[row])`。系数地址 0–8 为行优先矩阵，9–11 为 R/G/B 偏置；非法地址只置错误，合法配置保持。复位单位矩阵。
- 上述有符号右移加半量化单位的舍入规则在恰好负半值时趋向正方向，不是“远离零”舍入。
- 色彩转换使用 8 位分数的固定整数近似。RGB→Y：77/150/29；Cb：−43/−85/128 并加 128；Cr：128/−107/−21 并加 128。逆变换系数为 359、−88、−183、454；输出均饱和。往返不保证逐位恢复。

## 后续集成边界

源文件依赖见 manifest.json，组级构建入口为 `../pipelines/run_group_regression.py`。未加入通用板级工程。Bayer 双行缓存和 Gamma 使用同步存储；v60 CCM/Gamma 组合候选已测综合、PNR和板 UART，但其他 ISP 模块与整条流水的 DSP/LUT 数量及时序仍未测量，不能据此宣称整组符合 Tang 20K 的15K LUT/4 DSP预算。

运行 `python cores/system/common_scaffold/image/pipelines/run_group_regression.py`，每次生成新的 pipelines/build_group_时间目录，保留 bench、编译/仿真日志、vvp 和 JSON。2026-10-15 获得 ISP_GROUP_PASS；覆盖 RAW8/10/12×四相、小图 marker/尺寸错误、AWB 求解及闭环、CCM→亮度→Gamma→CSC、CE/背压和多阶段配置。旧失败证据保持；2026-10-17 CCM/Gamma 回归单独记录，并在核对日志后删除了本轮新生成的 vvp。


2026-10-17 亮度/对比度实现更新：来源为板级 v54 冻结候选的相同 RTL，原一拍版本保留在
`board/tang25k/build/image_isp_common_selftest_25k_20261017_v46/rtl/`。三段弹性流水保持整数公式、
舍入、饱和、共享 CE、背压和 SOF 配置语义；接口延迟由一拍改为三拍，调用方应按握手对齐。
独立边界测试为 14,336 组合 / 43,008 通道结果；v54 三次独立 SRAM 加载均核对完整210字节
UART（188项像素/marker检查）。组合资源4,402 LUT/995 DFF/0 DSP，修正时序模型路由55.02 MHz，
实际工作50 MHz并保留CE4；不代表整条自动ISP或所有配置全速验收。v53同核心但不同物理实现两次
停在BC前，失败日志保留，根因未定；不得把新增watchdog当作图像算法修复。

2026-10-17 CCM/Gamma 更新：`img_isp_ccm.v` 与 `img_isp_gamma_lut.v` 逐字节来自冻结的 v60 候选，
回写前 RTL 备份与源哈希见 `evidence/production_ccm_v60_20261017/`。CCM 延迟由一拍改为四个 CE
使能沿，仍为 II=1；SOF 配置在输入握手时快照，标记和像素一同经过弹性级，Q6.10 舍入/偏置/
饱和合同不变。Gamma 本身仍为一个 CE 使能沿；v60 并行自测顶层中的三级 Gamma 对齐只用于和
四级 CCM 比较，未加入生产 Gamma 模块。生产色彩流水按 AWB→CCM→亮度/对比度→Gamma 串联，
不需要该对齐级。新旧延迟的独立回归记录在同一 evidence 目录；冻结候选通过 50 MHz PNR，
三次独立 SRAM 装载的 53 字节 UART 检查均通过，但这不等同于任意 ISP 全链路验收。

2026-10-17 历史 v65 AWB 更新（小宽验证；后续stats/autogain由下述v95取代）：`img_isp_awb_gain.v`、`img_isp_awb_autogain.v`、`img_isp_awb_stats.v`
逐字节来自冻结并上板通过的 v65 候选；回写前备份、源哈希及生产回归证据见
`evidence/production_awb_v65_20261017/`。`img_isp_awb_auto.v` 保持原字节。增益模块由一段
改为三段弹性流水，无阻塞输入至输出传输延迟由 1 改为 3 个 CE 沿，II=1；输入 SOF
接受时锁定像素和所用活动/影子增益，旧在途像素使用各自已捕获的增益。求解器在统计
捕获后增加求和及 target 寄存阶段，共多 2 个 CE 沿；统计模块只调整计数器进位/饱和
判定结构，RGB 旁路仍一段，统计发布的握手/延迟不变。

生产三份 RTL 通过独立流水检查（10885 输入、10883 输出、2 笔复位取消）、原168字节
UART 对比、autogain target 检查和563个计数边界案例；整组回归证据为
`../pipelines/build_group_20261017_021508_192727/`。v65 组合资源5086 LUT/2332 DFF/3 SPX9/0 DSP，
修正模型路由50.34 MHz、hold/资源门槛通过，物理50 MHz/CE4下三次独立SRAM装载均核对
完整168字节UART。板级范围为统计SUM_WIDTH=8及求解/自动反馈SUM_WIDTH=16的有限向量，
不能据此认定默认48位整条AWB或完整视频流时序已验收。该组回归本轮新生成的vvp在
核对PASS日志后清理，旧日志与候选产物保留。

2026-10-17 当前默认48位AWB更新：仅 `img_isp_awb_stats.v` 与
`img_isp_awb_autogain.v` 精确复制冻结v95；旧生产源以非 `.v` 后缀保存于
`evidence/production_awb_v95_20261017/`。gain与auto包装器未在本次修改。
8套生产源回归覆盖1/8/9/13/16/17/49位参数、默认48位stats与17项solver向量、
除法随机/边界及normal/fault UART；ISP组结果见
`../pipelines/build_group_20261017_041726_014899/`，本轮949915字节VVP已清理。
上述800 CE限制来自回归testbench，RTL没有新增硬件watchdog。

v95四普通RGB像素真实统计→flush→48位solver→UART组合为2164LUT/1144FF/0BRAM/0DSP，
修正模型56.91/56.72MHz；三次独立SRAM完整47字节均通过。v91硬件17项ROM只实例化
solver，覆盖高48位sum、total0/1/2/3、零通道/空统计/overflow元数据及边界倒置，
1326LUT/621FF/0BRAM/0DSP，64.97/57.27MHz；三次独立SRAM完整25字节通过。
两者实际50MHz、CE恒1，记录各见候选 `board_validation_summary.json`。高位stats预置饱和
仍仅为仿真证据，不能扩大为超长图像统计、连续视频或整条ISP板端验收。早期freeze内的
NOT_RUN保留历史状态，后续独立逐次板测记录才是PASS依据。
