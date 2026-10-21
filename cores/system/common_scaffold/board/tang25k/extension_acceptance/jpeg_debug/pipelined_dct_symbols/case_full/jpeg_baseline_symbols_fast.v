// Baseline JPEG coefficient symbolization only; no quantizer or Huffman coding.
module jpeg_baseline_symbols_fast #(parameter COEFF_W=16,COMPONENTS=3)(
 input wire clk,rst,ce,
 input wire signed[COEFF_W-1:0] s_coefficient,input wire s_valid,output wire s_ready,
 input wire s_first,s_last,input wire[1:0] s_component,input wire s_restart,
 output wire token_valid,input wire token_ready,output wire token_dc,
 output wire[3:0] token_run,token_size,output wire[15:0] token_amplitude,
 output wire token_block_end,token_restart,output wire[1:0] token_component,
 output reg[3:0] error_code
);
 localparam TAKE=0,EMIT=1,FAILED=2;
 reg[1:0] state;
 reg[5:0] index,zeros;
 reg signed[COEFF_W-1:0] predictor[0:COMPONENTS-1];
 reg[1:0] component;
 reg pending_dc,pending_end,pending_restart;
 reg[3:0] pending_size;
 reg[15:0] pending_amplitude;
 integer k;
 wire signed[COEFF_W:0] extended={s_coefficient[COEFF_W-1],s_coefficient};
 wire signed[COEFF_W:0] previous=(s_component<COMPONENTS&&!s_restart)?$signed({predictor[s_component][COEFF_W-1],predictor[s_component]}):0;
 wire signed[COEFF_W:0] value=(index==0)?extended-previous:extended;
 wire[COEFF_W:0] magnitude=value<0?-value:value;
 function[4:0] category;
 input[COEFF_W:0] m;
 integer i;
 begin category=0;for(i=0;i<=COEFF_W;i=i+1)if(m[i])category=i+1;end
 endfunction
 wire[4:0] size=category(magnitude);
 // Exact negative amplitude = mask - magnitude = (~magnitude) & mask.
 // Prefix OR directly produces each mask bit, avoiding category->barrel shift
 // ->32-bit addition on the token amplitude path. Error/category logic unchanged.
 wire[15:0] amplitude_mask,magnitude_low;
 assign magnitude_low=magnitude;
 genvar mb;generate for(mb=0;mb<16;mb=mb+1)begin:mask_bits
 if(mb<=COEFF_W)assign amplitude_mask[mb]=|magnitude[COEFF_W:mb];
 else assign amplitude_mask[mb]=1'b0;
 end endgenerate
 wire[15:0] amplitude=(value<0)?((~magnitude_low)&amplitude_mask):value;
 assign s_ready=ce&&state==TAKE;
 assign token_valid=state==EMIT;
 assign token_dc=pending_dc;
 assign token_run=(!pending_dc&&zeros>=16)?4'd15:zeros[3:0];
 assign token_size=(!pending_dc&&zeros>=16)?4'd0:pending_size;
 assign token_amplitude=(!pending_dc&&zeros>=16)?16'd0:pending_amplitude;
 assign token_block_end=pending_end&&!(zeros>=16&&!pending_dc);
 assign token_restart=pending_restart;
 assign token_component=component;
 initial if(COEFF_W<2||COEFF_W>16||COMPONENTS<1||COMPONENTS>4)$fatal(1,"invalid JPEG symbol parameters");
 always @(posedge clk) begin
 if(rst) begin
 state<=TAKE;index<=0;zeros<=0;component<=0;pending_dc<=0;pending_end<=0;pending_restart<=0;pending_size<=0;pending_amplitude<=0;error_code<=0;
 for(k=0;k<COMPONENTS;k=k+1)predictor[k]<=0;
 end else if(ce) begin
 if(state==EMIT&&token_ready) begin
 if(!pending_dc&&zeros>=16) zeros<=zeros-16;
 else begin state<=TAKE;zeros<=0;end
 end
 if(state==TAKE&&s_valid&&s_ready) begin
 if(s_first!=(index==0)||s_last!=(index==63)) begin error_code<=1;state<=FAILED;end
 else if(s_component>=COMPONENTS||(index!=0&&s_component!=component)) begin error_code<=2;state<=FAILED;end
 else if(s_restart&&index!=0) begin error_code<=5;state<=FAILED;end
 else if(index==0&&size>11) begin error_code<=3;state<=FAILED;end
 else if(index!=0&&size>10) begin error_code<=4;state<=FAILED;end
 else begin
 pending_restart<=0;
 if(index==0) begin
 if(s_restart)for(k=0;k<COMPONENTS;k=k+1)predictor[k]<=0;
 predictor[s_component]<=s_coefficient;component<=s_component;
 pending_dc<=1;pending_restart<=s_restart;pending_end<=0;pending_size<=size[3:0];pending_amplitude<=amplitude;zeros<=0;state<=EMIT;index<=1;
 end else begin
 index<=(index==63)?0:index+1'b1;
 if(s_coefficient!=0) begin
 pending_dc<=0;pending_size<=size[3:0];pending_amplitude<=amplitude;pending_end<=index==63;state<=EMIT;
 end else if(index==63) begin
 pending_dc<=0;pending_size<=0;pending_amplitude<=0;pending_end<=1;zeros<=0;state<=EMIT;
 end else zeros<=zeros+1'b1;
 end
 end
 end
 end
 end
endmodule
