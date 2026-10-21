# IP-06 four-channel digital lock-in (development)

Target Primer25K/GW5A-25,50MHz. No physical measurement or analog ADC validation
is claimed. `lockin4.v` reuses unchanged dsp_20k dds_nco twice (sine/cosine ROMs)
and one unchanged16-stage cordic for all four outputs. It adds atomic command,
four simultaneous sample lanes,manual calibration,quadrature products,
48-bit boxcar integrators,power-of-two decimation and timestamp alarms.
The existing FIR/CIC/FFT are not required in this selected boxcar subchain.
Repository reuse is not a distribution-license grant;licensing remains open.

Commands latch32-bit phase step,nominal timestamp period,run ID,log2 integration
length4..12 (16..4096samples),four signed16 offsets and unsigned Q1.15 gains.
Each command restarts the DDS phase at0. A common ready/valid beat carries
four signed16 samples and four64-bit timestamps (lane0 in the low slices).
The DDS advances once per accepted vector. Registered LUT outputs correspond
to the phase before that advance;mixing occurs in the following clock.
Thus this implementation accepts at most one vector per two core clocks.
Backpressure pauses sample/reference progress;this is not an unbuffered ADC
full-rate interface. A real ADC source would need a separately qualified FIFO.

Calibration: corrected=clamp16(((sample-offset)*unsigned_gain)>>>15).
I=sum(corrected*cosQ15) >>> (15+log2N),
Q=-sum(corrected*sinQ15) >>> (15+log2N). For x=A*cos(reference+phi),
I≈A*cos(phi)/2,Q≈A*sin(phi)/2. Negative shifts use arithmetic floor.
Amplitude approximates2*sqrt(I²+Q²);phase is atan2(Q,I),signed radians*2^14.
Low-level I/Q vectors are normalized upward before CORDIC (max component at
least4096);amplitude is scaled back afterward. Zero I/Q returns zero amplitude
and phase explicitly. DDS lookup is256samples signedQ1.15.

Output packs four signed16 I,Q,four unsigned16 amplitude,four signed18 phases,
first/last lane0 sample timestamps,run ID and sticky error bits. All hold while
m_valid&&!m_ready. Next command waits until completion acceptance. Error-tagged
measurements must not be accepted as valid lock-in results:

| Bit | Cause |
|---|---|
| 0 | timestamps differ among lanes on an accepted vector |
| 1 | successive lane0 timestamps differ from commanded period (modulo64bits) |
| 2 | calibration clipped |
| 3 | CORDIC magnitude reached its output limit |
| 4 | invalid integration length or zero period;no samples consumed |

Timestamp values are supplied with the samples;this module does not prove their
relation to wall-clock time. Future virtual-source/board binding must generate
them from the actual common sample event and preserve external LA evidence.

```powershell
python cores/signal_processing/lockin/tools/test_lockin.py
python cores/signal_processing/lockin/tools/synth.py
```

Current test `lockin_20261020T191949590621Z` PASS:three coherent frequencies
(1,3,7cycles/256samples),four channels/12amplitude-phase combinations,amplitudes
64..28000,all quadrants,exact I/Q and first/last timestamps,source gaps,held
outputs,changed config pins,offset calibration,clipping,desync/cadence flags,
invalid command,mid-run reset and clean recovery. error_table.csv and JSON
contain simulation-derived errors,not physical measurements. Predeclared limits
are12counts amplitude and0.06rad phase;these are bounded by tested cases only.

Initial harness path/held-width failure and pre-normalization low-amplitude
failure are retained. CORDIC normalization fixed the arithmetic limitation;
no error threshold was relaxed. Shared DDS/CORDIC source hashes are recorded.
Isolated synthesis is pending in synth_20261020T192050098558Z. The first synthesis
attempt failed because the unused default DDS LUT filename was elaborated;
the current flow defers elaboration and uses the explicit frozen ROM paths.

Remaining: full-rate virtual ADC/reference integration and timestamp generation,
CSR parameter switching/readback,board P&R/resources/Fmax,hard-user-JTAG binding,
physical4-channel known-signal/error tables and associated LA capture.

Clock-scheduled4channel virtualsource and commonclock timestamp integration
now pass;see VIRTUAL_ADC.md. Replaycontroller overflowabort/CSR/board/physical
gates remainopen. Frozenisolatedcore synthesis37299 remainslive.
