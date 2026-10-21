# 图像滤波、边缘与形态学

本目录的主要滤波入口已有实际计算与控制逻辑。先前七个算法占位入口均已替换：开/闭运算、Canny、双边、导向、NLM、时域降噪。2026-10-17 已将均值、高斯、中值、Sobel、Prewitt、二值化、腐蚀、膨胀的流水版本通过 Tang Primer 25K 限定窗口板测并回写源码。v70 对 `OP=0 && PIXEL_W=8` 的均值输出改用同步 4096×8 ROM；其他位宽保留原除法。完整Canny的四级梯度寄存版本v100也已通过三次限定帧SRAM/UART板测并回写，生产image_core组通过。其余入口仍按各自证据限定，未连接混合密码顶层，未承诺20K容量或实时整帧视频吞吐。

v70 ROM 的值由 `(sum + 4) / 9` 精确实现，表项对 12-bit 地址 `a` 等于 `floor(a / 9)`。ROM 输出寄存器构成原三段流水的最后一级，因此无停顿延迟仍为三个使能沿、II=1；`clk_en`、ready/valid、SOF/EOL 和背压语义不变。ROM 内容和数据输出不复位，复位会清除 valid/marker，所以无效周期的数据未定义。独立算术回归遍历两种 CE/背压模式的全部 4096 地址，共核对 8192 个有效输出。

## 接口

原生流采用同一 `clk_en`，传输为 `clk_en && valid && ready`。输出与响应在背压或 CE 暂停时保持。单通道默认 8 bit，RGB 需逐通道处理或明确转为亮度。外部 3×3 窗口按 row-major 打包，tap0 位于低位，tap4 为中心；标记描述中心输出像素。窗口模块不隐含行存储。

上述八个窗口算子现在均为三段弹性流水，空闲时延由原一段增加为三个使能推进沿，最大每使能沿接受一个窗口。Sobel/Prewitt 的有符号 Gx/Gy、幅值、显示像素和 SOF/EOL 一起推进。接入方须相应对齐独立旁路；其他使用 `img_filter_stream_register` 的模块保持其默认 `PIPE_STAGES=1`。中值采用本地九层 odd-even 网络按三层一组分级；均值/高斯、形态学和梯度均将实际算术分散到级间。

整帧命令入口默认 `MAX_WIDTH=64, MAX_HEIGHT=64`，可参数化；配置/尺寸在命令接受时锁存，之后恰好接收 `width*height` 个像素。内部同步 RAM 不依赖复位清零，整帧多遍处理后内部回放。响应只在最后输出被接收后产生。无超时的入口要求调用方完成输入并最终接受输出；复位可取消未完成操作。

## 可选入口

| 入口 | 支持功能与边界 |
|---|---|
| `img_filter_mean3x3`, `img_filter_gaussian3x3`, `img_filter_median3x3` | 外部窗口均值、固定二项式高斯、九值中值 |
| `img_morph_erode3x3`, `img_morph_dilate3x3` | 非空编译期结构元素；膨胀反射结构元素偏移，支持不对称 SE |
| `img_morph_open3x3`, `img_morph_close3x3` | 整帧两遍腐蚀/膨胀及完整中间帧；运行期非空 9-bit SE；每遍复制边界 |
| `img_edge_sobel3x3`, `img_edge_prewitt3x3`, `img_edge_laplacian3x3` | 外部窗口；保留梯度/响应及饱和显示输出；Sobel/Prewitt 为 L1 幅度 |
| `img_filter_threshold` | 给定阈值二值化，可反相 |
| `img_edge_canny` | 完整 Gaussian→Sobel L1→四方向 NMS→双阈值→8 连通弱边传播至固定点；同尺寸复制边界；非单跳近似 |
| `img_filter_bilateral3x3` | 外部窗口，真实空间/灰度距离指数权重与归一化；sigma 为 Q8.8；9 次顺序累加 |
| `img_filter_guided` | 独立灰度 source/guide 原子配对、协方差和正则化、两遍 box 系数平滑；当前支持 8 bit、半径 0..3 默认；依赖 dehaze 目录两个 guided 模块 |
| `img_filter_nlm` | 整帧 patch SSD 与指数权重、搜索邻域归一化；默认最大 patch 半径1/search半径3；h 为像素幅值 Q8；复制边界 |
| `img_filter_temporal_denoise` | 默认内部同步历史帧，完整输出后发布；复位/尺寸变化/坏帧失效；运动阈值与 0..256 当前权重；可选外部历史原子配对 |
| `img_filter_temporal_blend` | 已对齐像素对的低层混合算术，无历史存储 |

双边命令的响应表示 sigma 配置已接受，之后可连续处理窗口，直到下一次配置；其接口没有帧尺寸，因此不返回整帧完成。NLM/双边指数采用 256 项 `round(65535*exp(-index/16))` 常量 LUT。导向滤波 Q8 epsilon 向上取整为原始 8-bit guide 的平方单位，最小1；source 的 Q1.15 适配及输出舍入饱和在 wrapper 内完成。

整帧主要错误为 bit0=配置/参数不支持，bit1=输入 SOF/EOL 不符，bit7=内部状态错误；Canny bit2=异常未收敛，temporal bit2=外部历史标记不配对。guided 低4位透传 guided_engine 错误，bit5=source/guide 标记不符。错误帧若已产生输出，调用方须按响应丢弃。精确端口与限制见 RTL 和 manifest。

## 分组开发检查

```powershell
. .\scripts\env.ps1
python cores/system/common_scaffold/image/sim/run_image_core_group.py
```

已通过独立整数参考组：开/闭运算（不对称 SE）、NLM、完整 Canny、双流导向、两帧运动自适应时域、双边窗口，共 183 个整帧像素及 4 个窗口，检查 CE/背压、像素值、SOF/EOL、最终响应/tag。参考 Canny 使用 flood-fill，与 RTL 重复扫描实现不同。命令/日志/生成测试保存在追加的 `image/build_core_group_<时间>/`；失败日志保留。

当前 v70 板测证据在 `../../board/tang25k/build/image_window_filter8_selftest_25k_20261017_v70_meanrom/board_validation_summary.json`：三次独立 SRAM 加载均通过，检查 5 帧、206 像素、102 个有效窗口及八个滤波算子，UART 每次返回 52 字节且摘要为 `73D33C84`。实际时钟 50 MHz，CE 每 16 个周期启用 13 个周期；修正时序模型的路由报告为 59.72 MHz，50 MHz setup/hold 检查通过。候选完整自检顶层合计 4,469 LUT、1,678 FF、11 BSRAM、0 DSP（含 ROM、checker、UART），比 v69 多 2 个 BSRAM；这些是顶层总数而非单核资源。测试不覆盖整帧持续视频吞吐或更大图像的窗口/帧存储能力。

生产源回归和独立 Python 参考均通过：ROM/算术流水检查 8,192 个 ROM 输出及六组 W1/8/12 算术配置；独立参考覆盖 167 个窗口；图像整帧组覆盖开闭运算、NLM、Canny、导向、时域和双边，共 7 个 case、183 个像素、4 个窗口。标准整帧组 runner 会忽略 `evidence/` 中保留的旧源码快照，避免重复模块定义。此次 `.vvp` 镜像已在仿真后删除；摘要、命令和空间记录见 `sim/production_meanrom_v70_20261017/integration_manifest.json`。先前候选和改前源码仍保存在各自证据目录。

其余小核已参加全目录编译，尚无逐核完整验收结论。当前结果未承诺所有参数组合、频率、资源或图像质量。直接乘除与大帧存储应在目标系统选择配置后优化。

## 当前完整Canny的板测与生产集成

`img_edge_canny.v` 精确来自冻结v100，旧完整整数核及文档/manifest字节备份见
`sim/production_canny_v100_20261017/`。尺寸/索引与算术按数学上界限定，Sobel实际
分为正负加权和、带符号差、绝对值、Q8方向乘积/幅值四个寄存状态，随后比较方向
并写同步梯度RAM。相较旧实现每个像素额外4个CE使能沿；输入/输出/response合同和
数值不变，调用方应等待有效握手而非假定旧完成周期。

独立旧核交易对照覆盖P1/8/12、MAX1x1/8x8/3x5及80个尺寸命令，两核各自CE/背压。
冻结Python flood-fill黄金的10个板命令共272真实输入/输出像素，覆盖九跳弱边链、
17次promote、3轮changed扫描，无strong种子、bad SOF/EOL、非法阈值/零宽及恢复。
normal/checker-fault/GDIFF中途复位、原2M物理拍watchdog及完整46字节UART/12位静默
均过；保持7C514D90。修正库路由76.51/63.38MHz，50MHz setup/hold与资源门禁全过，
1611LUT/549FF/6BRAM/0DSP。三次独立SRAM每次IDCODE0x1281b且完整UART严格匹配：

```text
CNY97 PASS N=0A P=0110 E=0000 D=7C514D90 C=F
```

报告中的CNY97为保留的既有候选标识；实现和三次记录在v100目录。实际50MHz，
CE13/16，无多周期时序例外。板范围仅GRAY8/MAX8x8，不能扩大为默认64x64、实时视频
或全部滤波核同一top面积验收。生产image_core组7case/183像素/4窗口通过，证据
`../build_core_group_20261017_043631_002878/`；本轮2230283B VVP已清，旧产物保留。
外部OpenCV/Vitis/FPGA案例审查的URL/commit/hash及采用差异见共享外部参考索引和
v100 `VITIS_REFERENCE_REVIEW.json`，未导入第三方代码或改变本地黄金。
