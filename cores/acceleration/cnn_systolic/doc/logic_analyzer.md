# 逻辑分析仪标定记录（fx2lafw / Muse Lab 8ch）

## 设备识别

- 型号：sigrok fx2lafw 兼容 8 通道逻辑分析仪（Muse Lab 类）
- USB：VID:PID = `1D50:608C`，字符串 `SIGROK_FX2_8CH`
- 驱动：`fx2lafw:conn=2.2`（sigrok 后端）
- **不是 COM 口设备**——Windows 上的 COM10 是无关 root 端口，打不开。
  控制必须用 `sigrok-cli` / PulseView / libusb。
- 板端 UART 仍是 COM24（FT2232H，0403:6010），与 LA 无关。

软件：

- sigrok-cli 0.7.2：`C:\Program Files\sigrok\sigrok-cli\sigrok-cli.exe`
- PulseView：`C:\Program Files (x86)\sigrok\PulseView\pulseview.exe`

## 标定方法

探针 bitstream `build_oss/la_probe.fs`（源：`src/la_probe_top.v` +
`src/la_probe.cst`）：8 个目标引脚 one-hot 轮转，每个引脚占一个
65536 拍时隙（@27MHz ≈ 2.427ms），周期重复。时隙号即引脚序号：

| 时隙 | 引脚 |
|---|---|
| 0 | A11 |
| 1 | B11 |
| 2 | N6 |
| 3 | D11 |
| 4 | N9 |
| 5 | N7 |
| 6 | L9 |
| 7 | N8 |

采集命令：

```powershell
sigrok-cli -d fx2lafw --config samplerate=1m \
    -o doc/la_probe_capture.bin -O binary --samples 50000
```

二进制格式：每字节 8 位，bit N = 通道 DN 电平，50000 样本 = 50ms。

## 实测结果（2026-09，doc/la_probe_capture.bin 解码）

每通道上升沿时隙（多数表决）：

| LA 通道 | 上升沿时刻 | 时隙 | → FPGA 引脚 |
|---|---|---|---|
| D0 | 0.21 ms | 0 | **A11** |
| D1 | 2.64 ms | 1 | **B11** |
| D2 | 5.07 ms | 2 | **N6** |
| D3 | 7.49 ms | 3 | **D11** |
| D4 | 9.92 ms | 4 | **N9** |
| D5 | 12.35 ms | 5 | **N7** |
| D6 | 14.78 ms | 6 | **L9** |
| D7 | ~17.2 ms | 7 | **N8** |

结论：当前接线为 **D0–D7 顺序对应 A11,B11,N6,D11,N9,N7,L9,N8**，
8/8 通道一一对应、无交叉、无静默通道。D7 首个"上升沿"在 0ms 是
采集起点落在其高电平内，时隙表决仍为 7，不影响结论。

## 复现

解码脚本逻辑（doc/la_probe_capture.bin → 映射）：

```python
d = open('doc/la_probe_capture.bin','rb').read()
SLOT = 65536/27e6; SR = 1e6
for ch in range(8):
    prev, rises = 0, []
    for i,b in enumerate(d):
        v = (b>>ch)&1
        if v and not prev: rises.append(i)
        prev = v
    slots = [int((t/SR)/SLOT)%8 for t in rises]
    # 多数表决时隙号 → 引脚名（上表）
```

## 使用注意

- fx2lafw 8ch 实际采样率上限约 24MHz；27MHz 核时钟为欠采样。帧级
  /节拍级事件用 1MHz 足够；拍级沿分析需 ce 降速或 PLL 变体。
- 接线改动后必须重新跑探针标定——映射以实测为准。
