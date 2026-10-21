// Endpoint-aligned exact-rational trilinear RGB lookup. Single-table, frame-safe load.
module color_lut3d #(parameter BITS=10,GRID_LOG2=2)(
 input wire clk,rst,ce,
 input wire load_begin_valid,output wire load_begin_ready,
 input wire[3*BITS-1:0] lut_data,input wire lut_valid,lut_last,output wire lut_ready,
 input wire commit_valid,output wire commit_ready,output reg commit_done,configured,
 output reg[3:0] config_error,output reg marker_error,
 input wire[3*BITS-1:0] s_rgb,input wire s_valid,s_sof,s_eol,s_eof,output wire s_ready,
 output wire[3*BITS-1:0] m_rgb,output wire m_valid,m_sof,m_eol,m_eof,input wire m_ready,
 output wire busy
);
 localparam K=1<<GRID_LOG2,N=K+1,DEPTH=N*N*N,AW=$clog2(DEPTH),D=(1<<BITS)-1;
 localparam ACC_W=4*BITS+1,DEN_W=3*BITS,MIW=$clog2(BITS),DIW=$clog2(ACC_W);
 localparam [DEN_W-1:0] DENOMINATOR=({{(DEN_W-BITS){1'b0}},{BITS{1'b1}}})*D*D;
 localparam IDLE=0,COORD=1,VADDR=2,VREAD=3,VCAP=4,SETUP=5,MULT=6,DIVIDE=7,OUTPUT=8;
 reg[3:0] state;
 reg loading,complete,frame_active;
 reg[AW-1:0] load_addr,read_addr;
 reg[3*BITS-1:0] table_mem[0:DEPTH-1],read_q,vertex[0:7];
 reg[3*BITS-1:0] pixel,out_rgb;
 reg out_sof,out_eol,out_eof;
 reg[1:0] channel,axis;
 reg[1:0] pair_index;
 reg[2:0] vertex_index;
 reg[BITS+GRID_LOG2-1:0] coordinate;
 reg[GRID_LOG2-1:0] index_work,lower_r,lower_g,lower_b;
 reg[BITS-1:0] fraction_r,fraction_g,fraction_b,weight;
 reg[3*BITS-1:0] work[0:3],operand_a,operand_b;
 reg[ACC_W-1:0] accumulator,dividend,quotient;
 reg[DEN_W:0] remainder;
 reg[MIW-1:0] mul_bit;
 reg[DIW-1:0] div_bit;
 wire cancel_cfg=!frame_active&&(load_begin_valid||commit_valid);
 assign load_begin_ready=ce&&!rst&&state==IDLE&&!frame_active;
 assign commit_ready=ce&&!rst&&state==IDLE&&!frame_active&&!load_begin_valid;
 assign lut_ready=ce&&!rst&&state==IDLE&&!frame_active&&loading&&!load_begin_valid&&!commit_valid;
 assign s_ready=ce&&!rst&&state==IDLE&&configured&&!loading&&!cancel_cfg;
 assign m_rgb=out_rgb;assign m_valid=!rst&&state==OUTPUT;
 assign m_sof=out_sof;assign m_eol=out_eol;assign m_eof=out_eof;
 assign busy=state!=IDLE||frame_active||loading;
 wire[GRID_LOG2:0] vr={1'b0,lower_r}+vertex_index[0];
 wire[GRID_LOG2:0] vg={1'b0,lower_g}+vertex_index[1];
 wire[GRID_LOG2:0] vb={1'b0,lower_b}+vertex_index[2];
 // Explicit constant shift-add addressing: R fastest, then G, then B.
 wire[AW-1:0] address=vr+(vg<<GRID_LOG2)+vg+(vb<<(2*GRID_LOG2))+(vb<<(GRID_LOG2+1))+vb;
 wire[ACC_W-1:0] selected=weight[mul_bit]?{{(ACC_W-3*BITS){1'b0}},operand_b}:{{(ACC_W-3*BITS){1'b0}},operand_a};
 wire[ACC_W-1:0] multiplied=accumulator+(selected<<mul_bit);
 wire[DEN_W:0] trial={remainder[DEN_W-1:0],dividend[ACC_W-1]};
 wire subtract=trial>={1'b0,DENOMINATOR};
 wire[ACC_W-1:0] quotient_next={quotient[ACC_W-2:0],subtract};
 wire[BITS-1:0] rounded=(|quotient_next[ACC_W-1:BITS])?{BITS{1'b1}}:quotient_next[BITS-1:0];
 function[BITS-1:0] component;
 input[3*BITS-1:0] rgb;input[1:0] which;
 begin case(which)0:component=rgb[3*BITS-1:2*BITS];1:component=rgb[2*BITS-1:BITS];default:component=rgb[BITS-1:0];endcase end
 endfunction
 always @(posedge clk)if(ce&&!rst)begin
 if(lut_valid&&lut_ready)table_mem[load_addr]<=lut_data;
 if(state==VREAD)read_q<=table_mem[read_addr];
 end
 initial if(BITS<8||BITS>12||GRID_LOG2<1||GRID_LOG2>4)$fatal(1,"invalid 3D LUT parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=IDLE;loading<=0;complete<=0;frame_active<=0;load_addr<=0;read_addr<=0;configured<=0;commit_done<=0;config_error<=0;marker_error<=0;
 pixel<=0;out_rgb<=0;out_sof<=0;out_eol<=0;out_eof<=0;channel<=0;axis<=0;pair_index<=0;vertex_index<=0;
 coordinate<=0;index_work<=0;lower_r<=0;lower_g<=0;lower_b<=0;fraction_r<=0;fraction_g<=0;fraction_b<=0;weight<=0;
 operand_a<=0;operand_b<=0;accumulator<=0;dividend<=0;quotient<=0;remainder<=0;mul_bit<=0;div_bit<=0;
 end else if(ce)begin
 commit_done<=0;
 if(load_begin_valid&&load_begin_ready)begin loading<=1;complete<=0;configured<=0;load_addr<=0;config_error<=0;end
 if(lut_valid&&lut_ready)begin
 if(lut_last!=(load_addr==DEPTH-1))begin config_error<=2;loading<=0;complete<=0;configured<=0;end
 else if(load_addr==DEPTH-1)begin loading<=0;complete<=1;end else load_addr<=load_addr+1'b1;
 end
 if(commit_valid&&commit_ready)begin
 if(!complete)config_error<=1;
 else begin configured<=1;commit_done<=1;end
 end
 case(state)
 IDLE:if(s_valid&&s_ready)begin
 pixel<=s_rgb;out_sof<=s_sof;out_eol<=s_eol;out_eof<=s_eof;
 if(s_sof!=!frame_active||(s_eof&&!s_eol))marker_error<=1;
 frame_active<=!s_eof;channel<=0;coordinate<=({{GRID_LOG2{1'b0}},s_rgb[3*BITS-1:2*BITS]}<<GRID_LOG2);index_work<=0;state<=COORD;
 end
 COORD:begin
 if(coordinate>=D&&index_work<K-1)begin coordinate<=coordinate-D;index_work<=index_work+1'b1;end
 else begin
 if(channel==0)begin lower_r<=index_work;fraction_r<=coordinate[BITS-1:0];coordinate<=({{GRID_LOG2{1'b0}},pixel[2*BITS-1:BITS]}<<GRID_LOG2);channel<=1;index_work<=0;end
 else if(channel==1)begin lower_g<=index_work;fraction_g<=coordinate[BITS-1:0];coordinate<=({{GRID_LOG2{1'b0}},pixel[BITS-1:0]}<<GRID_LOG2);channel<=2;index_work<=0;end
 else begin lower_b<=index_work;fraction_b<=coordinate[BITS-1:0];vertex_index<=0;state<=VADDR;end
 end
 end
 VADDR:begin read_addr<=address;state<=VREAD;end
 VREAD:state<=VCAP;
 VCAP:begin vertex[vertex_index]<=read_q;if(vertex_index==7)begin channel<=0;axis<=0;pair_index<=0;state<=SETUP;end else begin vertex_index<=vertex_index+1'b1;state<=VADDR;end end
 SETUP:begin
 accumulator<=0;mul_bit<=0;weight<=axis==0?fraction_r:axis==1?fraction_g:fraction_b;
 if(axis==0)begin operand_a<=component(vertex[{pair_index,1'b0}],channel);operand_b<=component(vertex[{pair_index,1'b1}],channel);end
 else if(axis==1)begin operand_a<=work[{pair_index[0],1'b0}];operand_b<=work[{pair_index[0],1'b1}];end
 else begin operand_a<=work[0];operand_b<=work[1];end
 state<=MULT;
 end
 MULT:begin
 accumulator<=multiplied;
 if(mul_bit==BITS-1)begin
 if(axis==2)begin dividend<=multiplied+(DENOMINATOR>>1);quotient<=0;remainder<=0;div_bit<=0;state<=DIVIDE;end
 else begin
 work[pair_index]<=multiplied[3*BITS-1:0];
 if((axis==0&&pair_index==3)||(axis==1&&pair_index==1))begin axis<=axis+1'b1;pair_index<=0;end else pair_index<=pair_index+1'b1;
 state<=SETUP;
 end
 end else mul_bit<=mul_bit+1'b1;
 end
 DIVIDE:begin
 remainder<=subtract?trial-{1'b0,DENOMINATOR}:trial;dividend<=dividend<<1;quotient<=quotient_next;
 if(div_bit==ACC_W-1)begin
 case(channel)0:out_rgb[3*BITS-1:2*BITS]<=rounded;1:out_rgb[2*BITS-1:BITS]<=rounded;default:out_rgb[BITS-1:0]<=rounded;endcase
 if(channel==2)state<=OUTPUT;else begin channel<=channel+1'b1;axis<=0;pair_index<=0;state<=SETUP;end
 end else div_bit<=div_bit+1'b1;
 end
 OUTPUT:if(m_ready)state<=IDLE;
 default:state<=IDLE;
 endcase
 end
 end
endmodule
