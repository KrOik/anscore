# Frame-configured RGB color chain

`rtl/rgb_color_chain.v` instantiates unchanged canonical img_isp_awb_gain,
img_isp_ccm and img_isp_gamma_lut. It adds a frame command sequencer and bounded
metadata admission FIFO. This is a separate RGB subchain; composition with
raw_rgb_frontend and subsequent Sobel/statistics remains to be verified.

While idle,load the inactive gamma bank using lut_valid/ready,channel0/1/2 or3
(broadcast),ascending addresses0..255 per channel. Then command valid/ready
samples gains(three unsignedQ8.8 values,R/G/B low-to-high),12 signed16-bit matrix
values(row-major9 signedQ6.10 coefficients followed by3 integer biases,low-first),
and gamma enable. No LUT write is accepted simultaneously with a command or
while a frame is active. Enabling gamma without a complete table gives response
error8 without accepting pixels. Canonical sticky LUT/config errors also give8;
reset is required to clear those sticky errors.

The sequencer writes12 coefficients then commits all three stage configurations
before opening input. Each canonical stage applies its pending config on its
own accepted SOF; because only one frame is admitted and the previous EOF has
drained before the next command,this refers to the same frame at every stage.
Changing command pins after acceptance cannot change the pending frame.
Source data waits during configuration. Idle/default behavior does not admit
unconfigured frames; one command is required per frame.

Every accepted RGB888 pixel carries SOF,EOL,EOF and16-bit frame ID. FIFO metadata
is pushed only with actual AWB admission and popped only with actual gamma output
consumption. Its16 entries cover the3+4+1 elastic pipeline stages,and full FIFO
blocks further source acceptance. Metadata FIFO uses logic storage explicitly;
no whole-frame metadata store or packet-commit FIFO is used. Output holds while
ready is low. After accepting input EOF,further source pixels are blocked.

Response follows acceptance of output EOF and stays until ready. Error9 marks
missing/repeated SOF or EOF without EOL;10 marks internal SOF/EOL metadata mismatch.
Caller must discard malformed frame output. The wrapper does not validate width,
height,constant frame ID or an absent EOF; those remain the enclosing frontend's
responsibility. Missing SOF can leave canonical pending configs unconsumed,so
reset is required before resuming malformed framing. Reset aborts control,output
and configuration and invalidates gamma table completeness;reload tables before
enabling gamma. No watchdog is supplied by this subchain.

AWB uses clamp((pixel*gain+128)//256); CCM uses clamp((dot+512)//1024+bias)
with arithmetic floor for negatives; gamma performs the exact loaded byte LUT.
Use gains256 and identity matrix to bypass AWB/CCM numerically with fixed
pipeline structure; gamma enable0 bypasses its mapping with unchanged interface.

Command: `python cores/image_processing/isp_stream/tools/test_color_chain.py` after env.ps1.
Evidence color_20261020T171340367961Z: six frames/384173pixels,including320x240,
640x480,identity and negative off-diagonal matrices,biases,nonunity gains,
saturation,gamma off/on and repeated complete bank loads,all pixel and metadata
bytes checked by an independent Python integer oracle. Initial incomplete-table
enable is rejected before a valid recovery. Command pins change after acceptance,
downstream stalls and source gaps are exercised. An uninterrupted128pixel burst
proves isolated color-chain II1,not fullRAW-chain II1 or sustained board fps.
No synthesis/P&R/resource or physical25K claim for this new subchain yet.

## Gamma table reuse

The wrapper tracks active enable and accepted inactive-bank writes. Consecutive
Gamma-enabled frames reuse a complete active table without asking the canonical
core to recommit an empty inactive bank. A newly written partial replacement
cannot silently reuse the old table: enable returns error8. A complete new table
commits at SOF. An enable transition still commits through the canonical core;
the core itself is unchanged. Staged tables survive commands already off.
`gamma_reuse_20261020T183212405107Z` PASS verifies64 exact pixels across four
frames with a single inversion LUT and rejects a partial replacement.
