# Continuous gated external-pin frequency counter

`frequency_counter.sv` counts qualified digital pin edges in consecutive fixed-duration reference-clock windows. It reports an atomic edge count and gate length; the host computes frequency without an RTL divider. This differs from `pulse_measurement`, which timestamps active/inactive intervals between edges and publishes complete-cycle widths. Both are real independent instruments; no existing core is modified.

## Pin sampling and frequency envelope

`clk` is the reference measurement clock. `input_pin` is an asynchronous digital input with two continuously clocked synchronizer registers, both marked ASYNC_REG, followed by a symmetric stable-N filter. FILTER_W=8 by default; a captured cfg_filter of0 or1 accepts the first changed synchronized sample, N>1 requires N consecutive changed synchronized samples. A return to the accepted level resets the candidate count. Input excursions shorter than N sampled clocks are rejected; accepted edges occur after the two-flop latency plus N-1 additional filter clocks relative to the first raw sample. The filter suppresses digital glitches and can merge intervals. It is not an analog input conditioner.

A pin edge close to a clock edge quantizes to one of the adjacent sample instants. Digital simulations cover fractional clock phases on both sides of sampling boundaries; they do not model analog metastability, establish MTBF or prove CDC placement. Apply actual synchronizer/timing constraints and IO voltage/threshold requirements at integration. For unfiltered or N=1 operation, each physical high and low phase must span at least one reference-clock sampling opportunity with setup/hold margin; N>1 needs at least N consecutive samples of each level. For phase-robust use, make each stable level longer than N reference periods, with additional electrical/metastability margin. A nominal50percent signal therefore needs frequency strictly below clk_hz/(2*max(1,N)); other duty cycles are limited by their shorter phase. Faster or narrow pulses can alias or disappear and are not detectable as an automatic error. This sampled-pin counter is deliberately distinct from a fast external-clock-domain Gray-counter frequency meter.

## Descriptor and gate boundaries

All controls and streams use posedge clk. Synchronous active-low rst_n overrides CE. Parameters COUNT_W=32 legal8..48, GATE_W=32 legal8..48, FILTER_W=8 legal1..16. Independent widths support short overflow fixtures and wide production gates. Start transfers only on CE && start_valid && start_ready, capturing:

- cfg_gate_clocks[GATE_W-1:0]: nonzero physical reference-clock periods per gate.
- cfg_filter[FILTER_W-1:0]: qualification threshold above.
- cfg_edge_mode[1:0]:0 rising,1 falling,2 both;3 is invalid.
- cfg_range_enable and cfg_min_edges/cfg_max_edges[COUNT_W-1:0]: inclusive optional edge-count bounds. Enabled min must be <=max; min0 is legal.

Invalid runtime or static parameters return DONE/error1 without measuring. START snapshots the current synchronized pin level; an input already high does not manufacture a rising edge. The acceptance edge is t0. The first measurement edge is t0+1clk; a gate of N clocks includes measurement edges t0+1 through t0+N, then the next gate immediately includes t0+N+1 through t0+2N. A qualified pin transition on a closing boundary belongs to the closing gate, including N=1. There are no drain/reconfiguration bubbles between gates. Boundaries apply to **qualified synchronized transitions**, so physical pin edges near a gate boundary may appear in the adjacent gate according to synchronization, sampling and filtering latency. Live descriptor inputs have no effect after START.

CE gates only host handshakes and abort. Pin synchronization/filtering, gate clocks, edge counters, result generation, queue insertion and drop accounting continue every physical clock while RUN. No tick prescaler is used. A stopped reference clock stops measurement and synchronous reset; this block cannot measure its own reference-clock failure.

## Atomic output and host conversion

The stream transfers on CE && m_valid && m_ready. Fields remain stable while a valid token is stalled, including physical edges, new gates, CE=0 and abort:

- m_edges[COUNT_W-1:0]: selected qualified transitions within that gate, saturating at all-ones.
- m_gate_clocks[GATE_W-1:0]: captured complete gate length.
- m_window_index[31:0]: gate sequence starting0 and incrementing for **every** completed gate, including dropped gates; wraps modulo2^32.
- m_flags[2:0]: bit0 no selected edges, bit1 edge counter overflow, bit2 enabled range violation. Zero flags denotes an ordinary within-range nonempty gate. No-edge is an explicit measurement status rather than a terminal failure. Overflow retains a saturated count; enabled range checking also reports overflow as above the representable maximum.

For rising-only or falling-only periodic signals, frequency_hz=m_edges*clk_hz/m_gate_clocks. For both-edge mode on a periodic signal, divide this transition rate by2 to estimate complete-cycle frequency. Both-edge counts can be odd within a gate. Use the actual reference-clock frequency supplied by the platform; there is no fabricated nominal clk_hz register. Do not convert a saturated overflow token into an exact frequency. A no-edge result describes that gate, not proof that no faster aliased input exists.

## Queue, abort and reset

Two retained FIFO entries bound host buffering. A separate one-cycle event register feeds them and cannot stall. Simultaneous full-FIFO pop and new event keeps both old ordering and the new event. When full without a pop, only the newly arriving window is dropped; drop_sticky sets and drop_count[31:0] saturates. Window index makes gaps observable. A final pipeline event can arrive while the host starts draining, so the total eventually observed after a stalled interval need not be exactly two windows. Exposed tokens are never overwritten. Drop state clears only on reset or a newly accepted START.

CE-qualified abort has priority over measurement on that edge, discards the incomplete gate (even when that edge would otherwise close it), and enters DRAIN with error3. All previously generated/queued/exposed complete results drain before DONE asserts. Thus a stalled host can hold abort completion indefinitely. Abort under CE=0 is ignored. DONE/error hold until CE && done_ready, then a new START is accepted. Reset alone cancels all queues, counters and held tokens immediately on its clock edge. Counter overflow, no-edge and range flags are per-gate and reset automatically for the next gate.

## Verification

From repository root:

    python -B cores/system/common_scaffold/peripherals/frequency_counter/run_tests.py
    python -B cores/system/common_scaffold/peripherals/frequency_counter/test_boundaries.py
    python -B cores/system/common_scaffold/peripherals/frequency_counter/test_protocol.py
    python -B cores/system/common_scaffold/peripherals/frequency_counter/test_parameters.py
    python -B cores/system/common_scaffold/peripherals/frequency_counter/synth.py

The pin oracle uses absolute asynchronous timestamps in picoseconds, independently samples the raw waveform, forms accepted transition timestamps and assigns them to fixed gates. A separate bounded host-queue oracle checks retained indexes, drops, tuples and no overwritten held output. It never forces DUT counters or derives expected results from DUT outputs.

16 main profiles cover3 edge modes, filter0/1/3/8, noninteger periods, inclusive range flags, no edges, CE-off measurement and output stalls. Eleven boundary profiles cover pin phases1/4999/5001/9999ps, explicit closing-boundary transition ownership, continuous gate1 with80consecutive no-drop outputs and a separately stalled run, maximum8bit gate255, actual COUNT_W8 overflow with next-gate recovery,48bit paths and real FILTER_W16 threshold65535. Protocol tests cover captured descriptors, illegal config, held output/oldest queue through abort/CE0, physical drop accounting, maximum48bit gate accepted without premature wrap followed by partial-gate abort, reset with CE=0. Six illegal static width configurations return explicit error1. These are digital simulation and isolated synthesis claims, not board acceptance.

Actual pinned mature LiteX FreqMeter and Raspberry Pi Pico gated PWM-count examples were fetched and inspected for gate/count/time normalization and CDC boundary conventions; URLs, SHA256 and excerpts are in references.json. The LiteX fast external-clock Gray-counter architecture has a different input envelope and is not copied or claimed equivalent. Source implementation and tests are independent. Temporary waveforms, simulators and netlists use cleaned C: TemporaryDirectory paths; only small source, logs and JSON remain.

Isolated Gowin synthesis (`-nodsp; check -assert`) uses341 LUT-class cells at8/8/1 widths,738 at32/32/8, and1006 at48/48/16; all0DSP/0BRAM9. LUT-class includes ALU/MUX and4xdistributed RAM. These are pre-route resource estimates, not physical-clock or board verification.
