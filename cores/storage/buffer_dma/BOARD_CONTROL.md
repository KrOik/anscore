# 25K narrow board/control wrapper

`examples/25k/buffer_dma_top.v` has clk, uart_rx, uart_tx and eight probe outputs
(11 pins total). At 50MHz, BIT_CYCLES=434 gives approximately115200 baud,8N1.
The 16-bit power-on counter releases reset after65535 clocks. The test does not
start automatically: write the control register. Canonical sys_uart and existing
uart_csr_transport are reused unchanged. This supplementary UART path does not
implement hard runtime JTAG, and does not close that mandatory work-order gate.

The CST targets GW5A-LV25MG121NES: E2 clock, B3 UART RX, C3 UART TX;
probe0..7=G5,F5,G8,G7,H7,H8,J5,H5 (the calibrated25K mapping). It must not be used
for the currently connected20K or its different probe mapping.

`rtl/buffer_dma_control.v` routes addresses below E0 to snapshot CSR and E0..FC
to control/status. One request is outstanding. The response route and data stay
fixed until consumption, even if address inputs change. Requests wait during
the one-clock selftest clear. Writes require full strobes and alignment; invalid
commands return error/zero. Read strobes are ignored.

| Address | Access | Meaning |
|---|---|---|
| E0 | R/W | Read bits0 ready,1 done,2 error; write exactly1 starts/restarts |
| E4 | R/W | Seed, default512A309B |
| E8 | R/W | Stall mode, exactly0 or1, default1 |
| EC | R | Frames per source, default32 (build parameter) |
| F0 | R | Checked output words |
| F4 | R | Bad accepted words |
| F8 | R | Run cycles |
| FC | R | Interface identifier42444631 (BDF1), not a build hash |

Start,seed,stall-mode writes are accepted only while ready. A start clears all
buffer/snapshot/monitor state and begins a new reset epoch. Completion is sticky.
Check errors need not be nonzero on timeout; the error status is authoritative.
For default32frames, expect544checkedwords,64published/released and zero errors.
Capture the snapshot by writing1 to00, then read timestamp,ID and51metrics per
csr_map.md. Confirm unchangedID after reading. The build evidence hashes, not
the fixed interface identifier, identify the exact RTL and bitstream.

UART commands are8bytes: A5,op(0read/1write),address,data32little-endian,CRC8.
CRC8 polynomial07,initial0 covers the first7bytes. Reply:5A,error,address,
data32little-endian,CRC8 over first7bytes. One command/reply at a time.

Simulation: `python cores/storage/buffer_dma/tools/test_control.py`.
Evidence control_20261020T164916960321Z: direct CSR tests cover config guards,
stalled response route,run/restart and snapshot invalidation. Full bit-serial
board-top test covers POR,UART RX/TX,CRC command/reply,seed readback,selftest,
snapshot publication/release and rejected RO writes. BIT_CYCLES=8 and4frames
accelerate simulation; default board settings remain434 and32frames.

Build: `python cores/storage/buffer_dma/tools/build_board.py` after env.ps1.
It saves source/CST hashes,synthesis,route/physical timing report and packed
bitstream. It does not download hardware. Inspect the resulting summary/logs;
successful synthesis alone does not imply route,timing or board acceptance.

Physical UART host command (requires pyserial and the correct25K image already
loaded; this command does not program a board):

```powershell
python cores/storage/buffer_dma/tools/run_uart.py --port COMx --clock-hz 50000000 --output artifacts/buffer_dma_25k/physical_run_unique
```

The tool verifies interfaceID,sets seed/mode,starts,polls completion,checks
word/error totals,captures all51metrics with ID bracketing and saves raw UART
exchanges,snapshot,decoded report and final status. It compares input CRCs to
host-generated pattern golden and all stream byte/frame counts. Output data
is checked by the hardware checker; output CRCs are recorded but not compared
to an independently measured per-frame output order by this host command.
The clock frequency is supplied from the known bitstream build,not detected
from UART. A PASS from this tool covers one controlled finite run only; it
does not prove sustained throughput,LA timing or hard-JTAG runtime behavior.
Hardware-free host framing checks: `python cores/storage/buffer_dma/tools/test_uart_codec.py`.
This tool has not yet run against physical hardware in the current work step.

Current route/pack candidate: artifacts/buffer_dma_25k/board_20261020T171548136931Z.
Final source/CST/image binding revalidated PASS;50MHz timing passes at56.68MHz.
Final routed report:9306LUT4,5798DFF,10BSRAM,11IOB,zeroDSP. See ppa.json for ALU
and wide-mux counts. This is ready for physical25K controlled testing,not itself
board acceptance. Current hardware was last confirmed20K;identify before download.
