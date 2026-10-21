# Host-controlled complete inference

`cnn_host.py` provides abstract-bus helpers for validated loading and readback.
`run_uart.py` reuses the buffer_dma UartCsr codec unchanged. It does not program
the FPGA. A supplied successful50MHz25K build must match the packed-image hash
and current source hashes. The build fingerprint is recomputed from that
manifest and compared with CSR30/34 before loading and after result readback.
This verifies a configuration identifier,not the exact loaded bitstream hash
or a cryptographic hardware identity. UART ID cannot identify the FPGA device.

The runner validates exported model/input hashes before opening serial,loads
weights/biases once,and runs all exported input cases. It reads every layer
element,checks numerical equality to the integer model,and verifies completion,
count,cycles and fingerprint stayed unchanged. Failed/uncertain runs are not
automatically restarted or acknowledged. Partial readback is saved periodically;
UART exchanges and terminal reports are retained on failure. Nominal compute
latency/rate uses run_cycles/50MHz,excludes host loading/readback,and is separate
from wall-clock end-to-end throughput. It does not infer actual oscillator rate.

```powershell
python cores/acceleration/cnn_infer_25k/tools/export_model.py --output artifacts/cnn_fixture_new
python cores/acceleration/cnn_infer_25k/tools/run_uart.py --port COMx --build-summary artifacts/cnn_infer_25k/board_20261020T190955731593Z/summary.json --fixture artifacts/cnn_fixture_new --output artifacts/cnn_uart_new
```

The current board image has11pins and no automatic flash programming. Confirm
the connected device is the25K before using it; the currently recorded physical
board is20K. Hard-user-JTAG/LA work-order acceptance remains separate and open.

`test_host.py` evidence `host_20261020T191325051805Z` PASS:3runs/31791retained
actual CSR RTL words,one weights/bias load,fragmented serial codec,wrong loaded
fingerprint before any loading,corrupted numerical readback,incomplete capture,
completion timeout and no ACK/retry after failure. Cycles and payloads derive
from `control_20261020T190709765497Z`;this is a software fixture,not a board run.
`run_uart.py --help` PASS. No physical serial execution has occurred.

Board build `board_20261020T190955731593Z` route/packPASS:71.75145MHz vs50MHz,
2839LUT4,1138ALU,1090DFF,30BSRAM,163MUX2_LUT5,11IOB,zeroDSP/PLL.
Fingerprint7b07213c07e31a2f; packed SHA256
8152f7b03c00fcc50049bb1e9ff4e82365ca187cc9605f44707db7c765e31609.
Source/snapshot/image hashes and host build validator PASS. Not downloaded.
Earlier board_20261020T190825980172Z failed because RAM16SDP4 has no target
BEL;that failure is preserved. The successful build uses -nolutram.

Bit-serial integration `uart_20261020T191404769960Z` PASS:all model parameters
and input loaded through UART,the full network runs,then10scores+Top3 match
Python. UART uses8clock bits in simulation;this is not physical115200baud.
Command: python cores/acceleration/cnn_infer_25k/tools/test_uart.py
Board-netlist narrow RAM audit `ram_audit_board_20261020_initial` also PASS.
