from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'bilateral_harness_v2/source/cip_image_bilateral_frame.v').read_text()
source=source.replace('reg [31:0] emitted,expected;', '''reg [31:0] emitted,expected,expected_last;
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
source=source.replace('emitted==expected-1','emitted==expected_last')
source=source.replace('emitted<=0;expected<=0;', 'emitted<=0;expected<=0;expected_last<=0;')
source=source.replace('KERNEL_CONFIG:begin', "KERNEL_CONFIG:begin expected_last<=expected-1'b1;")
source=source.replace('KERNEL_CONFIG:if(kernel_cfg_ready)state<=KERNEL_WAIT;', "KERNEL_CONFIG:begin expected_last<=expected-1'b1;if(kernel_cfg_ready)state<=KERNEL_WAIT;end")
source=source.replace('emitted<=emitted+1;', 'emitted<=emitted_next;')
source=source.replace('emitted+(output_fire?1:0)', '(output_fire?emitted_next:emitted)')
(HERE/'cip_image_bilateral_frame.v').write_text(source)
