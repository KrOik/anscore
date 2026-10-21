# 图像处理功能代码

本目录提供实际运算模块及可调用的帧处理入口。先前的 Canny、复杂降噪、开闭运算、整帧 HE/CLAHE、去雾、历史帧存储和几何放大占位已由功能实现替代。原始小核、兼容层和已有失败记录保留；不要把 legacy 错误应答接口当作帧处理入口。

| 功能 | 推荐入口 | 输入和边界 |
|---|---|---|
| Bayer 插值 | `pipelines/img_bayer_window_frontend_draft.v` | RAW8/10/12，四种 Bayer，相邻窗口双线性；裁边至 (W−2)×(H−2) |
| 自动白平衡、CCM、亮度/对比度、Gamma、色彩转换 | `pipelines/img_color_pipeline_auto.v` | RGB888，闭环灰世界 AWB；可选 BT.601 全范围 YCbCr444；手动链另保留 |
| 均值/高斯/中值、Sobel/Prewitt/Laplacian | `filters/rtl/img_filter_*3x3.v`, `img_edge_*3x3.v` | 已对齐外部窗口；`window/` 可供裁边窗口 |
| 双边降噪 | `filters/rtl/img_filter_bilateral3x3.v` | 空间/灰度指数权重；外部 3×3 窗口 |
| 导向/NLM/时域降噪 | `filters/rtl/img_filter_guided.v`, `img_filter_nlm.v`, `img_filter_temporal_denoise.v` | 内部同步帧/历史 RAM，有界尺寸；导向源/guide 独立配对 |
| Canny | `filters/rtl/img_edge_canny.v` | 完整多阶段与全帧 8 连通滞后追踪 |
| 二值化、腐蚀/膨胀、开/闭运算 | `filters/rtl/img_filter_threshold.v`, `img_morph_*.v` | 单核外部窗口；开/闭入口自带完整中间帧 |
| 局部自适应均值二值化 | `filters/rtl/img_filter_adaptive_mean3x3.v` | 外部3×3窗口；精确均值、有符号偏置、可反相；1/8/12/16位仿真通过，未板验 |
| 局部自适应高斯二值化 | `filters/rtl/img_filter_adaptive_gaussian3x3.v` | 外部3×3窗口；固定可分离[1,2,1]权重，精确比较、有符号偏置/反相；未板验 |
| 自适应均值/高斯整帧流 | `pipelines/img_adaptive_threshold_frame.v` | 内部两行同步缓存；W×H裁边至(W−2)×(H−2)，按帧锁存偏置/反相/tag，未板验 |
| Otsu自动阈值求解 | `histogram/rtl/img_hist_otsu_threshold.v` | 输入256项直方图；精确有理数比较；图像缓存/阈值回放由调用方提供，未板验 |
| 同帧Otsu二值化 | `histogram/rtl/img_hist_otsu_frame.v` | 内部同步帧缓存/直方图/阈值求解/回放，严格大于阈值，可反相，标记错误帧无输出；未板验 |
| HE / CLAHE | `histogram/rtl/img_hist_he_frame.v`, `img_hist_clahe_frame.v` | 内部帧存储/直方图/LUT，CLAHE 严格限幅重分配和多 tile 插值 |
| 去雾 | `dehaze/img_dh_dehaze_frame.v` | RGB888，同帧暗通道、自动大气光、透射率、可选真实 guided 和恢复 |
| 缩放、旋转、镜像、仿射/透视 | `geometry/rtl/img_geo_frame_buffered.v` | 内部同步帧 RAM；最近邻/双线性；任意角度通过外供逆仿射矩阵 |
| 抗混叠下采样、超采样 resolve | `geometry/rtl/img_geo_area_resample.v` | 精确像素面积重采样，支持非整数缩小 |
| 整数倍插值上采样 | `geometry/rtl/img_geo_integer_upsample.v` | 双线性；旧 `super_resolution_stub` 名称是兼容适配，不是学习型超分模型 |
| 像素反相 | `geometry/rtl/img_geo_pixel_invert.v` | 无符号全范围逐位反相 |
| OSD、帧差、背景、融合 | `multiframe/img_mf_frame_application.v` | 实际双帧存储，色键/权重、EWMA 初始化/更新/写回 |
| 自动图像拼接 | `multiframe/img_mf_auto_stitch.v` | 有界整数平移 SAD 配准并实际 warp/blend；另支持外供逆单应矩阵 |

所有原生流要求共同 `clk_en`，握手为 `clk_en && valid && ready`。不同入口的命令、tag、尺寸、像素格式和错误码以各组 README/端口为准。大多数整帧默认尺寸为 32×32 或 64×64，并可参数化；多遍顺序算法不承诺视频实时吞吐。帧错误后按最终响应丢弃该帧。

从仓库根目录构建时，可使用 `cores/system/common_scaffold/image/rtl_sources.f` 读取完整依赖；尤其 filters 的 guided 入口依赖 dehaze 的 `img_dh_guided_frame` 和 `img_dh_guided_refine`。生成文件/测试台不会混入源列表。

```powershell
python cores/system/common_scaffold/image/run_groups.py
python cores/system/common_scaffold/image/run_groups.py --compile-only
```

统一入口会编译实际 RTL 集合，并运行 core、ISP、geometry、histogram、dehaze、multiframe 的小帧分组对照，结果追加到 `build_groups_<时间>/summary.json`。这是开发阶段的接线、数值与握手检查，未进行逐核全面验收、综合、布局布线或板测。图像模块尚未接入混合密码顶层；现有 UART 合约未改。直接乘除、多个帧 RAM 和并行 CCM 乘法的目标板资源仍需后续测量，不能据此声称整套模块同时满足 15K LUT/4 DSP。
