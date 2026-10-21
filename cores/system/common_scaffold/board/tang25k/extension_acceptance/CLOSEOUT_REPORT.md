# 收尾与上板验收记录

本轮停止新增 IP 开发。MPU6050 按用户要求排除，已有材料保留为未交付状态；未完成的 indexed BMP 同样不计入交付。

| 范围 | 实际结果 | 证据 |
|---|---|---|
| 原有 48 核 | 48/48；144 次 SRAM 下载及精确 UART 比对通过；独立审计核对 202 个生产源码哈希未变 | [独立审计](../acceptance48/audit_restored_jtag_retest_20261019_224903_20261019_230451_2b462350.md) |
| HX711、Camera 配置 | 组合固件 3/3 次通过；下载后同步周期报文 | [板测记录](hx_camera/build_nolutram/board_validation_20261019_231641_421564.json) |
| DS3231 | 链路恢复后重新 3/3 次通过 | [通过记录](sensor_i2c/cases/ds3231/board_validation_20261019_232823_312054.json) |
| ADS1115 | 链路恢复后重新 3/3 次通过 | [通过记录](sensor_i2c/cases/ads1115/board_validation_20261019_232843_959391.json) |
| SHT3x | 完整 raw、CRC、温湿度换算版本 3/3 次通过；50 MHz 路由通过，最低 Fmax 59.97 MHz | [板测记录](sensor_i2c/cases/sht3x_timer_pipeline/board_validation_20261019_231543_616200.json) |
| JPEG 灰度完整编码器 v3 | 3/3 次本机 JTAG 烧录通过；每次完整 999 字节一致；6 帧实际输出全部解码，最大像素误差 1；50MHz 目标通过，最终 Fmax 65.52MHz | [板测](jpeg_delivery_v3/board_validation_20261020_010150_425018.json)、[实际图像解码](jpeg_delivery_v3/decoded_board_validation.json) |

新增外设验证为 FPGA 内部脚本化引脚回环，没有连接真实外部传感器。原 48 核使用冻结的有限测试夹具；不等于全分辨率视频、图像质量或任意参数均已上板覆盖。所有板测保持时间结论为 `HOLD_UNPROVEN`，不是完整时序签核。

23:20 使用已知通过的原版 FIR 作对照，JTAG 检测、下载返回码均为 0，但 UART 零字节，说明当前无输出现象也影响基线。该现象尚不能归因到某个新增核。用户重插并确认供电后，23:28 原版 FIR 已重新通过，DS3231、ADS1115 随后分别三次通过。[基线失败记录](../acceptance48/rtl_dsp/fir_v5_20261018_220000/functional_board_frozen_seed3_20261019_232003_679438.json)。

离线全量回归完成：141/141 项目测试通过，189/190 集成测试首次通过，144 RTL 合并编译通过，738 输入稳定。唯一失败项为白平衡参考源码下载 TLS 错误，原命令独立补跑已通过，覆盖 4 种 Bayer 排列、192 个 RTL 输出。首次失败结果原样保留，不标成单次全量通过。[原始全量结果](../../../evidence/image_extensions_20261019T134947Z_5dfb2b1c/results.json)、[独立补证审计](../../../evidence/raw_white_balance_reference_recovery_20261019T152435Z/recovery_audit.json)。RAW16、EEPROM、NOR 的来源与资源审计通过，旧 metadata 已归档；未给原失败全量结果加封版标记。

JPEG 现以 `delivery/jpeg_gray_encoder_v3` 独立版本交付，保留原标准 API。分拍乘积、累加与符号编码后，5 组正式 API 回归、57 块 DCT/IDCT、4121 组有符号乘积及原 999 字节串口仿真通过；正式交付源码直接用于上述真实板测。资源为 8242 LUT4、4940 DFF、9 BSRAM、0 DSP。原注册项目和已有冻结源码保持不变，集成时须使用交付清单的十个文件，避免同名模块重复编译。

早期 330 字节板测失败和 v2 47.16MHz 时序失败均保留，不改写为通过。[前次完整收尾快照](closeout_before_jpeg_v3_20261020.zip)。实际板测状态为 `FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN`；开源保持时间模型尚未资格化，因此不宣称完整时序签核。MPU6050、indexed BMP 仍不计入交付。

原 48 项复测新增临时位流已清理，47 份历史位流保留。[存储检查](../acceptance48/cleanup_restored_jtag_retest_20261019_224903.json)。新增外设四份已验证临时位流也已清理，释放 23,831,376 字节，保留可重建的路由、打包记录、源码哈希和日志。[清理记录](temporary_bitstream_cleanup_20261019_2331.json)。JPEG 最新失败候选的大网表压缩保留后清理，历史原始失败材料保留。

JPEG 两份新增网表经逐项哈希校验压缩为 2,067,266 字节归档，删除 39,897,623 字节原件，净节省 37,830,357 字节。本轮上述两项合计净释放 61,661,733 字节（约 61.7 MB），未删除历史基线。

本次 JPEG v3 交付与临时文件清理的最新详情见 [交付验收说明](../../../../../delivery/jpeg_gray_encoder_v3/ACCEPTANCE.md)。

最终交付压缩包为 `delivery/jpeg_gray_encoder_v3_20261020.zip`（62,762 字节，36 文件），解压后 35 项文件哈希及独立校验脚本通过。v2 新网表净清理 37,375,539 字节，v3 新网表和位流净清理 43,775,133 字节，分别见 [v2 清理记录](jpeg_delivery_v2/netlist_cleanup.json)、[v3 清理记录](jpeg_delivery_v3/temporary_artifact_cleanup.json)。[本轮最终完整性检查](final_integrity_check_20261020.json)确认 202/738 哈希未变。
