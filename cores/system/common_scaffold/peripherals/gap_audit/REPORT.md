# 常用外设缺口查重审计

本次只读检查全仓可读 RTL，排除 build、evidence、board、scratch、生成网表、ILA 和加密实现；检索后逐份查看状态机、端口及数据路径。`gap_audit.json` 记录 3,752 份可读源文件的检索范围、15 份主要源码 SHA256、命中位置及相同源码副本。没有开发新 RTL，也没有将源码存在等同于功能验证通过。

| 候选能力 | 源码实际情况 | 应补范围 | 建议 |
|---|---|---|---|
| 真正 SPI slave | **已有**模式 0..3、8/16 位帧、寄存器寻址、连续读写及 MISO 三态；另有 loopback fixture | 如需通用 TX/RX FIFO 流接口，在现有核上扩展并独立验证异步引脚时序 | 不重复开发同功能寄存器 slave |
| 双声道 I2S RX/TX | **已有**立体声接收 slave、发送 master；TX 包含 I2S/左对齐和欠载计数 | 接口整理、独立音频时序复核 | 复用已有，不记为缺失 |
| 多路 I2S 接收 | **已有**4 根串行数据线上的 8 通道接收，以及 7 通道麦克风映射；名为 `stub` 的模块也包含实际采集逻辑 | 通用可配置 lane/位宽、缓冲和发送方向 | P1 增强 |
| 单数据线多槽 TDM RX/TX | 未找到通用物理串行接口；`acc_tdm8_demux` 接收的是已经解串的数值和通道标签 | 2/4/8/16 槽、16/24/32 位、FS/BCLK/SD、DSP-A/B 对齐、收发双向及欠载/溢出/帧错 | **P0** |
| PWM 输入 / RC 舵机测量 | 已有共享输入捕获，但宽度计数仅 4 位、固定 watchdog=3；另有可参数化宽度的 glitch monitor | 24/32 位高宽、低宽、周期的完整一致结果，失脉冲/卡高低检测，RC 范围检查及稳定 host 输出 | **P0**，复用边沿捕获思想 |
| 频率计 / 周期计 | 已有调试 top 内 PLL 固定门控计数片段；没有找到通用独立周期计模块 | 参数化门控频率/倒数周期测量、无边沿超时、溢出与必要 CDC 快照 | P1，可与 PWM 共用前端 |
| 1-Wire reset/byte/CRC | **已有**物理 reset、presence、读写 byte 和 CRC 控制器，能力超过 slot 算子 | 先复核旧核 tick/CE 的物理时序约定，再决定包装或复用 | 不重复从 slot 开始写 |
| 1-Wire ROM/search/DS18B20 事务 | 未找到完整 ROM 枚举或 DS18B20 测温调度 | ROM read/match/skip/search、64 位 ROM CRC；Convert T、忙等待、scratchpad 9 字节和 CRC、带符号温度输出 | P1；明确外部供电与寄生供电边界 |

## 关键实现证据

- `cores/system/ip_series/src/ips_spi_slave_reg.v:32` 是真实可读实现；`:100` 驱动/释放 MISO，`:163`、`:171`、`:176` 分别实现 command/write/read 状态。`cores/communication/primitives/src/spi_slave_model.v:1` 明确属于自测 fixture，不能单独当作通用 slave 交付。
- `cores/system/ip_series/src/ips_i2s_tx_master.v:29` 提供双声道发送；`:42`、`:43` 输入左右声道，`:57` 固定一个 LRCLK 周期为两槽。`cores/system/ip_series/src/ips_i2s_rx_slave.v:33`、`:51` 为接收端和一位声道标签，属于 stereo 范围。
- `projects/micarry_audio_capture_20k/src/micarry_i2s_slots.v:71` 真实移位采集四路左右声道，`:85` 发布 8 路样本。`projects/micarry_channel_map_20k/src/micarry_i2s_rx.v:1` 实现 7 通道映射。`cores/acquisition/micarray_doa/src/i2s_quad_rx_stub.v:95` 之后有 BCLK 边沿、移位采集、帧发布逻辑，不能仅凭文件名把它判为占位。
- `cores/acceleration/operator_library/rtl/acc_tdm8_demux.v:6` 端口是 `a,b,c` 数值，`:37` 按标签分发已解串样本；不存在 FS/BCLK/串行数据引脚。它不是 TDM 物理收发器。
- `cores/system/ip_series/src/ips_timer4_pwm_cap.v:105` 固定 `WDT_PRE=3`，`:115` 捕获计数器为 4 位，`:254` 记录宽度；不具备常用毫秒级 RC 波形的通用动态范围。`cores/system/ip_series/src/ips_glitch_detector.v:72` 起提供可参数化计数宽度、脉冲最小最大宽度、glitch 监测，已有能力必须保留；它没有完整配对输出 high/low/period 的应用接口。
- `cores/system/extended_library/src/top_tapedbg.v:147` 至 `:161` 是真实 PLL 时钟频率门控计数片段，不能写成“频率计完全不存在”。`cores/signal_processing/dsp_isp_library/dsp/hilbert/rtl/phase_freq.sv:86` 是 IQ 相位差分估计频率，属于 DSP 算法，不是外部数字引脚周期计数。
- `cores/system/ip_series/src/ips_one_wire_master.v:98` 至 `:101` 只有 IDLE/RESET/WRITE/READ 四类底层状态；`:164` 接受 reset/write/read 命令，`:199` 逐位完成一字节，并处理 CRC。没有 ROM discrepancy 树遍历、器件 ROM 表、Convert T 或 Read Scratchpad 的高层状态机。
- `cores/acceleration/operator_library/rtl/acc_onewire_slot.v:118` 解析 host 提供的电平及持续时间，`:179` 对几个 ROM 类字节做识别标记；没有实际物理引脚控制和 ROM search 事务。识别 `0x33`、`0xCC` 不等于执行完整协议。
- `anscore/` 下有上述部分核的相同字节副本，详见 JSON 的 SHA 去重结果，未当作新增独立能力。`references/Sped0n_eko/.../design/i2s/i2s_recv.v:23` 也是可读 stereo RX 参考，不是多槽 TDM 核。

## 下一轮建议边界

优先两个可复用核：通用 TDM RX/TX，以及同步输入 high/low/period 捕获。频率计在第二个核的基础上形成独立接口，避免重复写同步/超时/溢出前端。之后补 1-Wire 应用调度，复用已有 reset/byte 层；先外部供电单器件测温，再扩展多 ROM 搜索。不要再新建等价 SPI register slave 或 stereo I2S 核来增加项目数。

`public_references.json` 保留实际下载的 Paul Stoffregen OneWire 与 DallasTemperature 成熟源代码 SHA256、字节数和小段引用，用于界定 ROM search/discrepancy、ROM 选择和测温事务层的范围。它们是软件参考，不可当作已经存在的 FPGA RTL，也没有复制实现。本轮下载在内存完成，无下载大文件和仿真临时文件。

命令：`python -B cores/system/common_scaffold/peripherals/gap_audit/audit_gaps.py`；可选重取公开参考：`python -B cores/system/common_scaffold/peripherals/gap_audit/fetch_references.py`。状态为源码审计完成，不是仿真、综合或上板验收 PASS。
