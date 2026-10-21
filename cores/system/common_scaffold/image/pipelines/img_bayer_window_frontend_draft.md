# RAW Bayer 窗口前端

此文件说明 `img_bayer_window_frontend_draft.v`。已完成 RAW8/10/12×四相小图、CE/背压、帧标记错误和非法尺寸的组级独立参考回归。未进行穷举验证、综合或上板；资源及时序未知。旧 draft 名称保留兼容。

依赖模块：`../window/img_window3x3_valid_draft.v`、`../isp/img_isp_bayer_interpolate.v`。

## 事务与像素接口

- `RAW_BITS` 默认 8，支持 8/10/12；`MAX_WIDTH` 默认 1920，合法范围 3…65535。非正 RAW_BITS 的输入端口保留一位，仅用于合法表达拒绝参数路径。
- `cfg_valid && cfg_ready && clk_en` 开始一帧，原图 `cfg_width/height` 均至少为 3，宽度不得超过 MAX_WIDTH。高度/宽度使用 16 位无符号整数。
- `cfg_pattern`：0=RGGB，1=GRBG，2=GBRG，3=BGGR，按原图左上角定义。只有尺寸合法的配置握手，才同时启动窗口核并对 Bayer 核执行 shadow write+commit。非法尺寸不会残留 Bayer `cfg_pending`。
- 原始像素采用 `s_data/s_valid/s_ready/s_sof/s_eol`；输入首像素带 SOF，每行末像素带 EOL。必须提供配置指定的完整 W×H 帧。
- RGB888 采用 `m_data/m_valid/m_ready/m_sof/m_eol/m_eof`。R 位于 `[23:16]`，G `[15:8]`，B `[7:0]`。EOF 跟随最后 RGB，并在背压期间保持。
- 输入、输出、配置和响应均采用共同 CE：仅在 `clk_en && valid && ready` 时传输。CE=0 时所有已挂起输出保持稳定。调用方必须共同遵守 CE。

## 裁边与时序

窗口核使用两行同步存储，只输出完整 3×3 窗口。原图 W×H 输出 `(W-2)×(H-2)`，`out_width/height` 在合法配置后报告该尺寸。不填充边界，不生成原图外沿一像素。窗口返回的原图中心坐标 `m_x/m_y` 奇偶直接送给 Bayer 核；不因裁边重新从零计算 CFA 奇偶。

窗口输出按行优先的低位 tap0→tap8 连接 Bayer 窗口，中心数据单独作为 Bayer `s_data`。窗口输入发起与计算各占一拍，II≥2；Bayer 为一项弹性输出寄存器。实际吞吐受窗口和下游背压共同决定。

EOF 使用与 Bayer 输出寄存器相同的输入接受/输出退休条件，在同步侧带寄存器中延后一拍；可在消费旧像素的同拍接收新窗口，不要求独立空拍。

`rsp_valid/rsp_ready/rsp_error` 是整帧事务响应。正常/输入标记错误的响应均等待窗口响应和最后 RGB 的实际下游消费，不能将“最后窗口送进 Bayer”视为整个前端完成。响应未消费前不接受下一配置。错误导致中止时，停止接收新 RAW/window，先保留并排空已呈现的 RGB，再复位内部核并响应；已中止的部分帧不保证具有最终 EOF。全局 `rst_n=0` 立即中止事务并清除响应，不额外产生完成响应。

| rsp_error | 含义 |
| --- | --- |
| 0 | 正常完成 |
| 1 | 非法尺寸，或窗口核拒绝配置 |
| 2 | 窗口核检测到输入 SOF/EOL 不符合指定帧布局，最终 RGB 消费后报告 |
| 3 | 窗口核/前端控制状态异常 |
| 4 | 不支持的 RAW_BITS，配置后有限响应，像素永不接收 |
| 5 | Bayer 核不支持当前实例参数 |
| 6 | Bayer 核报告错误 |
| 7 | 不支持的 MAX_WIDTH 参数，配置后有限响应，像素永不接收 |

非法参数/尺寸响应在配置握手之后出现，不依赖输入像素或下游 RGB ready；响应本身依然遵守 rsp_ready 背压。不完整输入帧、源端永久停顿、未遵守 valid 稳定规则等不由本前端超时诊断。

Bayer 沿用双线性插值和 RAW→RGB888 截位；无边缘自适应、黑电平、坏点修复。后级可接 img_color_pipeline_auto。完整执行记录通过 `python cores/system/common_scaffold/image/pipelines/run_group_regression.py` 生成在新的 build_group_时间目录。片上行存储映射、资源和时序仍待测量。
