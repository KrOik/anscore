from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'stitch_harness_v2/source/img_mf_dual_frame_store_bram_read.v').read_text()
source=source.replace('reg [31:0] index, x, idle_cycles;', '''// Counters cannot advance beyond the last valid pixel/column/timeout.
    localparam IW=(PIXELS>1&&PIXELS<=65536)?$clog2(PIXELS):1;
    localparam XW=(WIDTH>1&&WIDTH<=65536)?$clog2(WIDTH):1;
    localparam TIME_W=(CAPTURE_TIMEOUT>1)?$clog2(CAPTURE_TIMEOUT):1;
    reg [IW-1:0] index;
    reg [XW-1:0] x;
    reg [TIME_W-1:0] idle_cycles;''')
(HERE/'img_mf_dual_frame_store_bram_read.v').write_text(source)
