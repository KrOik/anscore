# RAW-to-color ISP core

`rtl/isp_stream_core.v` composes raw_rgb_frontend with rgb_color_chain. One
accepted command samples RAW geometry,frame ID,Bayer pattern,manual black levels,
target/bypass,gains,matrix and gamma enable into the corresponding child control
at the same clock edge. No new frame is admitted until final response consumption.
There are no modifications to canonical Bayer/window/AWB/CCM/Gamma kernels.

Load gamma's inactive bank while idle,then submit cmd_valid/cmd_ready. LUT writes
and commands are mutually exclusive through color-chain readiness. During active
processing,LUT loading is blocked. RAW pixels carry native RAW8/10/12,SOF and EOL.
Final RGB888 carries SOF/EOL/EOF and the sampled16-bit frame ID. Output dimensions
remain(W-2,H-2); color processing does not alter geometry. All endpoints use
valid/ready without a separate clock enable. See RAW_CONTRACT.md,FRONTEND.md and
COLOR_CHAIN.md for exact arithmetic and lower-level contracts.

Normal rsp_valid requires both children completed. In particular,the RAW
frontend's completion after last demosaic output admission does not count as
end-to-end completion: the final gamma output EOF must also have been consumed.
Response status/dimensions remain held until ready. Parameters for the next
frame wait until the previous output is drained. The full core's throughput
includes the window's II>=2 cadence and does not inherit isolated color II1.

On a child error,RAW admission and further RAW-to-color admission stop. The
color metadata count drains to zero before an error response is offered,so a
previously presented output is not revoked while ready is low. Caller discards
the erroneous frame's partial output. Consuming the error response resets both
children for one clock and clears all pending configurations. Gamma table
completeness is invalidated by this reset; reload before enabling gamma again.
RAW errors have priority if both children report an error. Invalid dimensions
can terminate without input; incomplete gamma tables can likewise reject a
command. There is no autonomous timeout for a source that stops mid-frame or a
consumer that never resumes; external reset aborts such transfers.

The new color `drained` output means no accepted pixels remain in its metadata
FIFO/elastic chain; it does not mean no configuration is pending. It is used
only to preserve downstream handshakes during fatal-frame drain/recovery.

Run `python cores/image_processing/isp_stream/tools/test_isp.py` after env.ps1. The test
uses independent full RAW matrices,black correction,bilinear interpolation,
gain rounding,signed matrix rounding/bias and gamma LUT equations. It compares
every final RGB/ID/SOF/EOL/EOF byte for RAW8/10/12,seven frames including320x240
and640x480,four Bayer patterns,nonunity gains,negative coefficients,gamma bank
loads/off/on,source gaps,output/response backpressure,changing command pins,
excess input blocked,invalid dimension then3x3 recovery. Finite functional
simulation does not prove sustained30fps or physical25K acceptance.

Still required for IP-03: Sobel/statistics integration and bypass/parameter
coverage across the final selected chain,stream metrics/CSR/probes,resource and
timing reports,realtime virtual-RAW source tests,and25K sustained controlled
capture. Camera input is optional; a complete board-controlled source is not.
No synthesis/P&R/physical resource claim for this combined core yet.

Current isolated GW5A synthesis PASS:core_synth_20261021T012235399,5246LUT1..4+1057ALU+188MUX2_LUT5,2391FF,6SDPX9B+2SPX9 cells,0DSP. No I/O mapping,P&R,Fmax or physical resource claim.
