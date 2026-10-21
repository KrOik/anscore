# Motor25K digital integration binding

`examples/25k/motor_top.v` binds canonical sys_uart RX/TX and canonical
uart_csr_transport to motor_control_csr at50MHz/115200baud,8N1. This is a
controlled digital diagnostic image,not a motor driver connection. Raw
encoder A/B/index are tied0 and external fault is tied inactive; phase samples,
angle and command parameters are CSR supplied. Full encoder/raw-fault pathways
are qualified in core simulation,not in this physical binding. Finite full-clock
replay and mandatory runtime hard-user-JTAG integration remain separate work.

Power-on reset lasts65535 system clocks. Watchdog monitor tick is once per
65536clocks; WMAX64 corresponds to approximately84ms at50MHz,subject to its
arming/count semantics. This slow diagnostic watchdog is not a real-motor
sample-rate specification. No software tool automatically enables the drive.

|LA channel|25K pin|Registered observed signal|
|---|---|---|
|CH0|G5|high gateU|
|CH1|F5|high gateV|
|CH2|G8|high gateW|
|CH3|G7|low gateU|
|CH4|H7|low gateV|
|CH5|H8|low gateW|
|CH6|J5|UARTTX|
|CH7|H5|actual carrier applied-update pulse|

All probe outputs have exactly one system-clock observation delay. They are
not functional power-stage outputs. Narrow applied pulses may require a
sufficient external LA sample rate or future pulse-stretched event page;
a missed pulse at low LA rate is not proof of no update. UART actualTX isC3,
RX B3,clockE2. This25K pinmap is not the current20K T6/P6/... wiring.
No output is driven onto20K using this image.

Offline commands:

```powershell
. ./scripts/env.ps1
python cores/control/motor_foc/tools/test_uart.py
python cores/control/motor_foc/tools/build_board.py
```

UART TB uses BIT_CYCLES8 and tests actual serial framing/CRC,replies,
loadedbuildID,three commands and36goldenresultwords,invalid owned-command
writes,emptyresult reads and ACK. PASS evidence:
`artifacts/motor_foc_25k/uart_20261020T214527771634Z`.
The physical115200baud/board/LA/hardJTAG path remains untested.
Build script freezes sources/tables/CST/script,derives buildID,synthesizes,
routes forGW5A-LV25MG121NES at50MHz and packs only after successful routing.
It never downloads. Behavioral DSP model is simulation-only and excluded.

When a qualifying25K image has been manually loaded,the diagnostic runner is:

```powershell
python cores/control/motor_foc/tools/run_uart.py --port COMx --build-summary <board-artifact>/summary.json --output <new-run-directory> --sample-id 17 --d 80 --q -60
```

This runner requires drive disabled. It validates the PASSbuild,current and
frozen source hashes,derivedfingerprint and suppliedimageSHA before opening
the link. Runtime magic/buildID identifies the loaded configuration;it does
not measure loaded SRAM contents or prove the supplied image is in SRAM.
The capture uses temporary-file flush/fsync and atomic replace before an
optional --ack-after-save. Default preserves the result. It does not enable,
clear,reset,retry or download anything. UARTphysical success would still not
satisfy mandatory hard-user-JTAG/runtime multi-test acceptance or physical
motor/encoder acceptance.

## First routed25K digital image

`board_20261020T214445572169Z` PASS synthesis/placement/route/pack at50MHz.
BuildID b04803d710238e94;motor.fs SHA256
1aaea87d72169756603a2b4c14cee9f5931ac13f5cf53421988563675f59f728.
Final nextpnr report:79.038887MHz,7328LUT4,1850ALU,2563DFF,
14MULT12X12,0BSRAM/PLL,11IOB. The initial packing log shows7823LUT4;
PPA_25K.csv uses authoritative final pnr_report utilization7328.
Core-only synthesis rows count LUT1..4 separately;the routed row uses final
packed LUT4 and leaves synthesis-only LUT1..3 blank. This is a tooling timing
estimate,not measured board frequency or physical shutdown latency.

Host validate_build has checked current and frozen source manifests,derived
fingerprint and actual generated motor.fs SHA. Evidence
host_build_validation.json sits with the build. No image was downloaded;
current20K hardware must not receive this25K image. The generated image lacks
full-clock replay and externalQEI/power-stage inputs and does not satisfy
runtime hard-user-JTAG acceptance. Those limitations remain explicit above.
