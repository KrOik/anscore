# BLC to Bayer RGB frontend

`rtl/raw_rgb_frontend.v` composes the new streaming manual BLC with unchanged
canonical img_bayer_window_frontend_draft, img_window3x3_valid_draft and
img_isp_bayer_interpolate. The complete source list and hashes are emitted by
tools/test_frontend.py. No copied/renamed kernel is used as a separate asset.

Accept a frame command cfg_valid/cfg_ready before RAW pixels. Width,height,
frame ID,Bayer pattern,black levels,target and bypass are sampled atomically;
later changes to command pins cannot change that frame. One frame is in flight.
Dimensions require width>=3,height>=3,width<=MAX_WIDTH(default640). Invalid
dimensions return bounded rsp_error1 with zero output dimensions,consume no
payload,and flush the pending BLC config when response is accepted. Supported
RAW_BITS=8/10/12. Other parameter values are unsupported.

Each input transfer carries native RAW,s_sof and s_eol. Valid/ready applies every
clock; no independent CE exists at the wrapper boundary. After width*height
accepted input samples,source ready remains low until the response and next
command. This blocks extra payload from spilling into the next frame. The
canonical window frontend checks marker consistency and provides its existing
error code; the wrapper flushes BLC on response acceptance to recover queued
state. A malformed frame's partial output must be discarded by the caller.

The output is RGB888 with stable per-frame ID and SOF/EOL/EOF under backpressure.
Exactly one pixel is cropped from each edge,so output dimensions are(W-2,H-2).
Output Bayer phase uses the original center coordinate,not cropped coordinate0.
Interpolation averages round using +1/2 or+2/4 in native RAW precision; channels
then truncate low RAW_BITS-8 bits to8bits. See the independent integer oracle
for the full equations. BLC bypass affects black correction only,not demosaic.

rsp_valid/error/dimensions hold until rsp_ready. Successful response occurs only
after all RGB output has been accepted. The next command waits through one BLC
flush cycle. Reset aborts frame/output/config state; output dimensions/ID from an
aborted frame have no validity. Upstream must restart at a new frame command.

The window core's inspected architecture uses an issue/processing cadence II>=2.
The BLC's isolated II1 does not imply whole-frontend II1. Current tests do not
measure a sustained frame rate or physical Fmax. No AWB/CCM/Gamma/Sobel/statistics
chain or25K board acceptance is claimed yet.

Verification: `python cores/image_processing/isp_stream/tools/test_frontend.py` after env.ps1.
RAW8/10/12 each checks380685output pixels across seven frames,including320x240
and640x480 inputs,four Bayer patterns,exact RGB/ID/SOF/EOL/EOF,random downstream
stalls,input gaps,command-field changes after acceptance,extra payload blocked,
response backpressure,invalid dimensions followed by valid3x3 recovery. Python
builds corrected RAW matrices and bilinear RGB independently from RTL control.
No synthesis or resource measurement performed for the composed frontend yet.
