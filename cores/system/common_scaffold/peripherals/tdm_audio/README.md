# Single-wire multichannel TDM audio

Two independently synthesizable native-BCLK slave cores, `tdm_audio_rx` and `tdm_audio_tx`. One serial DATA wire carries 2..16 channels per frame. These are new physical multichannel transports: the existing `ips_i2s_*` cores are stereo, `micarry_i2s_slots` receives four parallel stereo wires, and `acc_tdm8_demux` accepts already decoded indexed samples. They remain reusable and unchanged.

## Clock and pin contract

External BCLK is the native clock, not a sampled asynchronous pin. RX samples FS/SD and performs stream handshakes on **posedge BCLK**; TX samples FS, performs stream handshakes and launches SD on **negedge BCLK**. Each reset is synchronous active-low on its own edge and overrides CE. The system must supply a real clock on a clock-capable input and meet setup/hold for FS, SD and host stream signals. When joining these two cores, FS must be stable before the TX falling edge through the subsequent RX rising edge. TX SD is stable from that falling launch through the rising sample edge. Apply actual device input/output and clock constraints; no maximum MHz or physical timing closure is claimed by isolated synthesis.

There is no system-clock/BCLK ratio requirement because there is no system-clock sampler. CDC, asynchronous reset assertion/deassertion conditioning, and any crossing to a system bus are **external responsibilities**. Do not connect unrelated clock-domain ready/valid ports directly. Even opposite BCLK-edge stream logic must satisfy its half-cycle timing path.

CE qualifies only stream acceptance/consumption and `error_clear`. Physical shifting, FS checking, FIFO prefetch and error accounting continue with CE=0. Thus an asserted ready is only an offer; actual transfer requires CE && valid && ready at the specified edge. A stopped BCLK also stops error detection and reset sampling; this is not a wall-clock loss-of-clock watchdog.

## Parameters and wire format

Common parameters: SLOTS=8 (2..16), SLOT_BITS=32 (16/24/32), SAMPLE_BITS=24 (1..SLOT_BITS), FS_POLARITY=1 (0/1), FS_PULSE_BITS=1 (1..FRAME_BITS-1), DELAY_BITS=1 (0/1), FIFO_FRAMES=4 (2..8, including non-powers of two). FRAME_BITS=SLOTS*SLOT_BITS.

An inactive-to-active FS edge starts a frame; consecutive edges must be exactly FRAME_BITS BCLK cycles apart. FS stays active for exactly FS_PULSE_BITS sampled cycles. Slot order is 0..SLOTS-1, each sample MSB first with trailing zero padding on TX. The first slot MSB occurs DELAY_BITS cycles after FS. For DELAY_BITS=1 with SAMPLE_BITS=SLOT_BITS, the old frame's final data bit occurs on the next FS edge, then the next frame starts its MSB one cycle later. Both cores explicitly implement this full-width wrap. RX ignores trailing pad bits; it does not validate their value.

## RX ABI, buffering and recovery

Inputs: bclk,rst_n,ce,fs,sd,error_clear,m_ready. Outputs: m_sample[SAMPLE_BITS-1:0],m_slot[3:0],m_sof,m_last,m_valid, overflow_sticky,framing_sticky and their 32-bit `_count` counters. SOF denotes slot0 and LAST slot SLOTS-1. All sample and marker fields remain stable while a valid output is stalled, including CE=0 and subsequent physical framing errors.

RX captures one complete frame, validates its FS period and pulse width at the following boundary, then commits it atomically. It queues FIFO_FRAMES frames plus one held output frame; the in-progress capture is separate. A full queue drops only the newly completed frame, sets overflow and increments overflow_count; older accepted frames remain intact. Full read+write on the same cycle is accepted at distinct addresses. Physical storage is FIFO_FRAMES+1 entries with logical capacity FIFO_FRAMES, avoiding device-specific same-address RAM collision behavior.

An early/late/missing FS boundary, too-short/too-long pulse or stuck-active FS invalidates the affected capture. The next FS edge rephases capture; only a subsequently complete correctly framed frame is published. An invalid physical frame never withdraws an already published token. There is one-frame boundary validation latency, plus prefetch/output handshakes.

## TX ABI, buffering and recovery

Inputs: bclk,rst_n,ce,fs,error_clear,s_sample[SAMPLE_BITS-1:0],s_slot[3:0],s_sof,s_last,s_valid. Outputs: s_ready,sd, underrun_sticky,input_error_sticky,framing_sticky and corresponding 32-bit `_count` counters. Input must enumerate exactly slots0..SLOTS-1 with SOF/LAST matching endpoints. Marker error discards the partial assembly; a valid new slot0/SOF immediately restarts assembly, otherwise recovery waits for a valid slot0/SOF. A complete queued frame remains unaffected by errors in a later partial frame.

Only complete frames enter the FIFO. Capacity is FIFO_FRAMES queued frames plus one prefetched pending frame and one partial assembly. Input ready conservatively goes low when the logical FIFO is full, even if it is being read that cycle. At FS, the pending complete frame is serialized; if absent, the **whole new frame** is zero-filled and underrun_count increments once. A partial input cannot leak onto the wire. A frame completed on the FS edge is eligible only after FIFO/prefetch latency, not that same boundary. Queue at least several bit clocks before FS when immediate output is required. For delay1, a preceding frame's final wrap bit still belongs to that preceding frame.

Bad external FS timing sets framing error and rephases at the next observed FS edge; it can truncate the prior wire frame because the external frame boundary itself was invalid. Intact queued frames remain atomic and their order is retained. Missing FS beyond FRAME_BITS drives idle zero until reacquisition.

Sticky flags clear only on CE && error_clear. Counters wrap modulo2^32 and clear only on reset. Framing counters count observed error edges (pulse mismatch, invalid boundary or timeout), at most once per edge; one malformed frame may generate more than one observation. Clear coincident with a new error leaves its flag set. Outputs with valid=0 have no semantic value.

## Verification and resources

Run from repository root:

    python -B cores/system/common_scaffold/peripherals/tdm_audio/run_tests.py
    python -B cores/system/common_scaffold/peripherals/tdm_audio/test_protocol.py
    python -B cores/system/common_scaffold/peripherals/tdm_audio/test_limits.py
    python -B cores/system/common_scaffold/peripherals/tdm_audio/test_roundtrip.py
    python -B cores/system/common_scaffold/peripherals/tdm_audio/test_parameters.py
    python -B cores/system/common_scaffold/peripherals/tdm_audio/synth.py

48 main profiles independently generate physical input bits and predict physical TX output bits: slots2/4/8/16, slot widths16/24/32, both polarities and delays, padded/full samples, CE pauses, held output and pointer/collision assertions. Eight long profiles run32frames each, concurrent input refill/output drain, non-power slots/depths, SAMPLE_BITS1/32, FIFO2/8, FS pulse1/FRAME_BITS-1. Protocol checks cover overflow capacity/order, bad FS pulse/early/late/loss/stuck recovery, errors during held output, bad markers/newSOF recovery, partial-input whole-frame zero fill, CE0 error clear and reset. Four actual TX-to-RX wire chains retain independent expected samples and TX-bit checks. Invalid parameters are rejected by explicit initial checks or illegal-width elaboration.

Isolated Gowin synthesis, LUT-class counts include ALU/MUX and4xdistributed RAM: RX default532/max1173/slot24=510; TX default805/max2731/slot24=1001. All0DSP/0BRAM9. No build or bitstream of another project changed; no board test or audio electrical acceptance claimed. Temporary vector/netlist/simulator files use C: TemporaryDirectory and are removed automatically; only small source and evidence logs persist.

Actual pinned Analog Devices RX/TX sources were fetched and inspected for serial bit/channel/frame buffering conventions; URLs, SHA256 and excerpts are in references.json. This is independent code, with an independent multichannel waveform oracle; the stereo reference is not claimed to be an arbitrary-slot TDM golden implementation.
