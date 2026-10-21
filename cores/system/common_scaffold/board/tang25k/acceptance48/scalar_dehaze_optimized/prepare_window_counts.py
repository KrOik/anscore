from pathlib import Path
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
text=(COMMON/'signal_video/rtl/cip_image_window_filter_frame.v').read_text()
text=text.replace('reg [31:0] emitted,expected;', '''reg [31:0] emitted,expected,expected_last;
// Parallel byte carries preserve exact modulo-2^32 counting without a long
// no-ALU LUT ripple chain. No extra latency or CE assumptions are introduced.
function [31:0] increment_count;
 input [31:0] value;
 begin
  increment_count[7:0]=value[7:0]+8'd1;
  increment_count[15:8]=value[15:8]+(&value[7:0]);
  increment_count[23:16]=value[23:16]+(&value[15:0]);
  increment_count[31:24]=value[31:24]+(&value[23:0]);
 end
endfunction
wire [31:0] emitted_next=increment_count(emitted);''')
text=text.replace('emitted==expected-1','emitted==expected_last')
text=text.replace('emitted<=0;expected<=0;', 'emitted<=0;expected<=0;expected_last<=0;')
text=text.replace('CONFIGURE:if(window_cfg_ready) state<=ACTIVE;', 'CONFIGURE:begin expected_last<=expected-1\'b1;if(window_cfg_ready) state<=ACTIVE;end')
text=text.replace('emitted<=emitted+1;', 'emitted<=emitted_next;')
text=text.replace('emitted+(output_fire?1:0)', '(output_fire?emitted_next:emitted)')
(HERE/'cip_image_window_filter_frame.v').write_text(text)
