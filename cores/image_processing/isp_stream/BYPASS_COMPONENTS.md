# ISP bypass components and integrated validation

These components are integrated through isp_control and atomic CSR word4.
The current extended board build uses frozen inputs; the older baseline build
retains its own archived inputs and does not contain this extension.

## Bayer interpolation bypass

`raw_bayer_mode_stream.v` composes unchanged canonical synchronous two-row
window and one-stage Bayer kernel. Both modes preserve(W-2)x(H-2) crop,source
frame ID and all SOF/EOL/EOF. Normal mode uses the Bayer RGB result. Bypass
returns the native center sample shifted to8bits and broadcast toRGB;it does
not invent full-size edge pixels. The center/EOF registers advance with exactly
the same input handshake as the canonical kernel output. The kernel still
runs in bypass mode,so there is no shorter ready/valid path or added row RAM.
Pattern and mode are latched by the frame command. Invalid dimensions produce
error1/no pixels. Malformed framing produces error2 after complete output
drain;the next command can recover. External reset aborts an incomplete frame.

`test_bayer_modes.py` evidence `bayer_modes_20261020T182321831886Z` PASS
RAW8/10/12 each380739pixels with independent Python bilinear/center golden and
all metadata. Covers four normal Bayer patterns,320x240bypass,640x480normal,
3x3boundary,configuration pin changes,source gaps,output/response stalls,
invalid dimensions,malformed EOL then valid recovery.

`test_bayer_latency.py` evidence `bayer_latency_20261020T182450903497Z` PASS:
two actual wrapper instances driven in parallel,one normal and one bypass,
four Bayer patterns/80pixels,shared randomized sink stalls. Input/command
ready,output valid/markers and response timing match on every clock. The test
checks center values and confirms normal/bypass data actually differ.

## AWB and CCM identities

`isp_mode_config.v` selects actual unity AWB gains or identity CCM from the
applied512-bit configuration bank. It retains the original canonical stages
and their pipeline depth. Accepted additional flag locations are word4 bit3
Bayer bypass,bit6 AWB bypass,bit7 CCM bypass;the existing BLC/Gamma/Sobel and
Bayer pattern locations are unchanged. These assignments are accepted by the CSR and propagated through the full chain.

`test_mode_color.py` evidence `mode_color_20261020T183123228744Z` PASS64pixels
through actual rgb_color_chain with all four AWB/CCM mode combinations,
nonunity original gains,negative matrix entries,bias,rounding/clipping,metadata,
backpressure and configuration pins changed after acceptance. Independent
Python arithmetic matches every output byte. Gamma stays off in this test.

Commands after scripts/env.ps1:

```powershell
python cores/image_processing/isp_stream/tools/test_bayer_modes.py
python cores/image_processing/isp_stream/tools/test_bayer_latency.py
python cores/image_processing/isp_stream/tools/test_mode_color.py
```

Full integration evidence `all_modes_20261020T183333608166Z` PASS: all64
BLC/Bayer/AWB/CCM/Gamma/Sobel combinations,64 atomic CSR runs,576 exact output
pixels,independent Python RGB/CRC/metadata/version/flag checks. Nonzero black
levels,nonunity gains,signed CCM and all Bayer patterns are exercised.
`gamma_reuse_20261020T183212405107Z` PASS: four enabled frames reuse one
nonidentity inversion LUT; a partial replacement is explicitly rejected.

Current full-chain regression `isp_sobel_20261020T183426653724Z` PASS:
RAW8/10/12 each377317pixels and7snapshots. Real-time simulation
`realtime_20261020T183426663011Z` PASS:829200pixels,5RGB snapshots,
50MHz/30fps cadence at320x240 and640x480. These are simulation results.
Current-source P&R,50MHz closure and25K physical acceptance remain open.

Full-chain latency evidence `mode_latency_20261020T185105095734Z` PASS: all64
actual CSR modes with no sink stalls and fixed7x7 input. First accepted input
to first accepted output82clocks; final input to final output19clocks;
input/output spans95/32clocks. All576 pixels and markers match the Python oracle.
This proves equivalent pipeline timing in this scenario,not mode-independent
command admission (Gamma may commit),full-chainII1 or physical timing.
Command: python cores/image_processing/isp_stream/tools/test_mode_latency.py
