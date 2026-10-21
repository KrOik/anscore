// D65 sRGB888 <-> CIELAB8; signed Q16 matrix arithmetic, synchronous transfer ROMs.
module rgb_cielab_stream #(parameter WIDTH=16,HEIGHT=16,
 parameter DECODE_FILE="decode.mem",NONLINEAR_FILE="nonlinear.mem")(
 input wire clk,rst,ce,start_valid,output wire start_ready,input wire cfg_inverse,
 input wire[23:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg[23:0] m_data,output wire m_valid,output reg m_sof,m_eol,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[3:0] error_code,output wire busy
);
 localparam IDLE=0,INPUT_PIXEL=1,DEC_READ=2,DEC_CAPTURE=3,DEC_FIN=4,
 MAT_BEGIN=5,MAT_ISSUE=6,MAT_RESULT=7,MAT_FIN=8,NL_BEGIN=9,NL_READ0=10,NL_CAPTURE0=11,
 NL_READ1=12,NL_CAPTURE1=13,NL_ISSUE=14,NL_RESULT=15,NL_FIN=16,ENC_BEGIN=17,ENC_ISSUE=18,
 ENC_RESULT=19,ENC_LDIV=20,ENC_FIN=21,HOLD=22,DONE=23,MULTIPLY=24,DIVIDE=25;
 reg[4:0] state,return_state;reg inverse;
 reg[15:0] index,column;reg[23:0] pixel;
 reg[1:0] channel,term,kind;reg signed[31:0] vector[0:2],result[0:2];reg[7:0] encoded[0:2];
 reg signed[18:0] decode_rom[0:1023],decode_q;
 reg signed[25:0] nonlinear_rom[0:4095],nonlinear_q,base_value;
 reg[11:0] nonlinear_address;reg[6:0] fraction;reg[2:0] fraction_shift;
 reg signed[63:0] accumulator,product;
 reg[63:0] magnitude,multiplicand;reg[31:0] multiplier;reg negative;reg[4:0] mul_bit;
 reg[31:0] dividend,quotient,divisor;reg[32:0] remainder;reg[4:0] div_bit;
 wire[32:0] trial={remainder[31:0],dividend[31]};wire subtract=trial>={1'b0,divisor};
 wire[31:0] quotient_next={quotient[30:0],subtract};
 wire[7:0] selected=channel==0?pixel[23:16]:(channel==1?pixel[15:8]:pixel[7:0]);
 wire[9:0] decode_address=inverse?({channel,8'b0}+10'd256+selected):{2'b0,selected};
 reg signed[31:0] coefficient;
 always @* begin
 coefficient=0;
 if(!inverse)case(channel*3+term)
 0:coefficient=28440;1:coefficient=24655;2:coefficient=12441;
 3:coefficient=13938;4:coefficient=46868;5:coefficient=4730;
 6:coefficient=1164;7:coefficient=7174;8:coefficient=57198;endcase
 else case(channel*3+term)
 0:coefficient=201848;1:coefficient=-100738;2:coefficient=-35574;
 3:coefficient=-60376;4:coefficient=122946;5:coefficient=2965;
 6:coefficient=3466;7:coefficient=-13371;8:coefficient=75441;endcase
 end
 assign start_ready=ce&&!rst&&state==IDLE;assign s_ready=ce&&!rst&&state==INPUT_PIXEL;
 assign m_valid=!rst&&state==HOLD;assign done_valid=!rst&&state==DONE;assign busy=state!=IDLE;
 function signed[31:0] round16;input signed[63:0] v;
 begin if(v<0)round16=-(((-v)+64'sd32768)>>>16);else round16=(v+64'sd32768)>>>16;end endfunction
 function[7:0] clamp8;input signed[31:0] v;begin clamp8=v<0?0:(v>255?255:v[7:0]);end endfunction
 function signed[31:0] clamp_linear;input signed[31:0] v;
 begin clamp_linear=v<0?0:(v>65536?65536:v);end endfunction
 task mul;input signed[31:0] a,b;input[4:0] next_state;
 begin magnitude<=0;multiplicand<={32'b0,(a<0?-a:a)};multiplier<=b<0?-b:b;negative<=a[31]^b[31];mul_bit<=0;return_state<=next_state;state<=MULTIPLY;end endtask
 task divide;input[31:0] a,b;input[4:0] next_state;
 begin dividend<=a;divisor<=b;quotient<=0;remainder<=0;div_bit<=0;return_state<=next_state;state<=DIVIDE;end endtask
 reg signed[31:0] nl_input;reg[17:0] nl_offset;
 always @* begin
 nl_input=vector[channel];nl_offset=0;
 if(kind==2)begin
 if(nl_input< -32768)nl_offset=0;else if(nl_input>131072)nl_offset=163840;else nl_offset=nl_input+32768;
 end else nl_offset=clamp_linear(nl_input);
 end
 wire signed[63:0] interpolation=$signed(base_value)+((product+(64'sd1<<(fraction_shift-1)))>>>fraction_shift);
 wire signed[63:0] mac=accumulator+product;
 initial begin
 if(WIDTH<1||HEIGHT<1||WIDTH>65536||HEIGHT>65536||WIDTH*HEIGHT>65536)$fatal(1,"invalid CIELAB geometry");
 $readmemh(DECODE_FILE,decode_rom);$readmemh(NONLINEAR_FILE,nonlinear_rom);
 end
 // Synchronous ROM access. No coefficient or frame arrays are asynchronous.
 always @(posedge clk)if(ce&&!rst)begin
 if(state==DEC_READ)decode_q<=decode_rom[decode_address];
 if(state==NL_READ0||state==NL_READ1)nonlinear_q<=nonlinear_rom[nonlinear_address];
 end
 integer j;
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;return_state<=0;inverse<=0;index<=0;column<=0;pixel<=0;channel<=0;term<=0;kind<=0;
 nonlinear_address<=0;fraction<=0;fraction_shift<=6;base_value<=0;accumulator<=0;product<=0;
 magnitude<=0;multiplicand<=0;multiplier<=0;negative<=0;mul_bit<=0;dividend<=0;quotient<=0;divisor<=1;remainder<=0;div_bit<=0;
 m_data<=0;m_sof<=0;m_eol<=0;done_error<=0;error_code<=0;
 for(j=0;j<3;j=j+1)begin vector[j]<=0;result[j]<=0;encoded[j]<=0;end
 end else if(ce)case(state)
 IDLE:if(start_valid)begin inverse<=cfg_inverse;index<=0;column<=0;done_error<=0;error_code<=0;state<=INPUT_PIXEL;end
 INPUT_PIXEL:if(s_valid)begin
 pixel<=s_data;channel<=0;m_sof<=index==0;m_eol<=column==WIDTH-1;
 if(s_sof!=(index==0)||s_eol!=(column==WIDTH-1))begin done_error<=1;error_code<=error_code|{(s_eol&&column!=WIDTH-1),(!s_eol&&column==WIDTH-1),(s_sof&&index!=0),(!s_sof&&index==0)};end
 state<=DEC_READ;end
 DEC_READ:state<=DEC_CAPTURE;
 DEC_CAPTURE:begin vector[channel]<=decode_q;if(channel==2)state<=DEC_FIN;else begin channel<=channel+1'b1;state<=DEC_READ;end end
 DEC_FIN:begin
 if(inverse)begin vector[0]<=vector[0]+vector[1];vector[1]<=vector[0];vector[2]<=vector[0]-vector[2];kind<=2;state<=NL_BEGIN;end
 else state<=MAT_BEGIN;end
 MAT_BEGIN:begin channel<=0;term<=0;accumulator<=0;state<=MAT_ISSUE;end
 MAT_ISSUE:mul(vector[term],coefficient,MAT_RESULT);
 MAT_RESULT:begin
 if(term==2)begin result[channel]<=round16(mac);accumulator<=0;term<=0;if(channel==2)state<=MAT_FIN;else begin channel<=channel+1'b1;state<=MAT_ISSUE;end end
 else begin accumulator<=mac;term<=term+1'b1;state<=MAT_ISSUE;end end
 MAT_FIN:begin for(j=0;j<3;j=j+1)vector[j]<=clamp_linear(result[j]);kind<=inverse?1:0;state<=NL_BEGIN;end
 NL_BEGIN:begin channel<=0;state<=NL_FIN;end
 NL_FIN:begin
 if(kind==2)begin nonlinear_address<=2050+(nl_offset>>7);fraction<=nl_offset[6:0];fraction_shift<=7;end
 else begin nonlinear_address<=(kind==1?1025:0)+(nl_offset>>6);fraction<={1'b0,nl_offset[5:0]};fraction_shift<=6;end
 state<=NL_READ0;end
 NL_READ0:state<=NL_CAPTURE0;
 NL_CAPTURE0:begin base_value<=nonlinear_q;nonlinear_address<=nonlinear_address+1'b1;state<=NL_READ1;end
 NL_READ1:state<=NL_CAPTURE1;
 NL_CAPTURE1:state<=NL_ISSUE;
 NL_ISSUE:mul($signed(nonlinear_q)-$signed(base_value),$signed({25'b0,fraction}),NL_RESULT);
 NL_RESULT:begin
 result[channel]<=interpolation;
 if(kind==1)encoded[channel]<=clamp8(round16(interpolation));
 if(channel==2)begin
 if(kind==2)begin for(j=0;j<2;j=j+1)vector[j]<=result[j];vector[2]<=interpolation;state<=MAT_BEGIN;end
 else if(kind==1)begin m_data<={encoded[0],encoded[1],clamp8(round16(interpolation))};state<=HOLD;end
 else state<=ENC_BEGIN;
 end else begin channel<=channel+1'b1;state<=NL_FIN;end end
 ENC_BEGIN:begin channel<=0;state<=ENC_ISSUE;end
 ENC_ISSUE:case(channel)
 0:mul(result[1],29580,ENC_RESULT);
 1:mul(result[0]-result[1],500,ENC_RESULT);
 default:mul(result[1]-result[2],200,ENC_RESULT);endcase
 ENC_RESULT:begin
 if(channel==0)begin if(product<=267386880)begin encoded[0]<=0;channel<=1;state<=ENC_ISSUE;end
 else divide(product-267386880+3276800,6553600,ENC_LDIV);end
 else begin encoded[channel]<=clamp8(round16(product)+128);if(channel==2)state<=ENC_FIN;else begin channel<=channel+1'b1;state<=ENC_ISSUE;end end end
 ENC_LDIV:begin encoded[0]<=clamp8($signed(quotient));channel<=1;state<=ENC_ISSUE;end
 ENC_FIN:begin m_data<={encoded[0],encoded[1],encoded[2]};state<=HOLD;end
 HOLD:if(m_ready)begin if(index==WIDTH*HEIGHT-1)state<=DONE;else begin index<=index+1'b1;column<=column==WIDTH-1?0:column+1'b1;state<=INPUT_PIXEL;end end
 DONE:if(done_ready)state<=IDLE;
 MULTIPLY:begin
 magnitude<=magnitude+(multiplier[0]?multiplicand:64'b0);multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(mul_bit==31)begin product<=negative?-$signed(magnitude+(multiplier[0]?multiplicand:64'b0)):$signed(magnitude+(multiplier[0]?multiplicand:64'b0));state<=return_state;end
 else mul_bit<=mul_bit+1'b1;end
 DIVIDE:begin dividend<=dividend<<1;quotient<=quotient_next;remainder<=subtract?trial-divisor:trial;
 if(div_bit==31)state<=return_state;else div_bit<=div_bit+1'b1;end
 default:begin done_error<=1;error_code<=15;state<=DONE;end
 endcase
 end
endmodule
