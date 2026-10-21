# Streaming manual RAW black-level stage

`rtl/raw_black_level_stream.v` accepts one native unsigned RAW8/10/12 sample,
16-bit frame ID, SOF(first frame pixel) and EOL(last row pixel) per valid/ready
transfer. Default RAW_BITS=10. Output preserves sample count, coordinates,
frame ID and markers through one elastic output register. No frame/line RAM
or multipliers are used. No clk_en: every transfer is valid && ready.

One configuration handshake loads a pending pattern, four black levels, target
pedestal and bypass. Pattern0..3 means RGGB,GRBG,GBRG,BGGR. Levels low-to-high
are R,Gr,Gb,B. Pending configuration commits at the next accepted input SOF,
including correction of that same SOF pixel. Config ready remains low until
commit. A configuration accepted on the same clock as SOF cannot affect that
pixel and waits for the next SOF. Upstream must queue config ahead of the frame.
Bypass has identical register/handshake latency and passes native sample values.

Correction is clamp(raw - selected_black + target,0,2^RAW_BITS-1). It uses
signed widened arithmetic without rounding. Clip counters increment per accepted
non-bypass sample that underflows/overflows; counters wrap32 and reset to zero.
Default levels/target are zero, bypass disabled,patternRGGB. Output and sidebands
hold under backpressure. Reset aborts queued data and clears active/pending
configuration and coordinate parity; the next accepted frame must begin at SOF.

Coordinates advance only on input acceptance. SOF resets Bayer origin to(0,0),
EOL advances row parity, including single-pixel rows. This stage deliberately
does not infer/validate dimensions or reject malformed frame markers; framing
validation belongs to the pipeline frontend. It does not implement same-frame
optical-black ROI measurement, automatic exposure or analogue-gain tuning.

The existing raw_black_level full-frame module remains unchanged for its own
same-frame-auto use case. This separate streaming path is needed because that
module rejects dimensions above256 and stores/replays whole frames; see
REUSE_AUDIT.md. No whole ISP throughput or board qualification is claimed here.

Run after scripts/env.ps1:
`python cores/image_processing/isp_stream/tools/test_blc.py`

The test independently checks every sample/marker/frame ID and clip total in
RAW8/10/12: each384078pixels across eight frames, all Bayer patterns, odd and
one-pixel widths, bypass,320x240 and640x480 frames, random output stalls and
pending next-frame configuration loaded mid-frame. A separate128pixel continuous
burst measures isolated II=1 and tests reset while output is stalled. Full-size
finite simulation is not320x240@30 or640x480@30 physical continuous acceptance.
Current BLC verification evidence: artifacts/isp_stream_25k/blc_20261020T165939975888Z.
Isolated default RAW10 GW5A synthesis PASS: blc_synth_20261021T010610071,
120 LUT1..4,99 ALU,202 FF,20 MUX2_LUT5,zero DSP/BSRAM. These are synthesis
cells,not physical PPA; no routing/Fmax or board result. The composed RAW-to-RGB
frontend has separate contracts and verification in FRONTEND.md.
