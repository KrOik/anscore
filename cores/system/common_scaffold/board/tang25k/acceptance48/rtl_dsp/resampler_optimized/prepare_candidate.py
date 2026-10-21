"""Create an isolated exact-arithmetic pipeline; never edits production RTL."""
from pathlib import Path
HERE = Path(__file__).resolve().parent
COMMON = HERE.parents[4]
source = (COMMON/'dsp/rtl/cip_dsp_resampler.v').read_text()
source = source.replace('MAC=2, OUTPUT=3;', 'MAC=2, OUTPUT=3, ACCUMULATE=4, QUANTIZE=5;')
source = source.replace('reg [1:0] state;', 'reg [2:0] state;')
source = source.replace('wire signed [ACC_W-1:0] total=acc+product;',
    'reg signed [DATA_W+COEFF_W-1:0] product_q;\nwire signed [ACC_W-1:0] total=acc+product_q;')
source = source.replace('wire signed [ACC_W-1:0] scaled=total>>>SHIFT;',
    'wire signed [ACC_W-1:0] scaled=acc>>>SHIFT;')
source = source.replace('acc<=0;m_data<=0;', 'acc<=0;product_q<=0;m_data<=0;')
source = source.replace('integer phase,tap,remaining,k;', '''localparam integer PHASE_W=$clog2(UP+DOWN+1)>0?$clog2(UP+DOWN+1):1;
localparam integer TAP_W=$clog2(HISTORY)>0?$clog2(HISTORY):1;
localparam integer REMAIN_W=$clog2(TAPS+1)>0?$clog2(TAPS+1):1;
reg [PHASE_W-1:0] phase;
reg [TAP_W-1:0] tap;
reg [REMAIN_W-1:0] remaining;
integer k;''')
source = source.replace('wire [31:0] address=phase+tap*UP;',
    'localparam integer ADDR_W=$clog2(UP+DOWN+HISTORY*UP+1);\nwire [ADDR_W-1:0] address=phase+tap*UP;')
start = source.index('        MAC: begin')
end = source.index('        OUTPUT: if(m_ready)', start)
source = source[:start] + '''        MAC: begin
            product_q<=product;
            state<=ACCUMULATE;
        end
        ACCUMULATE: begin
            acc<=total;
            if(tap==HISTORY-1) state<=QUANTIZE;
            else begin tap<=tap+1;state<=MAC;end
        end
        QUANTIZE: begin
            m_data<=scaled>MAXIMUM?MAXIMUM[DATA_W-1:0]:
                    scaled<MINIMUM?MINIMUM[DATA_W-1:0]:scaled[DATA_W-1:0];
            m_last<=ending && phase+DOWN>=remaining;
            m_valid<=1;state<=OUTPUT;
        end
''' + source[end:]
(HERE/'cip_dsp_resampler.v').write_text(source)
