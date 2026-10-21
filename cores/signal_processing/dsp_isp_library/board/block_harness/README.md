# External block harness

This wrapper loads real UART input into 64x32 synchronous RAM, replays the
accepted words through the frozen DC or CSC public data interface at 27 MHz,
captures every result in a separate 64x32 synchronous RAM, then exports raw
32-bit results. It never computes a DUT digest or expected value on board.
No physical operation is performed by run.py. Production/board qualification
is pending a successful gated build and parent-controlled fresh capture.

Top `block_harness`, CORE=0 DC, CORE=1 CSC, BITS=8/10 for CSC. Uses existing
T13 UART input, M11 TX, mirrored TX A11 for FX2 D0, H11 27 MHz. UART
115200 8N1, 234 clocks/bit matching the verified existing transport. POR holds
reset for 4096 clocks. Reset/init never clears RAM; counters gate valid reads.

Diagnostic CORE=2 is a true 32-bit identity through the same RAM/replay/capture
path and a one-slot elastic register; config must be zero. Host oracle returns
exactly its input words without masking. This isolates storage/transport from
algorithm arithmetic. `--core identity --build` creates this diagnostic.

`--mem inferred` (MEM_IMPL=0, original candidate) uses inferred synchronous
64x32 RAM. `--mem explicit` (MEM_IMPL=1) uses two 18-bit DPX9B banks per 32-bit
RAM, storing16 payload bits/bank with byte enables11, physical addresses
`{zero[3:0],word[5:0],00,11}` on write and `{zero,word,0000}` on read.
This reproduces the measured `wave2_ip_20k/src/w2_dpram.v` connection pattern;
simulation compiles the existing `imgwin_20k/sim/gowin_bsram_sim.v` registered
DO model. Port resets remain tied off and no simultaneous same-address
read/write occurs between load/replay/drain phases. Explicit candidate status
must still be established by physical comparison, not inferred from this model.

Wire format is byte-oriented, little endian for every multibyte integer:

| Request field | Bytes | Meaning |
|---|---:|---|
| magic | 4 | ASCII BLK1 |
| tag | 4 | fresh host nonce, returned unchanged |
| config | 4 | core configuration below |
| count | 1 | 1..64 words |
| stall | 1 | 0..7: output ready low for this many phases of each 8-cycle replay period |
| words | 4*count | raw input words |

DC config bits 1:0 mode (0 blocker,1 mean,2 baseline), 17:2 pole UQ0.16,
21:18 window log2 0..8; reserved bits must be zero. Input is signed16 low
halfword; upper input bits ignored. Result is `{signed baseline16,residual16}`.
CSC config bits 3:2 mode (0 forward,1 inverse,2 gray), 1 standard (601/709),
0 range (Full/Limited); upper bits must be zero. Input/result are packed
three BITS channels in low 3*BITS bits, first channel highest. Result bit31
captures the core's SOF and bit30 captures its EOL (not regenerated from host
index). Independent oracle checks both markers with every result, including
single-word SOF+EOL and output stalls. Gray occupies
the first channel with other channels zero. Each block is one image row:
SOF on word0 and EOL on final word. Each block resets the core, including
DC history, and submits configuration before replay. State does not carry
between blocks. This is bounded block qualification, not unbounded streaming
or a camera frame format. Sequential blocks need no global reset/reprogram.

| Response field | Bytes | Meaning |
|---|---:|---|
| magic | 4 | ASCII RES1 |
| tag/config | 8 | exact request identity/config |
| count | 1 | number of raw result words |
| flags | 1 | bit0 invalid count/stall; bit1 framing; bit2 unexpected RX while busy; bit3 config; bit4 replay watchdog |
| input_count/output_count | 2 | accepted input and captured output words |
| cycles | 4 | RUN cycles through last captured output inclusive |
| raw results | 4*count | values, not checksum |

Host must wait for the entire response before sending another packet. No
simultaneous load/drain, ping-pong overlap or input flow control is promised.
Busy-RX flag bit2 is sticky until POR. If an unexpected byte arrives after
the flags byte was transmitted, the next response still reports bit2;
starting a new request cannot erase it. Other per-request flags clear on
the next recognized initial B. Consumers must reject nonzero flags.
Serial throughput is much lower than 27 MHz replay; UART wall time must not
be reported as algorithm throughput. For stall=0, valid n-word block replay
uses n+1 clocks with DC/identity and n+4 with production CSC; no intra-block bubbles. Other
stall values are exactly modeled by protocol.verify. Config/load/report time
is excluded from replay cycles. Bounded watchdog is 4096 replay cycles.

Count/stall errors immediately report zero results after the header, without
consuming a payload. Config errors consume the valid-size payload then report
zero results. The host must not submit malformed-sized payloads. UART framing
errors set flags and discard that byte; an incomplete packet can require POR
to resynchronize (no receive timeout). Magic scanning is a simple prefix
recognizer; arbitrary byte-stream resynchronization is not promised. Reset
discards an incomplete packet, all in-flight results and algorithm state.

`protocol.py` provides independent host oracle, request encoder, exact response
verifier including identity/config/flags/counts/cycles and numerical results.
No expected values come from simulation or board output. The verifier rejects
ten byte-corruption positions per simulated block. A physical runner must
archive source/image identity, requests, raw serial/LA captures and verdicts.
UART negative tests additionally cover count0/65, stall8, illegal mode and
reserved config. Separate tb_fault checks truncated payload never launches,
bad stop discard, busy RX after flags transmission retained into the next
packet, and a test-only forced watchdog edge simultaneous with capture.

```
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core dc --build
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core csc --bits 8 --build
python cores/signal_processing/dsp_isp_library/board/block_harness/run.py --core csc --bits 10
```

Each command creates a fresh evidence directory with exact source snapshots,
hashes, externally generated stimulus, real UART bit-level TB, raw response,
independent verdicts and logs. Build uses synth_gowin -noalu, actual LUT/DSP
counts, nextpnr GW2A-LV18PG256C8/I7 at 27 MHz seed1 without timing-ignore,
and pack only after resource/timing gates. No final bitstream means not
authorized for board qualification. Failed directories are preserved.

Isolated algorithm variants use `--dc-source path/to/dc_stream.sv` or
`--csc-source path/to/csc_stream.v`. No production source is replaced. Exact
selected paths and source hashes are archived. `--latency N` explicitly binds
the candidate's globally stalled pipeline latency (1..16) into variant,
simulation and build metadata. Host `protocol.verify(..., latency=N)` checks
its expected replay cycles. Default build latency is4 for canonical CSC and1
for DC/identity; an explicit CSC source requires an explicit latency argument.
Protocol verification default remains1 for every original image; a new
latency may never be used to reinterpret a failing old capture. Only pipelines
with this global-stall contract are supported by this cycle oracle.
