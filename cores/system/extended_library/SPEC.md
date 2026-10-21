# wave2_ip_20k — 第二波 IP 工程规格书（单元契约）

目标：在 GW2A-18C（Tang Primer 20K, 27 MHz）上按 `docs/IP_CORE_SOP.md`
开发约 40 个可复用 IP 核。第一波基础（可直接引用、不得修改）：
`cores/image_processing/window`（win3x3_gen/line_buf_ram/uart_tx 等）、
`cores/communication/primitives`、`cores/signal_processing/dsp`、`cores/acceleration/cnn_systolic`。

## 目录与工具链

```
cores/system/extended_library/
  src/      RTL：共享基础设施 + 每单元 <unit>.v + st_<unit>.v
  sim/      tb_st_<unit>.v、gowin_bsram_sim.v、golden/dump 文件
  tools/    golden_<grp>.py 等
  doc/      单元记录
  ip/       IP 封装输出（集成阶段统一生成）
  build_oss/综合输出（gitignored 产物）
```

工具链（Git Bash，先 export）：

```bash
export PATH="/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/bin:/d/sipeedTANG20K/tools/oss-cad-suite/oss-cad-suite/lib:$PATH"
cd /d/sipeedTANG20K/cores/system/extended_library   # vvp/相对 mem 路径必须在工程根跑
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
    src/<u>.v src/st_<u>.v [deps...] sim/gowin_bsram_sim.v
vvp sim/tb_st_<u>.vvp
yosys -p "read_verilog -sv src/<u>.v [deps]; synth_gowin -top <u>; stat"
python tools/golden_<grp>.py     # Python = C:\Program Files\Python312\python
```

## 单元契约（所有 st_<unit> 必须严格遵守）

每个单元交付一个**自测单元 cell**，接口逐字如下：

```verilog
module st_<unit> (
    input  wire        clk,
    input  wire        clk_en,   // 逻辑节拍（板上 = clk/16）；cell 内所有
                                 // 寄存器必须 clk_en 门控（含复位预热期可用
                                 // clk_en || !rst_n）
    input  wire        rst_n,    // 低有效异步复位
    input  wire        start,    // 1 个 clk_en 节拍的启动脉冲
    output reg         done,     // 完成后置位并保持
    output reg         pass,     // done 时有效：digest === EXP 且内部检查全过
    output reg  [31:0] digest,   // FNV-1a(输出流)，init 32'h811C9DC5
    output reg  [15:0] cycles    // 从 start 到 done 的逻辑节拍数
);
```

- cell 内部自带激励（推荐 `w2_img_stim`）、DUT 实例、FNV 折叠、
  `localparam [31:0] EXP = 32'h........;`（**值只能来自独立 Python golden
  的输出**，禁止从仿真回填，陷阱 T1）。
- 判定用 `===`/`!==`（T6）。`pass` 在 `done` 拉高同一拍或之后稳定即可。
- `cycles` 自 start 起按 clk_en 计数，done 时冻结。
- 同一个 st_ cell 可以例化多个 DUT 场景（如正/逆、多帧），把各段输出都
  折进 digest；cell 可顺序复用 DUT。

## 共享基础设施（src/ 下，只读复用）

| 模块 | 说明 |
|---|---|
| `w2_dpram.v` | DPX9B 同步双口 RAM（W≤18, DEPTH≤1024），写口 A / 读口 B，读数据寄存一拍。**任何需要 RAM 的单元必须用它**（T9：推断 BSRAM 硅上数据错乱）。 |
| `w2_win_rd.v` | 通用 K×K 窗读取器：帧存进 w2_dpram 后随机访问，逐 tap 地址 clamp（边界复制），每输出像素 K² 拍。IMG_W 须为 2 的幂。 |
| `w2_img_stim.v` | 公式化多帧图像激励（公式见文件头，golden 必须逐字复现）。8-bit `pix` + 24-bit `pix24`，`fidx` 帧号，`new_line`/`pix_valid` 流契约同 imgwin。 |
| `w2_fnv.vh` | `` `include "w2_fnv.vh"``，FNV-1a 函数（移位加实现）。 |
| `gowin_bsram_sim.v`(sim/) | DPX9B 行为模型（含实测寄存 DOB 语义），用 w2_dpram 的 TB 必须链接它。 |
| imgwin 复用 | `../../imgwin_20k/src/win3x3_gen.v`、`line_buf_ram.v`、`uart_tx.v`、`median3x3.v`、`morph3x3.v`、`sobel_edge.v`、`threshold_bin.v`、`gaussian3x3.v` 可直接列入编译文件表（相对路径），**不得复制改副本**。 |

图像流契约（与 imgwin 一致）：每行先 1 拍 `new_line`（该拍无 pix_valid），
再 IMG_W 拍 `pix_valid`+`pix`；IMG_H 行一帧。边界策略统一为 edge
replication（clamp）。

## RTL 硬性规则（SOP 摘录，违者返工）

1. `clk` + `clk_en` + `rst_n`；**所有**寄存器 clk_en 门控（T2）。
2. 常量乘法一律移位加；真乘法只在被测 DSP 路径（T4）。DSP 预算全局 ≤4。
3. packed 多维数组压平 1D 取段（T3）。
4. `$readmemh` 默认文件参数必须存在（工程内 mem）。
5. 源文件 UTF-8、Verilog-2005/`iverilog -g2012` 兼容。
6. 判定 `===`/`!==`，TB 末尾要求 `!any_fail`。
7. 行缓存/帧存/直方图 RAM 全部走 `w2_dpram`（T9）。
8. 每单元资源目标：LUT4 ≤ 1500、0 DSP（CSC 等确需乘法时说明理由且 ≤1）。

## 交付物（每单元）

| 文件 | 内容 |
|---|---|
| `src/<unit>.v` | 核心 RTL（可综合） |
| `src/st_<unit>.v` | 自测 cell（契约见上） |
| `sim/tb_st_<unit>.v` | 独立 TB：拉复位→start→等 done→打印 `W2TB <TAG> PASS D=%08X C=%d` 或 `FAIL`，最后 `$finish`；含 X 检查 |
| `tools/golden_<grp>.py` | 独立 Python 模型：生成 `sim/golden_<unit>.txt`（每行一个 hex 字节的期望输出流）并打印各单元 `TAG DIGEST=XXXXXXXX` |
| `doc/units_<grp>.md` | 单元表：接口摘要、EXP digest、iverilog 结果、synth stat(LUT4/DFF/BSRAM/DSP)、已知限制 |

辅助子模块文件命名 `<unit>_*.v`（回归脚本自动收进编译），或写
`sim/files_<unit>.lst` 列出额外依赖的相对路径（每行一个）。

验证顺序（每步过了再下一步）：iverilog 语法 → golden python 产出 →
TB PASS（digest 与 golden 一致 + dump 逐字节比对 golden_*.txt）→
`synth_gowin; stat` 记录资源。TB dump 写 `sim/dump_<unit>.txt` 用
`$fopen/$fwrite("%02x")`，与 golden 文件 `diff` 比对。

## 单元清单（40 项；idx 为 UNIT_EN 位号与报告序号）

| idx | TAG | module | 组 | 功能要点 |
|---|---|---|---|---|
| 0 | DPC | isp_dpc | A | 缺陷像素校正：3×3 邻域，|c−med8|>THR 则替换 med8 |
| 1 | DEM | isp_demosaic | A | Bayer RGGB→RGB888 双线性插值 |
| 2 | AWB | isp_awb | A | 灰度世界白平衡：帧统计 R/G/B 均值→增益→应用 |
| 3 | GAM | isp_gamma | A | 256 项 γ LUT（LUT 可写口 + 应用流） |
| 4 | CSC | isp_csc | A | RGB↔YCbCr 定点转换（移位加系数） |
| 5 | GRY | isp_rgb2gray | A | BT.601 亮度 Y=(77R+150G+29B)>>8 |
| 6 | CGR | canny_grad | B | Sobel Gx,Gy→mag(|+|饱和)+dir(2-bit 象限) |
| 7 | NMS | canny_nms | B | 沿梯度方向 3×3 非极大抑制 |
| 8 | DTH | canny_dth | B | 双阈值分类 → 强(2)/弱(1)/无(0) |
| 9 | HYS | canny_hyst | B | 3×3 滞后：弱像素邻接强像素→边缘 |
| 10 | HAR | feat_harris | C | Harris 角分：Ix²,Iy²,Ixy 窗和→det−k·tr² |
| 11 | FST | feat_fast | C | FAST 角点（半径 3, 16 圆点，N 连续弧长） |
| 12 | LBP | feat_lbp | C | 3×3 LBP 8-bit 码 + uniform 标志 |
| 13 | HOG | feat_hog | C | 8×8 cell 梯度方向直方图（4-6 bin） |
| 14 | INT | img_integral | C | 积分图（SAT）32-bit 输出流 |
| 15 | SCL | img_scaler | D | 双线性缩放（缩放比参数） |
| 16 | HST | img_histogram | D | 256-bin 帧直方图（BSRAM 累加+读出） |
| 17 | CLA | hist_clahe | D | 小块 CLAHE：分块直方图+clip+CDF→LUT 应用 |
| 18 | SAD | match_sad | D | 8×8 模板 SAD 滑窗匹配→最优 (x,y)+minSAD |
| 19 | CRP | img_crop | D | ROI 裁剪流（x0,y0,w,h 参数/寄存器） |
| 20 | FDIF | frame_diff | E | |curr−prev| 帧差 + 阈值二值（帧存 w2_dpram） |
| 21 | BGS | bg_model | E | 滑动平均背景 bg+=(p−bg)>>α，fg 掩码 |
| 22 | BBOX | mot_bbox | E | fg 掩码→每帧 bbox(min/max xy)+像素计数 |
| 23 | CCL | ccl_bbox | E | 二值图连通域标记：label+面积+bbox 表 |
| 24 | PRJ | meas_proj | E | 行/列投影和（水平/垂直 profile） |
| 25 | CAN | can_ctrl | F | CAN 2.0 控制器：位时序+位填充+CRC15+ACK，回环自测 |
| 26 | MAC | eth_mac_mii | F | MII 半字节 MAC：前导/SFD/CRC32/IFG/地址过滤，回环自测 |
| 27 | PWM | pwm_gen | F | 4 通道 PWM（周期/占空比寄存器） |
| 28 | QEI | qei_dec | F | 正交编码器解码 ×4（计数+方向+index） |
| 29 | STP | step_drv | F | step/dir 步进脉冲 + 梯形加减速 |
| 30 | DMA | dma_sg | G | 简易 DMA：mem↔stream 描述符搬移+完成中断 |
| 31 | ILA | ila_core | G | 片内逻辑分析仪：触发(模板/沿)+BSRAM 捕获+读出 |
| 32 | CRC | crc32_eth | G | 流式 CRC32(IEEE)+CRC16-CCITT 参数化 |
| 33 | PRBS | prbs31 | G | PRBS-31 发生+校验（误码计数+失锁标志） |
| 34 | MBST | mem_bist | G | March 式 RAM BIST（挂在 w2_dpram 上，兼作硅验证探针） |
| 35 | BC3 | bnn_conv3x3 | H | 二值 3×3 卷积：XNOR+popcount+阈值→1-bit |
| 36 | BDN | bnn_dense | H | 二值全连接神经元组（32 输入 XNOR popcount+偏置比较） |
| 37 | TMR | tmr_voter | H | 三模冗余多数表决器+失配标志+错误计数 |
| 38 | WDT | wdt_win | H | 窗口看门狗（最小/最大周期+kick+故障计数） |
| 39 | LFSR | lfsr_prng | H | 32-bit Galois LFSR + 加扰/解扰对（回环 digest） |

## 集成（由协调方完成，agent 不管）

`w2_selftest.v` 聚合 40 个 st_ cell（UNIT_EN[39:0] 掩码拆分），
`top.v` UART 报告 `W2xx TAG P D=XXXXXXXX`；构建/烧录/IP 封装按 SOP
Phase 3–6 执行。**任何 agent 不得新建/修改共享文件**（w2_selftest、top、
脚本、本文件）；发现共享文件缺陷时在单元记录中说明并绕开。
