# DSP 与图像处理接口框架

此目录保留早期统一 ABI 模板。已实现的图像算法和可调用帧处理入口位于
[image/README.md](../image/README.md)，使用该目录源列表；无需加载本目录
的同类 `cip_image_*` 模板。这里的模板检查结果在总报告中单列为 legacy。

FIR、IIR biquad、resampler、CIC、CORDIC、FFT的6个旧入口已接入功能算法，命令和数值约定见
[FUNCTIONAL_DSP_ABI.md](FUNCTIONAL_DSP_ABI.md)。下述占位协议只适用于42个图像模板。
DSP算法的独立入口见 [DSP说明](../dsp/README.md)。

本目录其余算法核均为 **placeholder**，不计算算法结果。它们提供可编译的
命令、数据流、参数和存储接口，供后续接入现有库或逐核实现。测试 PASS
只代表接口拒绝行为正确；不是去雾、缩放、ISP 或其他算法验证通过。

## 协议

* 原生握手：同一时钟域双方共享 `clk_en`，仅在 `clk_en && valid && ready`
  时完成传输。CE=0 保持响应；背压期间保持响应 tag/error。
* 每条被接收的 `cmd_valid` 命令产生一个 `rsp_valid`，`rsp_error=2'b01`
  表示 UNSUPPORTED，`rsp_tag` 原样返回。复位取消未完成命令。
* `s_ready=0`、`m_valid=0`，不消耗样本，不输出伪造图像。调用方先提交
  命令，检查响应，再送帧；收到 UNSUPPORTED 应跳过该核或选用软件路径。
* 图像流 `s_sof` 对应帧首像素，`s_eol` 对应每行末像素；输出同理。宽高
  由命令参数给出。默认为 DATA_W=24 的 RGB888；其他位宽可编译，但格式
  尚未实现。Bayer、灰度及 YUV 的实际位排列须在后续 SPEC 中固定。
* 所有配置端口当前均保留、忽略，命令仍返回 UNSUPPORTED。未实现配置
  校验、系数加载和帧级原子生效，不把接口存在当作功能支持。

## 图像框架覆盖

| 分类 | 模块后缀（均带 `cip_image_` 前缀） | 后续实现要点 |
|---|---|---|
| 去雾 | dehaze、dark_channel、transmission、recover | 大气光、暗通道窗口、透射率下限、细化和恢复饱和 |
| ISP | bayer_demosaic、gamma、awb、ccm | Bayer 排列/位宽、LUT 双缓冲、统计/增益、矩阵/偏移 |
| 直方图与色彩 | histogram、he、clahe、brightness_contrast、color_convert | CDF、分块裁剪与插值、范围及定点精度 |
| 降噪 | mean_filter、gaussian_filter、median_filter、bilateral_filter、guided_filter、temporal_denoise、nlm_denoise | 边界策略、权重、窗口、历史帧及运动适应 |
| 边缘与分割 | sobel、prewitt、laplacian、canny、threshold、morphology | Canny 连接滞后判定；固定/Otsu/自适应阈值；腐蚀/膨胀/开闭 |
| 几何与采样 | scaler、rotate、downsample、upsample、super_resolution、affine、mirror_flip、invert、perspective | 抗混叠、插值、逆映射、帧缓存及无效区域填充 |
| 多帧/组合 | osd、frame_difference、background_model、stitch、fusion | Alpha/色键、历史帧、配准、接缝和曝光一致性 |
| 支撑 | window、framebuffer | 行缓存、窗口、帧存取及带宽仲裁 |

“集合变化”按几何变换理解。`mirror_flip` 预留水平镜像/垂直翻转；
`invert` 预留像素强度反相。`upsample` 为插值上采样，`super_resolution`
为依赖模型/权重的超分辨率；两者不混称。拼接预留对齐后双输入及外部帧
访问；特征提取/匹配、相机标定、模型训练与权重生成不在当前框架内。

## 参数与辅助通道

* `cfg_src_width/height`、`cfg_dst_width/height`：输入输出帧尺寸。
* `cfg_mode`、`cfg_param0/1`：各核运行模式、强度/阈值/缩放等参数的保留位。
  最终位语义由每核实现固定，当前不能当成已支持的软件 ABI。
* `coeff_valid/ready/addr/data`：Gamma/CLAHE LUT、CCM/滤波/变换矩阵及权重
  的加载接口。占位 `coeff_ready=0`，不默默丢弃配置。
* `aux_data/valid/ready/sof/eol`：OSD、融合、引导、历史帧等第二像素流。
  占位 `aux_ready=0`；实际帧匹配与错帧处理待实现。
* `cfg_frame_base/stride`、`cfg_aux_base`：外部帧存储地址框架。
* `mem_req_valid/ready/write/addr/wdata/wstrb` 与
  `mem_rsp_valid/ready/rdata/error`：32 位单事务存储接口预留；不等同 AXI。
  占位不发请求、不接收响应；将来需绑定请求排序、位宽转换和仲裁规则。

已有 DSP/ISP 功能库可作为实现来源，接入时先核验接口、参数与实际验证
边界。本目录不会替换或降级它们。

```powershell
python cores/system/common_scaffold/signal_video/generate.py --check
python cores/system/common_scaffold/signal_video/run_tests.py
```

生成器无参数更新占位RTL和manifest，保留手写功能适配器；`--check` 只检查一致性。
仿真遍历全部接口，验证错误响应、tag、背压、CE、复位与所有数据通道静止。
