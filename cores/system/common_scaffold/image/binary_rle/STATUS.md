Only image/binary_rle/ changed; no shared/production/JTAG edits.
python -B test_binary_rle.py: PASS seven profiles/63 frames/631845 real RTL
loopback pixels/115196 exact tokens;13 malformed cases plus13 recovery frames
(216 valid prefix/recovery pixels), eight invalid static cases.
python -B synth_binary_rle.py: PASS both modules at32x32 and65535x65535,
all CHECK clean. Encoder59/150 LUT,22/64 ALU,44/120 FF; decoder86/193 LUT,
23/97 ALU,38/93 FF. All zero RAM/DSP. No board/timing claim; temp products cleaned.
