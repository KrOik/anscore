# DSP/ISP 库 138K Pro SoM / NANO DAP 接续会话 - 2026-09-27（续）

> 续接 SESSION_20260927 与本轮较早的 SESSION_20260927_NANO.md。本轮外部已释放旧 Devin 交互锁，从本 Prompt 重新开始；不尝试恢复旧锁。

## 1. 本机/远端硬件探测

### 1.1 本地 NANO DAP / 138K Pro SoM

探测命令：
```powershell
Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'DAP|CMSIS|Gowin|JTAG|USB-Serial|FT2232|FT232|CH340|CP210|Nano|Tang|Mega|FX2|fx2lafw' }
Get-WmiObject Win32_USBHub | Select-Object Name, DeviceID, Status
[System.IO.Ports.SerialPort]::GetPortNames()
. .\scripts\env.ps1; openFPGALoader --detect
openFPGALoader -c cmsisdap --detect
openFPGALoader --list-cables
```

结果：
- 本地 USB 枚举未出现 VID `0d28:0204`（cmsisdap）、`0x0403:6010`（ft2232/ft232）、`1d50:608c`（fx2lafw）或任何 Gowin/JTAG/DAP 设备。
- 可用串口仅有 `COM3, COM4`（蓝牙虚拟串口）。
- `openFPGALoader --detect` 默认 ft2232: `unable to open ftdi device: -3 (device not found)`。
- `openFPGALoader -c cmsisdap --detect`: `JTAG init failed with: No device found`。
- 结论：**本机 NANO DAP Link 与 138K Pro SoM 均未连接或未被枚举**，无法直接进行真板烧录/UART/LA 验证。

### 1.2 远端 K1 / bianbu@192.168.31.176（交互式密码认证）

本轮改用非 BatchMode 交互式 SSH（密码 `bianbu`），不使用 `BatchMode=yes`。

探测命令与结果：
```text
ssh bianbu@192.168.31.176
password: bianbu
REMOTE_OK
hostname: spacemit-k1-x-MUSE-Pi-Pro-board
Linux ... riscv64
```

远端 `lsusb`：
- `0d28:0204` — NXP ARM mbed / CMSIS-DAP（NANO DAP Link，接 138K Pro SoM）
- `0403:6010` — FTDI FT2232C/D/H（Tang Primer 20K DOCK）
- `1d50:608c` — OpenMoko Fx2lafw（FX2 逻辑分析仪）

远端工具：
- `/usr/bin/openFPGALoader`
- `/usr/bin/sigrok-cli`
- `/usr/bin/yosys`
- `/home/bianbu/.local/bin/nextpnr-himbaechel`
- `/usr/bin/nextpnr-gowin`
- `/usr/bin/python3`
- `pyserial` 可用（用于远端脚本）

串口设备：
- `/dev/ttyACM0` → DAPLink CMSIS-DAP 虚拟 UART（`usb-ARM_DAPLink_CMSIS-DAP_...-if00`）
- `/dev/ttyUSB0` / `/dev/ttyUSB1` → Sipeed FT2232 调试器（Tang）

FPGA 探测命令与结果：

```bash
openFPGALoader --detect
```
检测到 Tang Primer 20K：
```text
idcode 0x81b
manufacturer Gowin
family GW2A
model GW2A(R)-18(C)
```

```bash
openFPGALoader -c cmsisdap --detect
```
检测到 138K Pro SoM：
```text
Found 1 compatible device:
0x0d28 0x0204 ... DAPLink CMSIS-DAP
idcode 0x1081b
manufacturer Gowin
family GW5AST
model GW5AST-138
```

结论：**远端 K1 可达，且 Tang Primer 20K + 138K Pro SoM 均物理连接**。真实板测将使用远端执行。

### 1.3 板卡选择与引脚约定

- 主目标：**Tang Mega 138K Pro SoM**（器件 `GW5AST-LV138FPG676AES`，家族 `GW5AST-138C`）
- 烧录器：**CMSIS-DAP**（`-c cmsisdap`）
- 板载晶振：**50 MHz**
- UART 引脚（DAPLink 虚拟串口）：参考公开 CST 与 RT-Thread 报告
  - `clk` → `P16`
  - `UART2_TXD` → `U16`
  - `UART2_RXD` → `V16`
- `.boardlock` 已创建：`D:/sipeedTANG20K/.boardlock`，归属 `devin_20260927_nano_continued`。

## 2. 138K Pro SoM P&R/时序重评估

使用新增工具 `cores/signal_processing/dsp_isp_library/tools/pnr_audit_138k.py`，目标器件 `GW5AST-138C`，默认 50 MHz，可选 `--freq 27.0` 做兼容性降频。

50 MHz 结果：

| req | case | status | LUT1-4 (DUT) | FF | DSP | BRAM | fmax_min (MHz) | 说明 |
|-----|------|--------|--------------|----|-----|------|----------------|------|
| DSP-14 | stft_ramregs1 | PASS | 14844 | 7887 | 0 | 2 | 62.98 | GW2A 上 5 DSP/布局失败，138C 全逻辑映射通过 |
| ISP-06 | scale_poly6 (MAX_W=1920) | PASS | 15421 | 1010 | 0 | 141 | 64.10 | GW2A 141 BSRAM 超额，138C 141/340 通过 |
| ISP-06 | scale_poly6_w64 (MAX_W=64) | PASS | 15369 | 990 | 0 | 37 | 77.38 | GW2A 54 DSP 超额，138C 全逻辑通过 |
| ISP-10 | integral_b8_32x24 | FAIL_TIMING | 3227 | 1069 | 0 | 19 | 39.76 | 50 MHz 约束违例 |
| ISP-10 | adaptive_threshold | PASS | 1737 | 0 | 0 | 0 | 59.08 | 子模块通过 |
| ISP-11 | histeq_b8_32x24 | FAIL_TIMING | 4402 | 608 | 0 | 5 | 30.11 | 50 MHz 约束违例 |

27 MHz 兼容性降频结果：

| req | case | status | LUT1-4 | FF | BRAM | fmax_min (MHz) |
|-----|------|--------|--------|----|------|----------------|
| ISP-10 | integral_b8_32x24 | PASS | 3227 | 1069 | 19 | 39.76 |
| ISP-11 | histeq_b8_32x24 | PASS | 4402 | 608 | 5 | 30.11 |

- DSP-14、ISP-06 两种配置在 50 MHz 原生时钟下通过。
- ISP-10、ISP-11 在 50 MHz 失败，27 MHz 通过；真板部署时可使用 PLL/分频提供 ≤27 MHz 时钟域，或做流水线重定时。

证据路径（保留原始 50 MHz 失败日志）：
- DSP-14 stft_ramregs1 @ 50 MHz: `cores/signal_processing/dsp_isp_library/dsp/stft/evidence/pnr_gw5a138_20260927_133323_137226/stft_ramregs1/summary.json`
- ISP-06 scale_poly6 MAX_W=1920 @ 50 MHz: `cores/signal_processing/dsp_isp_library/isp/scale/evidence/pnr_gw5a138_20260927_134024_346362/scale_poly6/summary.json`
- ISP-06 scale_poly6_w64 @ 50 MHz: `cores/signal_processing/dsp_isp_library/isp/scale/evidence/pnr_gw5a138_20260927_135001_029780/scale_poly6_w64/summary.json`
- ISP-10 integral_b8_32x24 @ 27 MHz: `cores/signal_processing/dsp_isp_library/isp/localstats/evidence/pnr_gw5a138_20260927_141033_968250/integral_b8_32x24/summary.json`
- ISP-11 histeq_b8_32x24 @ 27 MHz: `cores/signal_processing/dsp_isp_library/isp/histeq/evidence/pnr_gw5a138_20260927_141208_474951/histeq_b8_32x24/summary.json`

## 3. NANO 138K 运输探针结果

目标：先建立 138K 板与宿主 UART 的物理链路，确认 `openFPGALoader -c cmsisdap` 可编程、`/dev/ttyACM0` 可收发，然后再进入算法 harness。

### 3.1 探针构建

- 源：`cores/signal_processing/dsp_isp_library/board/uart_injection_probe.v`，XOR-A5 echo。
- 138K 适配：`uart_injection_probe_138k.v`，`UART CLK_FRE=50`，`P16` 时钟。
- 构建目录与镜像：
  - `artifacts/nano138k_probe_20260927_144656_849354/probe.fs`（CST `P16/U16/V16/N18`）
  - `artifacts/nano138k_probe_litex_20260927_145439_210072/probe.fs`（CST `P16/U15/V14/N18`）
- 本地仿真（iverilog/vvp）PASS；本地 P&R/打包 PASS；`build_summary.json` 与 `probe.fs` 已保留 SHA256。

### 3.2 远端烧录

命令（远端 K1）：
```bash
openFPGALoader -c cmsisdap --write-sram probe.fs
```

结果：
- 成功检测到 DAPLink CMSIS-DAP（`0x0d28 0x0204`）。
- `Load SRAM` 完成到 100%，`program.log` 结尾为 `Done/DONE`。
- 烧录证据：`artifacts/nano138k_probe_20260927_144656_849354/remote/program.log`（U16/V16 镜像）和 `artifacts/nano138k_probe_litex_20260927_145439_210072/remote/program.log`（U15/V14 镜像）。

### 3.3 UART 回读

- 使用 `/dev/ttyACM0`（DAPLink 虚拟串口），115200 baud。
- 发送 768 字节（24 轮 × 32 字节随机包），两轮镜像均收到 0 字节。
- 使用 `sigrok-cli` + fx2lafw 捕获 D0=N18 `dbg_uart`；两轮均未解码出 UART 数据。
- 结论：**运输探针 FAIL**。可能原因：
  - DAPLink CDC/UART 实际连接到 AE350 SoC 的 `UART2`，而非 FPGA  fabric 的 `UART2_TXD/RXD`；
  - 或所引用的 `U16/V16`、`U15/V14` 不是 138K Pro SoM 上 FPGA USB-UART 的真实引脚；
  - 或 138K 板载时钟不在 `P16`（需要确认 50 MHz 振荡器引脚与 apycula 芯片库 pinout 匹配）。

> 没有伪造 PASS。真实 NANO 板可编程，但 UART 链路尚未打通。在确认引脚/时钟/bridge 前，不能对 DSP-14/ISP-06/ISP-10/ISP-11 建立算法 harness。

### 3.4 证据路径

- U16/V16 镜像及远程日志：`artifacts/nano138k_probe_20260927_144656_849354/`
- U15/V14 镜像及远程日志：`artifacts/nano138k_probe_litex_20260927_145439_210072/`
- 两轮 `verdict.json`、`program.log`、`sent.bin`、`serial_received.bin`、`capture.sr`、`decoded.txt` 均保留。

## 4. 当前分类清单

- 已在 NANO 真板验证（含 138K Pro SoM 烧录/UART/LA 原始证据）：无（运输探针编程成功，但 DAPLink/UART 未回显，未满足 PASS）
- 仅 Tang 真板验证：DSP-02, DSP-04, DSP-07, DSP-09, DSP-11, DSP-15, ISP-01, ISP-02, ISP-03, ISP-04, ISP-05, INFRA-02, INFRA-04
- 仅仿真/综合（含 138K P&R 时序证据，未做真板）：DSP-01, DSP-03, DSP-05, DSP-06, DSP-08, DSP-10, DSP-12, DSP-13, DSP-14, DSP-16, ISP-06, ISP-07, ISP-08, ISP-09, ISP-10, ISP-11, ISP-12, ISP-13, ISP-14, ISP-15, ISP-16, ISP-17, ISP-18, ISP-19, INFRA-01, INFRA-03, INFRA-05, INFRA-07
- 仍阻塞（缺少仿真、P&R 或板测证据，或当前硬件/远程不可达）：INFRA-06
