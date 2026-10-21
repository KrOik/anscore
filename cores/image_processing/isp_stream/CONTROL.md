# Runtime-controlled ISP subsystem

`isp_control.v` connects the atomic CSR adapter, seedable virtual RAW source,
full ISP/Sobel pipeline, output monitor, coherent snapshots and registered
probe pages. The atomic config bus stays unchanged during a run; a new commit
may wait until source and pipeline are idle. Acceptance launches exactly one
run. Refer to CONFIG_REGISTERS.md for the16configuration words.

The top reuses unchanged `sys_register_snapshot`, `logic_probe8` and
`buffer_dma_25k/rtl/frame_stream_monitor.v`. Output CRC is CRC32/ISO-HDLC over
accepted grayscale bytes, with no metadata bytes. Monitor and latest RGB stats
clear on each accepted run. A previously captured snapshot remains frozen
until explicit capture,including while new output traffic progresses.

## Additional CSR addresses

| Address | Read | Write |
|---|---|---|
| 0x0c | bit0 snapshot captured | value1 captures32metric words atomically |
| 0x10 | snapshot timestamp low32 | Gamma LUT write:channel[25:24],address[23:16],value[7:0] |
| 0x14 | snapshot timestamp high32 | error |
| 0x18 | snapshot ID | error |
| 0x1c | selector value | bits1:0 probe page,bit8 metric page;other bits zero |
| 0xc0..0xfc |16words from selected snapshot page | error |

LUT writes require idle source,no pending configuration and pipeline LUT ready.
Channel must be0..2 and unused payload bits zero. Writes during a run return an
error rather than a false handshake. Load all768entries before committing
Gamma-enable. Incomplete Gamma produces an explicit failed run. Such errors
invalidate child LUT completeness; reload before another Gamma-enabled run.
Metric reads before the first capture error. Timestamp/ID are resetzero until
capture. Capture ACK is zero; read0x18 separately for the updated ID.

Snapshot word mapping (page0=0..15,page1=16..31):

| Word | Value |
|---|---|
| 0 | bit0 source ready,bit1 done,bit2 error,bit3 config pending |
| 1..5 | completed frames,deadline misses,command stalls,pixel stalls,run cycles |
| 6..10 | accepted output bytes,output frames,cumulative CRC,last-frame CRC,last-frame duration |
| 11 | latest stats frame ID[15:0],overflow bit16,protocol error bit17 |
| 12..13 | latest RGB pixel/line counts |
| 14..19 | RGB48-bit sums,each low32 then upper16 zero extended |
| 20..22 | config version,current source frame ID,full low8 configuration flag byte (including Bayer pattern) |
| 23..31 | reservedzero |

The snapshot is coherent across words,not necessarily at a frame boundary.
For terminal metrics wait for done,then capture. Latest RGB stats describe the
pre-Sobel image and may belong to a completed earlier frame during an active
run. CRC/byte counters include any pixels emitted before a run error.

## Probe pages

Each is registered with one clock of observation latency. Page0 bit0..7:
RAWaccept,out_valid,out_ready,out_SOF,out_EOL,out_EOF,rsp_ready,rsp_valid.
Page1 is offered RAWlow8;page2 offered grayscale byte;page3 bit0..7:
commandaccept,source_ready,source_done,source_error,cfg_valid,cfg_pending,0,0.
Offered data pages must be interpreted with handshake observations.

## Verification and physical top

`test_control.py` evidence `control_20261020T180930042929Z` PASS: CSR-only
configuration and restart,held CSR/output,live-traffic snapshot retention,
two-frame Sobel output and CRC0xfebcb7c1,early incomplete-Gamma rejection,
768CSR LUT writes,one-frame Gamma/center-bypass recovery and CRC0xb6c9cb0b,
27exact output pixels/markers,RGB sums/metrics and all4registered probe pages.
The first integration failure `control_20261020T180809335809Z` is retained:
source waited until after RAW transmission to accept a pre-payload error.
Explicit early error responses now abort the source frame; ordinary stalls
still hold samples. Error response consumption may withdraw the aborted RAW
offer; this is a frame abort,not normal backpressure progress.

`examples/25k/isp_top.v` uses the unchanged UART RX/TX and CSR transport at
50MHz/BIT_CYCLES434,with16-bit power-on reset delay.11pins are clock,RX,TX and
8probes;the CST uses verified25K CH0..7=G5,F5,G8,G7,H7,H8,J5,H5.
UART is supplementary;this is not hard user-JTAG runtime binding.
`test_uart.py` evidence `uart_20261020T181126001154Z` PASS actual bit-serial
RX/TX configuration,run,CRC/snapshot readback,probe selector and invalid access.

Commands after scripts/env.ps1:

```powershell
python cores/image_processing/isp_stream/tools/test_control.py
python cores/image_processing/isp_stream/tools/test_uart.py
python cores/image_processing/isp_stream/tools/build_board.py
```

Board build `board_20261020T181007022100Z` is running in session73270;
inspect terminal synthesis/route/pack results. No download is automatic.
Current physical board remains20K. No25K sustained/physical qualification or
hard runtimeJTAG claim is made. The remaining physical and work-order gates remain open.

## Integrated mode extension and current build provenance

Word4 now accepts bits0..7: BLC bypass,Gamma enable,Sobel center bypass,
Bayer center bypass,2-bit Bayer pattern,AWB bypass,CCM bypass. Metric22
records this complete byte. Upper24 bits remain reserved zero.
All64 stage-mode combinations passed in `all_modes_20261020T183333608166Z`.
Gamma reuses the active table across enabled frames without a new commit.
A partial newly written table rejects enable; a complete replacement commits
atomically. Initial enable still requires all three complete channels.

The older `board_20261020T181007022100Z` has its original30inputs archived in
source_snapshot with a manifest. It does not contain this mode extension.
The extended `board_20261020T183704608918Z` synthesizes/routes from frozen
source_snapshot inputs. The older baseline route/pack passed at63.959064MHz (50MHz constraint),
17114LUT4/16BSRAM. Extended synthesis passed but original heap placement failed. Frozen-netlist
retry board_retry_20261020T184606844008Z also failed legal placement.
No current-image timing result; all failure artifacts retained.
Neither image was downloaded.

Current full-feature LUT4 build board_20261020T184939354706Z route/packPASS:
96.721153MHz,16762LUT4,2636ALU,7261DFF,16BSRAM,11IOB,zeroDSP/PLL.
Archived source/image hashes verified. No image downloaded;physical25K and
harduserJTAG acceptance remainopen. Earlier placementfailures are retained.
