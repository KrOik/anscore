# 多帧图像 IP：存储、整帧处理与有界自动拼接

本目录含固定小帧处理与有界拼接路径。2026-10-17 已将通过 Tang Primer 25K 板测的 v101b 同步 BRAM 存储和三级弹性 RGB 混合流水线回写生产源码，公开端口、数值舍入、配置和错误合同不变。实际生产源码已复跑 6×5 图像组级参考仿真（含 8×7 拼接画布）、4×3 整帧 normal/fault/reset 和独立混合流水线压力测试。

物理板测范围是 v101b 的 4×3 RGB888 捕获、OSD、帧差、持久 Q8.8 EWMA 和融合应用；三次独立 SRAM 烧录均返回严格相同的 58 字节 UART。该配置为 6965 LUT、1712 FF、10 个物理 BRAM、0 DSP，实际 50 MHz、CE 1/4，setup/hold 全部门禁通过且无 multicycle timing exception。SAD/单应拼接仍只有组级仿真证据；大尺寸、连续视频和任意参数配置需要单独综合及板测。生产回写没有重烧板，使用冻结候选板测加实际生产回归建立对应关系，详见下方证据。

| 文件/模块 | 当前能力 | 外部依赖与缺口 |
|---|---|---|
| `img_mf_pair_join.v` | 原子接收双流，逐拍检查 SOF/EOL、frameid、tag，保存双像素 | 同一时钟域、同一 CE；不自动重同步和超时 |
| `img_mf_osd_overlay.v` | RGB888 全画幅 OSD，统一 alpha 和精确色键 | 外部字形、图标和完整画幅覆盖流；无稀疏区域读取 |
| `img_mf_frame_absdiff.v` | 灰度帧差、绝对值和前景阈值 | 外供上一帧像素与帧时序，不含帧 RAM |
| `img_mf_background_ewma.v` | Q8.8 背景运行均值、前景 mask、背景写回流 | 外供旧背景、初始化状态和同步 RAM；不是完整 GMM |
| `img_mf_weighted_fusion.v` | 两幅已对齐 RGB 图像的归一化加权融合 | 配准、曝光估计、多尺度/HDR 融合在外部 |
| `img_mf_rgb_blend_pipe.v` | OSD/融合共用的三级弹性 RGB888 精确整数混合实现 | 同一 CE，背压保持；新增流水线改变延迟，不改变顺序和数值 |
| `img_mf_stitch_registered.v` | 已配准画布上的存在标记、逐像素接缝权重和重叠混合 | 标定、特征匹配、单应矩阵、扭曲及接缝权重生成在外部 |
| `img_mf_history_manager.v` | 历史帧槽的分配、写入态、提交、查询和释放元数据 | 外部 RAM、样本计数、完成栅栏和时序身份管理 |
| `img_mf_dual_frame_store.v` | 两幅固定尺寸帧同步存取、捕获/回放、成对随机读、背景初始化、写回、超时 | 单时钟共享 CE；≤65536 像素；无外部 DDR/DMA |
| `img_mf_history_ram_adapter.v` | 直接封装真实双 bank 存储，继承原接口并扩展成对读写端口 | 旧调用方可不使用新增随机访问端口；固定尺寸由参数指定 |
| `img_mf_processing_bank.v` | 复用四类像素处理级，配置和输出按操作模式选择 | 由整帧 top 保证模式在事务中稳定 |
| `img_mf_frame_application.v` | 完整捕获→回放→OSD/帧差/EWMA/融合→完成响应；EWMA 写回复用 | RGB888；差分/背景取低 8 位为灰度；外部须按用途管理 bank1 内容格式 |
| `img_mf_translation_sad.v` | 中央 ROI 穷举整数平移 SAD，输出最佳/次佳代价和置信差 | 搜索半径 0..15，固定 ROI，无旋转/尺度/特征匹配 |
| `img_mf_auto_stitch.v` | 捕获→实际 SAD 配准→同步 RAM 取样→画布扭曲/混合→整帧完成 | 自动模式仅有界整数平移；可显式选择外供逆单应矩阵 |
| `tb_img_mf_frame_group.v` | 单个组级独立整数参考仿真，包含存储、处理及拼接路径 | 覆盖小帧关键路径，不是逐核/全参数回归 |

## 像素与配置接口

- `rst_n` 异步低有效，复位期间输入 ready 为 0。所有参与端共用 `clk_en`；传输仅发生于 `rst_n && clk_en && valid && ready`。输出 valid 可以在 CE=0 时保持为 1，接收端必须服从同一 CE，不能直接当作无 CE 的 AXI Stream 使用。
- `s_*` 为主流，`aux_*` 为辅助流；valid 不能等待 ready 才拉高。配对器仅在两路 valid 均有效并且内部空间可用时，同时接受两路，防止单边消费后丢失。每个输出寄存器在背压时保持数据、标记和错误。
- `s_sof` 是帧首像素，`s_eol` 是每行末像素。两路必须有相同画布/扫描顺序；不存在用空周期跳过透明像素的约定。`tag` 推荐表示不会在一帧内混淆的像素位置，默认只有 16 位，大画幅应显式增大 `TAG_WIDTH`。
- `frameid` 在像素核中是**目标输出帧身份**。历史帧和背景读出必须由适配器把原历史身份映射为当前目标 frameid，原始来源身份留在历史管理/控制层，不可直接拿上一帧编号与当前帧编号比较。模块不证明“确实为前一帧”或正确的物理时间同步。
- `img_mf_pair_join` 默认检查 tag/frameid，也可通过参数关闭；上层运算核固定使用默认检查。标记或身份不匹配的配对仍被消费并返回有效的错误像素，运算核将图像数据清零，不假装正常成功。没有自动寻找下一帧的恢复策略，系统可依据错误选择丢帧和复位。
- 配置经 `cfg_we && cfg_ready` 写入影子寄存器，`cfg_commit && cfg_ready` 提交。提交后 `cfg_pending` 阻止再次更改；在处理级接受下一个无配对错误 SOF 时生效，首像素使用新参数。提交需要先于目标 SOF 到达处理级；同沿提交/SOF 留到下次 SOF。像素可能已在配对寄存器中等待，因此精确帧配置应在上游开始该帧之前完成提交。
- 权重/alpha 范围为 0..256，`result=(a*(256-w)+b*w+128)>>8`；0 选主流，256 选辅助流。超范围配置写入被拒绝并置粘滞 `cfg_error`，不会替换合法影子值。`cfg_we` 和 `cfg_commit` 可同沿，合法新值在随后 SOF 使用。
- 复位只清控制/小寄存器，不清外部帧存储。OSD/融合使用三级弹性流水线：像素/配置采样、六个通道乘积、精确加和舍入；每级服从同一 CE 和背压。同步存储的 replay/copy 增加等待级。延迟变化不改变已接受事务的像素、元数据、错误或完成顺序；不能据此推断任意帧尺寸或 Tang Primer 20K 的资源预算。

## 具体运算约定

OSD 默认关闭，alpha 默认 256；启用后若辅助 RGB 等于启用的 `cfg_color_key` 则透明，否则混合。即使关闭，辅助全画幅像素仍须存在并参与原子配对。

帧差输入/输出为 8 位灰度，`m_data=abs(current-history)`，`m_foreground=(difference>threshold)`，默认阈值 16。第一帧是否可以比较由外部管理；本核没有隐含首帧直通。

背景建模主输入为 8 位灰度，辅助 `aux_data` 是 Q8.8 旧背景，`aux_initialized` 与辅助像素同属一次传输。未初始化位置直接把当前像素扩为 Q8.8，并输出非前景。已初始化位置使用旧背景高 8 位计算差值和前景，阈值为严格大于；默认阈值 16。更新公式 `new=old+((current*256-old)>>>shift)`，`shift=0..8`，默认 4；有符号右移对负值向负方向截断，可能产生低位偏差。默认前景冻结，即前景位置保留旧背景。

背景图像输出 `m_data` 为当前灰度，同时提供 `m_difference` 和 `m_foreground`。独立 `wb_*` 输出 Q8.8 新背景，`wb_enable=0` 代表错误配对不可写入；写回接收端仍必须消费该错误响应以解除背压。两路有独立 pending 状态，先完成一路不会重复发送，下一像素要等待两路都腾出空间。外部必须保证同一位置下一次读取前写回已可见，并等待整帧完成栅栏后才发布背景版本。

拼接只提供画布组合：`s_present/aux_present` 表示该位置有效；两者均有效时使用 `aux_seam_weight` 混合，仅一者有效时直接选它，都无效时选择提交的背景色。权重与辅助像素原子存储；两者均有效且权重>256 时返回错误。外部必须预先配准且以配置明确 `cfg_external_registration=1`，默认值 0 会对每个像素返回 0x20。该开关是调用方声明，不是配准正确性的证明。

## 错误位

图像路径的 `m_error` 随像素保持，`error_code` 为复位清除的粘滞 OR：bit0=SOF/EOL 不符，bit1=目标 frameid 不符，bit2=tag 不符，bit3=非法配置（配置错误只在粘滞状态上报），bit4=拼接重叠权重非法，bit5=拼接外部配准模式未启用。背景写回同时带有 `wb_error`。纯配对器保留原始数据供诊断，上层运算核对错误数据清零。

## 历史帧控制接口

`img_mf_history_manager` 为小型槽元数据模块，默认 4 个槽；支持 1..16 槽且 `SLOT_WIDTH` 足以表示。状态为 EMPTY=0、WRITING=1、READY=2。命令和响应均为 CE 下 valid/ready 协议，每个命令恰好一份可背压响应，响应内容在阻塞时保持。

| cmd_opcode | 行为 |
|---|---|
| 0 | 指定 EMPTY 槽分配为 WRITING，记录 frameid、非零宽高、width×height 样本数和自然回卷序号 |
| 1 | 仅 WRITING 槽可提交；frameid 和外部报告 sample_count 必须与分配值相同，随后 READY |
| 2 | 查询非 EMPTY 槽，返回元数据和状态 |
| 3 | 释放非 EMPTY 槽；调用方负责保证没有未完成存储访问 |
| 4 | 全部失效，不清图像存储也不回退全局分配序号 |
| 5..7 | 明确返回 UNSUPPORTED |

元数据管理错误是独立命名空间：0x01=槽越界，0x02=状态非法，0x04=几何/样本数不符，0x08=未支持命令，0x10=提交 frameid 不符，0x40=参数配置不支持。错误命令不修改槽状态。查询/释放根据槽选择，不做时间次序搜索或自动淘汰。提交仅相信外部计数，不能视为 RAM 数据完整性验证。

`img_mf_history_ram_adapter` 现为 `img_mf_dual_frame_store` 的真实实现封装。存储命令：0=捕获主帧，1=捕获辅助帧，2=同时捕获，3=双帧成对回放，4=主帧回放，5=辅助帧回放，6=全部失效，7=把主帧低 8 位转换成 Q8.8 背景写到 bank1。捕获逐像素检查目标 frameid、顺序 tag、SOF/EOL；错误/超时保持所写 bank 无效。只有完全写入的帧才可回放。原 RAM 不在复位时清零，`frames_valid` 随复位失效。

## 整帧应用控制

`img_mf_frame_application` 命令 0/1/2 与存储捕获相同；3=OSD，4=帧差，5=背景更新，6=权重融合，7=失效双帧，8=从主帧初始化背景。命令中保存配置和目标 frameid，处理命令对所有 W×H 像素产生输出，在最后图像像素已被接收且（背景模式）最后背景写回已完成后才返回响应。响应背压不重复执行。OSD/融合的 `cfg_weight` 为辅助权重 0..256，OSD 支持精确色键。

典型背景流程：捕获主帧（命令 0）→初始化背景（命令 8）→捕获下一主帧（命令 0）→更新并输出前景（命令 5）。后续主帧不会清除有效背景。也可命令 1 显式装入 Q8.8 背景。差分比较的是两 bank 低 8 位，不能把 Q8.8 背景直接当作 RGB/灰度辅助图使用；应重新捕获所需格式。背景采用单一 EWMA，不等同于 GMM 或语义背景模型。

## 自动拼接与坐标

`img_mf_auto_stitch` 命令 0/1/2=捕获，3=自动配准并生成拼接帧，4=使用本命令保存的外供逆单应矩阵生成帧，5=失效双帧，其余返回 0x80。两帧必须来自相同静态场景、满足亮度 SAD 和平移模型；自动模式会真实比较所有 `[-MAX_SHIFT,+MAX_SHIFT]²` 平移。中央 `(W-2S)×(H-2S)` ROI 对所有候选相同。最小代价候选胜出，相同代价按扫描顺序；`confidence=second_cost-best_cost`，小于 `MIN_CONFIDENCE` 则整条命令返回 0x20、不输出伪成功画布。该差值不能代表普适统计置信度。

约定 `main(x,y) ≈ aux(x+dx,y+dy)`；输出画布固定为 `(W+2S)×(H+2S)`，输出坐标 `(u,v)` 对应主帧坐标 `(u-S,v-S)`。自动模式使用 SAD 结果实际读辅助 bank 的 `(x+dx,y+dy)`；双有效位置加权混合，单有效位置直接取该像素，其余输出 `cfg_background`。所有输出带顺序 tag、行末和目标 frameid。

外供模式保存 9 个有符号 32 位齐次系数，使用 `aux_x=floor((h00*x+h01*y+h02)/(h20*x+h21*y+h22))` 和同样的 y 式；统一缩放系数不改变映射，可传整数或同精度定点系数。分母为零的位置判为辅助缺口。三个分母系数均为零的命令立即拒绝为 0x08。采用最近下界像素取样，无双线性/抗混叠；画布仍为固定尺寸，范围外内容裁掉。该模式是调用方提供变换，**不声称自动求解单应矩阵**。当前生产实现使用共享迭代有符号向下取整除法器；请求、幅值、分段减法和恢复均注册，保持原数值及错误合同。

## 存储、错误和完成边界

RAM 是同步读，没有整帧异步读取或复位清存储的循环。随机双读在空闲时接受，一份背压响应保存两像素；写回优先于同端口外部调用的调度由 top 保证。直接调用存储模块时，不得把随机写与捕获、初始化或同地址回放混用；支持的写回路径只修改已读出的早期像素。捕获超时按无进展的使能周期计数，正常输入/输出外部背压可无限等待，这是 valid/ready 接口约定。全部输入 valid 必须独立于 ready，所有端点共用 CE。

整帧 top/存储错误空间独立于像素级：0x01=捕获标记/tag/frameid 错，0x02=捕获超时，0x04=缺少有效 bank，0x08=非法配置，0x10=随机地址越界，0x20=配准歧义，0x40=参数/内部状态不支持，0x80=未知命令。可背压响应直到接收且只产生一份；操作成功具有非空的完整像素结果（捕获、清除、背景初始化等控制命令除外）。帧完成不表示物理相机同步，输入场景身份由调用方管理。

## 已执行的组级开发检查

```powershell
. .\scripts\env.ps1
$mfPath='cores/system/common_scaffold/image/multiframe'
$mfSources=Get-ChildItem -LiteralPath $mfPath -Filter '*.v' | ForEach-Object { $_.FullName }
iverilog -g2012 -Wall -Wno-timescale -tnull @mfSources
iverilog -g2012 -Wall -Wno-timescale -s tb_img_mf_frame_group -o "$mfPath/mf_frame_group.vvp" @mfSources
vvp "$mfPath/mf_frame_group.vvp"
```

结果：编译成功，history_manager 仅有数组 `@*` 敏感列表提示；组级仿真输出 `MF GROUP PASS`。独立整数参考检查全帧 OSD/色键、差分/前景、Q8.8 初始化、EWMA 写回与再次读取、融合、已知 `(dx=1,dy=0)` 的实际 SAD 配准及完整画布、外供单应矩阵路径、CE 暂停、输出/响应背压、歧义拒绝、非法命令、捕获超时和复位失效。没有运行逐核大规模验证或原混合格密码工程回归；未改该工程及 UART。上述旧命令仅记录原开发检查；重跑时请使用下方自动清理临时输出的脚本，保留原有 `mf_frame_group.vvp` 基线。

## v101b 生产回写与物理证据

```powershell
python -B cores/system/common_scaffold/image/multiframe/evidence/production_v101b_20261017/integrate_and_verify.py
```

实际执行的生产回归包含：完整 MF GROUP；同一份独立 Python 黄金下的 38 条整帧命令 normal、checker fault→FAIL0001、异步 reset/recovery；256 向量混合流水线正常和复位重跑，覆盖全部流水级填满、长背压、CE、透明/错误、权重 0/1/96/128/129/255/256。整帧仍为 88 主输入、61 辅输入、168 输出、60 次背景写回、11 条预期错误；摘要保持 `EDA58BD3`，14176 周期。没有修改旧黄金或旧基线，临时 vvp 由 TemporaryDirectory 删除。

原 `frame_application` 和 `processing_bank` 字节未改；只回写 dual_frame_store、OSD、fusion 并新增 RGB helper。未带入候选板测专用 writeback probe。旧源码、README 和 manifest 原字节备份、生产源码 SHA、完整命令和日志位于 [production_v101b_20261017](evidence/production_v101b_20261017/README.md)。

冻结候选位于 `../../board/tang25k/build/image_multiframe_selftest_25k_20261017_v101b_pipeline/`。实际路由 Fmax 为 56.16/61.30 MHz，hold 和 ≤15K LUT/≤4 DSP 门禁均通过；10 个物理 BRAM 对应综合的 9 个 BRAM primitive。bitstream SHA256 为 `ebdfea24ce27fa5674574b5d6c299eecef66d4e449453ad192e5fbea9286854e`。三次 SRAM/UART 记录及 SHA 在候选 `board_validation_summary.json` 和生产 `regression_summary.json` 中。

CE 元数据更正以候选 `board_validation_scope_correction.json` 为准：原派生摘要误写 CE13/16，冻结源码 `cycle_count[1:0]==0` 及综合网表均为 CE1/4；原摘要、三份板测记录及初次生产证据字节均保留。更正不改变 50 MHz 时序检查、bitstream 或三次实际功能 PASS。

严格物理 UART 合同（结尾 CRLF，之后至少 12 个静默位）：

```text
MFR PASS F=26 I=0058 A=003D O=00A8 E=0000 D=EDA58BD3 C=F
```

外部设计审查使用固定版本的 OpenCV `accum.cpp` 和 LaForest ready/valid 资料，来源、HTTP/SHA 和许可审查在候选 `EXTERNAL_DESIGN_REFERENCES.md`、`external_http_audit.json`。本地 Q8.8 有符号向下截断及前景冻结与 OpenCV 浮点语义不同；未导入第三方代码。


## v105d 自动拼接生产回写与板验

实际生产源码已回写：自动拼接、SAD、新增同步 BRAM 随机读 store 变体及共享 signed-floor divider。
公共 `img_mf_dual_frame_store.v` 字节保持 v101b 已验证版本；两个源清单已纳入新增 helper。
随机读请求/范围检查、RAM 读及响应分别注册，响应延迟有意从 1 改为 2 个使能边沿。

生产回归实际编译上述四份生产 RTL，8 组 SAD、3 组 divider、3 组 store/标量、6 组地址边界、
6 项整帧板仿真及原 MF GROUP 全部 PASS。黄金值、checker 和 1M watchdog 未改；
正常/错误注入/复位恢复均为 167196 周期，旧参考为 53836 周期。
实际执行记录见 `sim/production_autostitch_v105c_20261017/run_20261016_223207_614096/summary.json`。
该历史 runner 目录名保留，运行记录显式选择的是最终 v105d 候选。

冻结候选 `image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe` 在修正 BRAM 时序库下
实测 59.85/60.67 MHz，hold/全部资源 PASS：7804 LUT、1862 FF、8 个实际 BRAM、0 DSP。
50 MHz 实际时钟、CE1/4，无 multicycle 例外。三次独立 SRAM 加载均识别 IDCODE `0x1281b`，
每次完整 58 字节一致，行后观察不少于 0.1 秒且无额外字节：

```text
STC PASS F=20 I=003E A=004B O=012C E=0000 D=64FB8FCF C=F
```

串口结尾是 CRLF。位流 SHA256：`2af204973b9b3abb2cb9c4c9cb6d2f087180cbacd6860fa3370b1579efd06360`。
物理验收仅覆盖 RGB888 4×3、shift1、两 ROI 采样、九 trial、6×5 画布，
32 命令、62 主/75 辅输入、300 输出、14 个预期错误；更大参数仿真不代表大帧时序或实时吞吐验收。
完整源码、冻结、生产回归、三板记录的路径及 SHA 见
[release_summary.json](evidence/production_autostitch_v105d_20261017/release_summary.json)。
生产模块更名后的新位流没有重新烧录；板验使用冻结候选，实际生产 RTL 另有完整回归证据。

外部参考固定版本 FPGA Design Elements 的 RAM/计数器/握手流水实现及 OpenCV，
URL、HTTP 状态、SHA、源码选行与许可在候选 `external_address_pipeline_http_audit.json` 等记录中。
未导入第三方代码；编译临时目录已自动清理，原基线与失败证据保留。
