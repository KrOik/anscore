Implemented self-contained 2/3-level Gaussian pyramidal iterative dense LK.
Odd/non-power-of-two ceil pyramid geometry, coarse bilinear*x2 initialization,
current-frame warp, fixed residual iterations and Q4 flow run entirely in RTL.
16 frames / 1932 output pixels PASS exact independent integer oracle;
malformed marker frames produce zero outputs, recovery PASS. Actual fixed
translation(4,2) fixture center median EPE0.0px vs single-scale4.52165px,
actual OpenCV0.000652px; 237/256 central pixels have no invalid flags.
Seven CE0 reset phases +64pixel recovery +11 static parameter rejects PASS.
Narrow MAX_STEP128 / det0 equality / internal SOF-EOL errors and recovery
PASS in a five-frame/192-output-pixel fixture. Prior unified run148.624sec;
new narrow fixture is automatically included, with no extra large rerun.
Unified test entry invokes protocol checks. Standalone synth/CHECK PASS:
2802/2952 LUT1..4,2640/2824ALU,1598/1607FF,4/6RAM,0DSP.
No board, placed timing or side-channel claim. All generated builds temporary.
Commands: python -B cores/system/common_scaffold/image/pyramidal_flow/test_pyramidal_flow.py;
python -B cores/system/common_scaffold/image/pyramidal_flow/synth_pyramidal_flow.py.
Changes confined to this directory; no production or shared runner edits.
