# ads131m08_multi_ip — multi-device ADS131M08 front end

Parameterised, device-independent RTL for **1 to 16 ADS131M08** 8-channel 24-bit
delta-sigma ADCs, with an AXI4-Lite control port and an AXI4-Stream sample port.
Targeted at the Sipeed **Tang Primer 25K** (GW5A-LV25MG121) and build-checked for
the **Tang Primer 20K** (GW2A-18). The 20K single-device route evidence uses the
scalar bring-up wrapper; the 25K constraint file remains a reference-only
template without physical-board verification.

Run `scripts\harness.ps1 docs` to audit documented paths, register offsets,
OSS source lists and the reference-only constraint declaration before packaging.
Run `scripts\harness.ps1 fifo-inference` to record isolated Gowin memory
mapping evidence; a `DEFERRED` result is retained until portable BRAM behavior
is demonstrated across the required vendor flows.
Use `scripts\harness.ps1 sim -Full -Quiet` for a bounded, low-noise full
regression. `scripts\harness.ps1 faults` verifies that a deliberately broken
RTL fixture is rejected by the compiler and never changes checked-in sources.
Use `scripts\harness.ps1 package` to build a `candidate-only` zip containing
the allowlisted source, documentation, formal inputs and generated JSON
evidence, together with a SHA256 file.

## 1. Read this first: there is no daisy chain

ADS131M08 has **no DAISY_IN / DAISY_OUT pin**. TI SBAS950B lists all 32 pins and
none of them is a chain port; a full-text search of the datasheet for "daisy"
returns nothing.

So several parts cannot be cascaded into one shift register. They share
**SCLK / DIN / DOUT** and are selected by an **individual CS** each, which is the
only topology the silicon supports. Only the addressed part drives DOUT; every
other part tri-states it while its CS is high (datasheet `tw(CSDOZ)`).

```
             +-----------+   +-----------+        +------------+
 FPGA  SCLK -+-> SCLK    |   |    SCLK <-+-- ... -+-> SCLK     |
       DIN  -+-> DIN     |   |     DIN <-+-- ... -+-> DIN      |
       DOUT <-+-- DOUT   |   |    DOUT --+-- ... -+-- DOUT     |
             |           |   |           |        |            |
   CS[0] ----+-> CS      |   |           |        |            |
   CS[1] --------------------+-> CS      |        |            |
   ...                                 ...                     |
   CS[15] -----------------------------------------+-> CS       |
  DRDY[0] <--+-- DRDY    |   |           |        |            |
  ...        |           |   |           |        |            |
  SYNC[0] ---+-> SYNC    |   |           |        |            |
             +-----------+   +-----------+        +------------+
```

## 2. Files

```
rtl/
  ads131m08_spi_engine.v     bit/byte PHY (SPI mode 1, symmetric SCLK)
  ads131m08_scheduler.v      one protocol FSM + device sequencer, 1..16 parts
  ads131m08_axi_lite.v       minimal AXI4-Lite slave -> plain register bus
  ads131m08_sample_fifo.v    synchronous sample FIFO, explicit overflow
  ads131m08_regfile.v        register state, control pulses and sticky status
  ads131m08_stream_adapter.v FIFO and AXI-Stream output slot
  ads131m08_multi_ip.v       top level: AXI, scheduler and narrow blocks
sim/
  ads131m08_device_model.v   behavioural part, one instance per device
  ads131m08_timing_check.vh  TI section 6.6 timing monitor, reusable
  tb_ads131m08_multi_ip.v    N devices, bus exclusivity, scheduling
  tb_ads131m08_axi.v         registers, stream, back-pressure, overflow
src/
  ads131m08_pads_top.v       parameterised 25K pad-level wrapper
  ads131m08_pads_top_20k.v   scalar 20K single-device bring-up wrapper
constr/
  tang25k_ads131m08_16.cst   GW5A-25A, N = 16 (template, see the header)
  tang20k_ads131m08_ip.cst   GW2A-18, N = 1 (route-checked pin names)
```

## Pad-wrapper observable contract

The pad wrappers keep AXI4-Lite idle because they are route vehicles rather
than host-controlled application tops. Their `led` outputs are wired only to
real IP outputs:

* `ads131m08_pads_top_20k`: `led = m_axis_tvalid`, meaning that a sample beat
  is waiting in the output slot.
* `ads131m08_pads_top`: `led = m_axis_tvalid | irq`, meaning that a sample beat
  or an enabled interrupt is pending.

LED low is not an initialization-health indication. A board-level bring-up
design must connect AXI control and expose status registers if it needs to
start initialization or diagnose the scheduler.

## 3. Using it

```verilog
ads131m08_multi_ip #(
    .ADC_COUNT (4),              // 1..16
    .CLK_HZ    (50_000_000),     // 50 MHz on the 25K, 27 MHz on the 20K
    .SCK_DIV   (1),              // fSCLK = CLK_HZ / (2*(SCK_DIV+1)) = 12.5 MHz
    .OSR_SEL   (2)               // OSR 512 -> 8 kSPS per part
) u_adc (
    .clk (clk), .rst_n (rst_n),
    .adc_sclk (adc_sclk), .adc_din (adc_din), .adc_dout (adc_dout),
    .adc_cs_n   (adc_cs_n),      // [ADC_COUNT-1:0]
    .adc_sync_n (adc_sync_n),
    .adc_drdy_n (adc_drdy_n),
    .s_axi_*    (...),           // AXI4-Lite slave
    .m_axis_tdata (m_axis_tdata), .m_axis_tuser (m_axis_tuser),
    .m_axis_tvalid (m_axis_tvalid), .m_axis_tlast (m_axis_tlast),
    .m_axis_tready (m_axis_tready),
    .irq (irq)
);
```

At power-up the IP runs `/SYNC` low, releases it, then walks every enabled
device once through `UNLOCK -> WAKEUP -> RREG ID -> 4 x WREG -> RREG CLOCK
read-back`. It then samples continuously. Nothing has to be poked to get data.

### Data format

One AXI4-Stream beat is one conversion frame of one device:

| Field | Bits | Meaning |
|---|---|---|
| `tdata[255:212]` | 44 | zero |
| `tdata[211:208]` | 4 | device index |
| `tdata[207:192]` | 16 | STATUS word |
| `tdata[191:0]` | 192 | CH7..CH0, 24-bit two's complement |
| `tuser[15]` | 1 | DRDY timeout on this device |
| `tuser[14]` | 1 | CLOCK read-back matched |
| `tuser[13]` | 1 | ID matched |
| `tuser[12]` | 1 | zero |
| `tuser[11:8]` | 4 | device index |
| `tuser[7:0]` | 8 | free-running frame counter |

`tlast` is high on every beat (one beat is one complete packet).

## 4. Register map

32-bit, single beat, no bursts. Unmapped reads return `0xDEADBEEF` and set the
sticky error bit `ERR[18]`.

| Offset | Name | Notes |
|---|---|---|
| `0x000` | CTRL | W0 soft reset, W1 start init, W2 enable (level), W3 clear errors, W4 clear FIFO, W5 resync |
| `0x004` | STATUS | [3:0] ADC_COUNT, [4] spi_busy, [5] all_init_done, [6] all_id_ok, [7] all_cfg_ok, [11:8] current device |
| `0x008` | SCHED | [0] 0 = round robin, 1 = DRDY priority; [31:16] enable mask |
| `0x00C` | ERR | [15:0] per-device error, [16] FIFO overflow, [17] DRDY timeout, [18] unmapped access |
| `0x010` | IRQ_EN | per-bit enables for ERR |
| `0x014` | IRQ_STATUS | W1C |
| `0x018` | CFG0 | [2:0] OSR select, [4:3] power mode |
| `0x01C` | CFG1 | [15:0] expected ID register (default `0x0801`) |
| `0x020+4n` | DEV_CTRL[n] | [0] enable, [1] resync pulse |
| `0x060+4n` | DEV_STATUS[n] | [0] init_done, [1] id_ok, [2] cfg_ok, [3] drdy_seen, [4] timeout, [5] drdy_n live, [31:16] last STATUS |
| `0x100+4n` | DEV_ID[n] | [15:0] ID read back |
| `0x140+4n` | DEV_SAMPLES[n] | frame counter |
| `0x180` / `0x184` / `0x188` | GAIN1 / GAIN2 / MODE | raw register values |
| `0x200` | FIFO_DATA | low 32 bits of the most recently popped beat |
| `0x204` | FIFO_STATUS | [15:0] level, [16] full, [17] empty |
| `0x208` | DROP_COUNT | frames dropped because the FIFO was full |

## 5. Bus bandwidth: read this before picking a sample rate

One frame is 9 words x 24 bits = 216 SCLK cycles, and 16 parts share one bus, so
16 frames need 3456 SCLK cycles. At 50 MHz with `SCK_DIV = 1` the SCLK is
12.5 MHz, giving 17.3 us per frame:

| Devices | 8 kSPS (125 us) | 4 kSPS (246 us) | 2 kSPS (492 us) |
|---|---|---|---|
| 1 | 14 % | ok | ok |
| 4 | 55 % | ok | ok |
| 8 | **110 %** | 56 % | ok |
| 16 | **221 %** | **112 %** | 56 % |

**16 parts on one bus require OSR >= 2048 (2 kSPS).** Percentages are bus
utilisation. More bandwidth needs more SPI buses, not a bigger FIFO.

Two consequences the IP already handles:

* `SCLK` is symmetric (`fSCLK = CLK_HZ/(2*(SCK_DIV+1))`), which is 1.5x faster
  than the original 3-phase engine at identical datasheet margins;
* DRDY stays low until the frame is read, so on an overloaded bus **every**
  device is ready almost all the time. A plain "lowest ready index" scheduler
  would starve devices 1..N-1 forever; this one resumes its search *after* the
  device it just served and only wraps when nothing above it is ready.

## 6. Build and test

```powershell
# simulation: N = 1, 2, 4, 16 plus the AXI/stream suite and the original
# single-device regressions, which now share the extracted PHY
.\scripts\test_ads131m08_ip_sim.ps1

# synthesis, resource report and (with -Route) place and route
.\scripts\build_ads131m08_ip_with_oss.ps1 -Board tang25k -AdcCount 16 -Route
.\scripts\build_ads131m08_ip_with_oss.ps1 -Board tang20k -AdcCount 1
```

Measured synthesis results (yosys `stat`, top = `ads131m08_multi_ip`):

| Target | N | LUT4 | DFF |
|---|---|---|---|
| GW5A-25A | 1 | 434 | 1264 |
| GW5A-25A | 2 | 495 | 1323 |
| GW5A-25A | 4 | 601 | 1439 |
| GW5A-25A | 8 | 693 | 1669 |
| GW5A-25A | 16 | 997 | 2127 |
| GW2A-18 | 1 | 458 | 1169 |

16 devices cost only 2.3x the logic of one: the SPI engine, the protocol FSM and
the scheduler are shared, and only per-device status is replicated.

Full place and route for GW5A-25A at N = 16 (`-Route`): LUT4 1157/23040 (5 %),
DFF 670/23040 (2 %), **Fmax 195.9 MHz against a 50 MHz constraint**, and a
5.96 MB `.fs`. `ads131m08_pads_top` is the PnR top; it drives the AXI ports from
constants, so yosys prunes the FIFO memory in that particular run and the DFF
count is not representative. Use the `stat` table above for sizing.

## 7. Tang Primer 25K specifics

Two things bite, both verified here, and both are already in the build script:

* nextpnr needs the **full part number**. `--device GW5A-25A` fails with
  `No package for partnumber GW5A-25A`; use `GW5A-LV25MG121NES`.
* GW5A-25A forces SSPI-as-GPIO. nextpnr and `gowin_pack` must agree or
  `gowin_pack` aborts with `sspi_as_gpio has conflicting settings in nexpnr`,
  so pass `--vopt sspi_as_gpio` to nextpnr **and** `--sspi_as_gpio` to
  `gowin_pack`.

The 25K Dock clock is **E2 at 50 MHz** (not 27 MHz) and reset is H11.

## 8. What is not done

* **No Tang Primer 25K hardware verification.** No 25K board was available. The
  design synthesises and places and routes for GW5A-25A and the constraint file
  is derived from the official breakout table, but nothing has been programmed
  or measured on that board. `constr/tang25k_ads131m08_16.cst` is a template.
* **Only one ADS131M08 module is physically available.** N = 1 is the hardware
  verify vehicle on the 20K; N = 2/4/16 are simulation and synthesis only.
* Multi-bus operation (more than one SPI controller for extra bandwidth) is not
  implemented; the scheduler assumes a single shared bus.
* No clock-domain crossing wrapper: the IP is single-clock by design.
* No PLL; the SPI engine runs directly off the board clock.
* The isolated FIFO probe maps the synchronous storage to eight Gowin block
  memory primitives for both GW2A and GW5A at depths 64 and 512. Evidence for
  other vendor inference tools remains a separate H-007 task.
* The Tang 20K hardware top that instantiates this IP alongside the LCD is
  `src/top_adc_ip.v` in `spi_lcd_e203_20k` (build `-Top adcip`, sim
  `tb_top_adc_ip`); `-Top adc`/`adcuart` still use the original single-device
  driver, which shares `ads131m08_spi_engine.v`. Board-level verification of
  the new top remains `DEFERRED` with the rest of the hardware gate.
