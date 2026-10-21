# Frame-buffered Histogram / HE / CLAHE

本组提供可直接接入灰度/Y 像素流的整帧 HE、CLAHE 实现：**输入帧只发送一次**，内部完成采集、统计、LUT 构建及原帧回放。2026-10-17 当前生产十份 RTL 的组级独立参考回归通过（18 命令、3840 输出像素、7 预期错误响应）。当前三谓词优化 engine 与单文件五级弹性插值器的精确组合，已由 v90 HE 16×16 和 v94 CLAHE 64×32 两份限定配置分别完成 50 MHz 时序/资源检查及三次独立 SRAM/UART 验证。其他尺寸、参数或持续视频吞吐仍需分别验收。

## 完整入口

| 模块 | 功能 |
| --- | --- |
| `img_hist_he_frame` | 整帧 HE，使用全局直方图和 CDF_min 归一化；常值帧保留原值 |
| `img_hist_clahe_frame` | 整帧多 tile CLAHE，严格限幅及循环重分配、逐 tile LUT、tile 中心双线性插值 |
| `img_hist_frame_engine` | 上述两入口的共享实现，以 `ADAPTIVE` 选择算法 |

输入为 8-bit 灰度或单独的 Y 通道。RGB 的颜色空间转换及色度保留由外层完成。本组不会把灰度输出当作 RGB 输出。

## 事务及存储接口

- `start_valid/start_ready` 接受一条帧命令，锁存 `start_tag` 以及 CLAHE 的绝对计数阈值 `start_clip_limit`。尺寸是 elaboration 参数，不能在一帧中更改。HE 入口没有 clip 输入。
- 成功命令进入采集后可每个 enabled clock 接收一个像素，第一像素必须带 SOF，每行末像素必须带 EOL。输入恰好 `FRAME_WIDTH*FRAME_HEIGHT` 个像素；采集以外 `s_ready=0`。
- 内部同步 frame RAM 保留原帧；histogram RAM 和逐 tile LUT RAM 的读写也都是时钟同步的，没有整帧异步读寄存器数组。所有 RAM 不复位，只复位控制并在使用前覆盖有效内容。
- 先采完整帧，再串行计算所有 tile，最后回放一次输出；没有跨帧采集/处理重叠。输出包含 gray、SOF、EOL、last、原 command tag 和 error。
- `clk_en && valid && ready` 上升沿才传输。CE=0 时所有状态和有效载荷保持，输入/start ready 拉低；输出及 done 支持任意背压。输出端也必须遵守同一 CE。
- 最后一个输出像素被接受后才产生成功 `done`；done 带 `count/tag/error/code`，保持到被接受后才能接受下一条 start。配置错误或输入标记错误不会输出成功帧。
- 异步复位取消任何进行中的帧及响应，不清空 RAM。缺失输入像素或无限输出背压没有隐含超时，复位可取消。

## 明确的算法定义

HE 使用 `floor(255*(CDF-CDF_min)/(N-CDF_min))`，低于首个非空 bin 的 LUT 值为零。常值帧输出原灰度，不会因分母为零报错。

CLAHE 的 `start_clip_limit` 是每个 bin 的**绝对最大计数**，不是软件库的浮点归一化 clip 参数。每个 tile 先限幅，再按 bin 0..255 的顺序向仍低于阈值的 bin 各分配一个 excess count；反复扫描直到全部分配。最终总数严格守恒且所有 bin 不超过阈值。`256*clip_limit < tile_pixels` 时数学上无法同时满足两条件，命令立即显式失败。

每个 tile 的映射为 `floor(255*CDF/tile_pixels)`，不减 CDF_min。tile 中心坐标为 `(tile_size-1)/2 + tile_index*tile_size`；中心之外延用最近 tile。中间位置选择相邻四个 tile 对同一原灰度查 LUT，fraction 截断为 Q0.F，双线性加权后四舍五入到最近整数。这是一种明确的严格 CLAHE 变体，**不承诺与 OpenCV 的重分配或边界扩展逐位一致**。

### 限定配置的 Tang Primer 25K 验收

2026-10-17 的冻结候选 `image_clahe4_selftest_25k_20261017_v81_interp5` 已在 Tang Primer 25K（GW5A-LV25MG121NES）完成 50 MHz 综合/布线及三次独立 SRAM 加载验证。验收范围严格限定为 GRAY8、64×32 帧、32×16 tile（2×2 tiles）、`COUNT_WIDTH=16`、Q6 fraction，以及每 16 个物理时钟启用 13 个时钟的 CE 模式。每次板测均核对完整 52 字节 UART：`CLA4 PASS F=07 I=3000 O=2000 E=0000 D=ADB48900 C=F`。布线 setup、hold 通过，报告的两组 Fmax 为 63.91/57.84 MHz；资源为 3179 LUT4、1102 FF、17 BSRAM、0 multiplier。插值从输入接受到 `m_valid` 首次有效为 5 个 enabled edges；无停顿时 II 为 1 个 enabled edge。证据和范围记录见 `evidence/production_interp_v81_20261017/`。

这份板测针对历史冻结 v81 候选。当前生产精确组合的 v94 CLAHE 验收见文末。此处也不宣称 OpenCV bit-exact、任意尺寸已签核或持续实时视频吞吐。

## 支持范围和资源边界

- 完整帧入口：`FRAME_WIDTH/HEIGHT` 各为 1..512；`COUNT_WIDTH` 为 1..32，并须满足总帧像素数 `<=2^COUNT_WIDTH-1`。默认 COUNT_WIDTH=16 不足以覆盖 512×512，应显式增大。
- CLAHE：tile 宽高至少为 2 且均为偶数，必须整除对应帧尺寸；不支持不完整边缘 tile。tile 总数为 1..256；`FRACTION_BITS` 为 1..12。不支持的配置通过参数错误响应退出。
- 实现优先完整功能和同步 RAM，逐像素输出、逐 bin 串行除法及逐轮重分配均有多拍开销，不宣称实时视频吞吐。
- 存储约为 `frame_pixels` 字节 + `256*tile_count` 字节 LUT + `256*COUNT_WIDTH` 位 histogram；另有插值乘法及控制。实际 LUT/DSP/BRAM、频率与器件容量须后续综合测量，不表示适合全部尺寸同时部署到 GW2A-18C。

完整帧错误码：0x01 参数/clip 容量；0x02 SOF/EOL；0x04 histogram 溢出；0x08 重分配无进展；0x10 CDF 总数；0x20 除法；0x40 插值。参数失败 count=0，其余错误带实际已采集像素数。所有错误带原 command tag。

## 低层模块与 legacy 接口

- `img_hist_accumulator`：同步直方图统计及冻结读回，输入间隔至少两个 enabled clocks；256 拍清零。已修复 `bins` 与 SystemVerilog 保留字冲突。它本身不保存帧。
- `img_hist_he_lut_builder`、`img_hist_lut_map`：保留低层统计/LUT 分离接口。单独组装它们时仍需外部帧回放；完整帧入口已经内含回放，无需使用这条旧的外部两遍链路。mapper commit 必须在随后接受的 SOF 才激活，未配置映射返回 identity 并报 error。
- `img_hist_ratio_u8`、`img_hist_clahe_interp`：由完整帧 engine 使用，串行精确比例除法和五级同步输出弹性插值。插值器仍使用原 `img_hist_clahe_interp` 模块名、参数及端口；实现与 helper 位于同一个 RTL 文件，兼容只编译该生产文件的入口。流水依次完成像素乘 x 权重、两行水平和、水平和乘 y 权重、垂直和、最终 HALF 舍入/移位/饱和，中间不舍入。输入接受后第五个 enabled edge 产生输出 valid；持续 ready 时 II=1。CE=0 时 valid 和载荷保持，实际传输由系统用同一 CE 限定。F=0 或 F>12、或 fx/fy 超范围时输出零并置 error。
- `img_hist_clahe_clip`：低层单 tile 256-bin 接口现同样实现严格循环重分配。输入 bin 必须依次 0..255，last 仅在 255。错误码 0x01 参数、0x02 输入顺序、0x04 总数超过严格 clip 容量、0x08 重分配无进展；失败不输出 histogram。其功能路径本轮未另做逐核验收，仅编译通过。
- `img_hist_clahe_controller_placeholder`：**legacy 错误响应兼容接口，禁止用于新 CLAHE 链路**。原接口没有任何像素端口，保留每条命令返回 0x80 的行为以免旧接线静默成功；完整替代为有真实像素流/帧存储的 `img_hist_clahe_frame`。

## 一次组级回归

从仓库根目录执行：

```powershell
. .\scripts\env.ps1
python cores\system\common_scaffold\image\histogram\sim\run_histogram_group.py
```

该命令先对本目录全部 10 个 RTL 做 `iverilog -g2012 -Wall -tnull`，再运行一套 Python 独立整数模型驱动的小帧端到端回归。覆盖 HE 常值/随机/梯度、CLAHE 3×2 多 tile、512px/tile 多轮严格重分配、两个 fraction 精度、不同 clip 参数、配置锁存、reset 取消、CE 暂停、输出与 done 背压、错误 SOF/EOL、不可行 clip 容量及错误后下一帧恢复。逐像素核对数值、SOF/EOL/last、tag、error，并逐帧核对输出数及 done 数。

2026-10-17 当前生产组合运行结果：**10 个 RTL 编译通过；18 条完整帧命令（11 成功、7 显式错误）；3840 个输出像素匹配独立模型**。证据见 `sim/results/20261017_035248_135024/summary.json`；该目录还记录测试前后十份源及 runner SHA 一致及本轮 341479 B 仿真镜像清理。实际 native 环境运行入口为 `python -B cores/system/common_scaffold/image/histogram/evidence/production_predicate_v90_20261017/run_production_group.py`。2026-10-15 旧组证据原样保留。已有中间失败日志均保留，包括最初编译保留字错误、HE 常量分支空 @* 敏感表造成 X 输出，以及 testbench Windows 长路径截断错误；相应问题均已修复后重跑。低层模块仍没有逐核完整验收；限定候选的综合、板测范围见上文，不能外推任意参数。

## 有界索引生产集成与组合验收

`img_hist_frame_engine` 的十四项持久索引已改用 `max(1,clog2(entries))`，未改状态、数值算法和原有调度。有界版本的历史生产快照与 v83 冻结 engine 逐字节一致；十三组逐物理拍 miter 覆盖 HE 1×1/COUNT1、非二幂、511/512 维边界和 CLAHE 256 tiles，同时比较公共输出和内部索引。静态宽度审查遍历 262144 个 HE 尺寸对、1376861 个合法 CLAHE frame/tile 组合；这不等于对这些尺寸做了完整帧仿真。历史证据见 `evidence/production_bounded_v83_20261017/`。

v83 的历史限定 HE 16×16/COUNT16 候选已三次独立 SRAM/UART 通过，仍使用旧单级插值器。v87 则验收了当时的有界 engine（SHA `2bbf4562…`）与五级插值器组合，当前 engine 已升级，因此保留 v87 为历史组合证据。独立 HE v88 的两次修正库布线最低 49.34/47.31 MHz，均未达到 50 MHz，未 pack、未板测。

当前 engine SHA 为 `913bb918ba4d48f7f70413b4e5134048929e5bb891ed4f92d79d5b070317864f`。v90 仅将 CDF_CALC 三个减法结果判零/相等分支改为模 `2^COUNT_WIDTH` 等价比较，divider 数据、状态和周期均保持；642468 项数学检查和十三组逐拍 miter 通过。回写来源、旧源及文档快照见 `evidence/production_predicate_v90_20261017/`。

| 当前生产限定候选 | 仿真和板上检查 | 修正库 Fmax / 资源 |
| --- | --- | --- |
| v90 HE，16×16、COUNT16 | 9 命令、2304 输入、1792 输出、2 预期帧错误；三次 SRAM 均严格匹配 52 字节 `HE16 PASS F=09 I=0900 O=0700 E=0000 D=2ABE0CBC C=F` | 56.56/57.04 MHz；1556 LUT、703 FF、7 BRAM、0 DSP |
| v94 CLAHE，64×32、2×2 个 32×16 tile、COUNT16/Q6 | 7 命令、12288 输入、8192 输出、3 预期错误；十份 RTL 与当前生产逐字节一致；三次 SRAM 均严格匹配 52 字节 `CLA4 PASS F=07 I=3000 O=2000 E=0000 D=ADB48900 C=F` | 66.19/54.22 MHz；2638 LUT、866 FF、17 BRAM、0 DSP |

两者均使用实际 50 MHz 时钟，CE 每 16 拍启用 13 拍，setup、hold 和资源门限全部通过；每次加载核对 JTAG `0x1281b`，仅写 SRAM。证据分别为 `../../board/tang25k/build/image_he16_selftest_25k_20261017_v90_predicate/board_validation_summary.json` 和 `../../board/tang25k/build/image_clahe4_selftest_25k_20261017_v94_predicate/board_validation_summary.json`。v94 位流 SHA 为 `44f4757813651e91a3339c6df6613b0b311d8ea27773bb8e52ffe02bcc2a94a8`；它与 v87 位流相同，但新冻结源、综合和三次板测均独立完成。
