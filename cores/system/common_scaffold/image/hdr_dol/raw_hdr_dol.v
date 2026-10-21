// Active-row DOL demultiplexer: each logical row is LONG then SHORT.
module raw_dol2_demux #(parameter BITS=10,WIDTH=640,HEIGHT=480)(
 input wire clk,rst,ce,input wire [BITS-1:0] s_data,input wire s_valid,s_sof,s_eol,s_short,
 output wire s_ready,output reg [2*BITS-1:0] m_data,output wire m_valid,m_sof,m_eol,
 input wire m_ready,output reg busy,output reg protocol_error
);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 localparam CAP=0,READ=1,EMIT=2;
 reg[1:0] state;reg[XW-1:0] x;reg[YW-1:0] y;reg short_row;
 reg[BITS-1:0] long_mem[0:WIDTH-1],short_mem[0:WIDTH-1];
 assign s_ready=ce&&state==CAP;
 assign m_valid=state==EMIT;
 assign m_sof=m_valid&&x==0&&y==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 initial if((BITS!=8&&BITS!=10&&BITS!=12)||WIDTH<1||HEIGHT<1) $fatal(1,"invalid demux parameters");
 always @(posedge clk) begin
 if(rst) begin state<=CAP;x<=0;y<=0;short_row<=0;m_data<=0;busy<=0;protocol_error<=0;end
 else if(ce) begin
 case(state)
 CAP: if(s_valid&&s_ready) begin
 busy<=1;
 if(s_short!=short_row||s_sof!=(x==0&&y==0&&!short_row)||s_eol!=(x==WIDTH-1)) protocol_error<=1;
 if(short_row) short_mem[x]<=s_data;else long_mem[x]<=s_data;
 if(x==WIDTH-1) begin x<=0;if(short_row) state<=READ;else short_row<=1;end
 else x<=x+1'b1;
 end
 READ: begin m_data<={long_mem[x],short_mem[x]};state<=EMIT;end
 EMIT: if(m_ready) begin
 if(x==WIDTH-1) begin x<=0;short_row<=0;state<=CAP;if(y==HEIGHT-1) begin y<=0;busy<=0;end else y<=y+1'b1;end
 else begin x<=x+1'b1;state<=READ;end
 end
 default: state<=CAP;
 endcase
 end
 end
endmodule

// Radiance merge with saturation blend and deterministic motion rejection.
module raw_hdr2_merge #(parameter BITS=10,WIDTH=640,HEIGHT=480)(
 input wire clk,rst,ce,
 input wire cfg_valid,output wire cfg_ready,input wire[15:0] cfg_ratio_q8,
 input wire[BITS-1:0] cfg_black_long,cfg_black_short,cfg_blend_low,
 input wire[3:0] cfg_blend_shift,input wire[BITS+7:0] cfg_motion_threshold,
 input wire cfg_deghost,output reg cfg_error,
 input wire[2*BITS-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg[BITS+7:0] m_data,output reg m_valid,m_sof,m_eol,output reg m_motion,
 input wire m_ready,output reg protocol_error,output reg busy
);
 localparam OW=BITS+8,XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 reg[XW-1:0] x;reg[YW-1:0] y;
 reg[15:0] ratio;reg[BITS-1:0] bl,bs,low;reg[3:0] shift;
 reg[OW-1:0] motion_threshold;reg deghost;
 wire advance=!m_valid||m_ready;
 assign cfg_ready=ce&&!busy&&!m_valid;
 assign s_ready=ce&&advance&&!(cfg_valid&&!busy);
 wire[BITS-1:0] raw_l=s_data[2*BITS-1:BITS],raw_s=s_data[BITS-1:0];
 wire[BITS-1:0] l=raw_l>bl?raw_l-bl:0,sh=raw_s>bs?raw_s-bs:0;
 // Pixel times exposure ratio; result fits OW at ratio <=65535.
 wire[BITS+15:0] product=sh*ratio;
 wire[OW:0] rounded=({1'b0,product}+128)>>8;
 wire[OW-1:0] scaled=(rounded>{OW{1'b1}})?{OW{1'b1}}:rounded[OW-1:0];
 wire[OW-1:0] difference=(scaled>l)?scaled-l:l-scaled;
 wire[BITS:0] high={1'b0,low}+( ({{BITS{1'b0}},1'b1})<<shift );
 wire moving=deghost&&difference>motion_threshold;
 reg[8:0] weight;
 reg[OW+9:0] blend;
 reg[OW-1:0] result;
 always @* begin
 if(l<=low) weight=0;
 else if({1'b0,l}>=high) weight=256;
 else weight=(({{8{1'b0}},l}-low)<<8)>>shift;
 blend=l*(9'd256-weight)+scaled*weight+128;
 if(moving&&{1'b0,l}<high) result=l;else result=blend>>8;
 end
 initial if((BITS!=8&&BITS!=10&&BITS!=12)||WIDTH<1||HEIGHT<1) $fatal(1,"invalid merge parameters");
 always @(posedge clk) begin
 if(rst) begin
 x<=0;y<=0;ratio<=256;bl<=0;bs<=0;low<=0;shift<=BITS-1;motion_threshold<=0;deghost<=0;
 cfg_error<=0;protocol_error<=0;busy<=0;m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;m_motion<=0;
 end else if(ce) begin
 if(cfg_valid&&cfg_ready) begin
 if(cfg_ratio_q8<256||cfg_blend_shift>BITS||({1'b0,cfg_blend_low}+({{BITS{1'b0}},1'b1}<<cfg_blend_shift))>((1<<BITS)-1)) cfg_error<=1;
 else begin ratio<=cfg_ratio_q8;bl<=cfg_black_long;bs<=cfg_black_short;low<=cfg_blend_low;shift<=cfg_blend_shift;motion_threshold<=cfg_motion_threshold;deghost<=cfg_deghost;end
 end
 if(advance) begin
 m_valid<=s_valid&&s_ready;
 if(s_valid&&s_ready) begin
 m_data<=result;m_sof<=x==0&&y==0;m_eol<=x==WIDTH-1;m_motion<=moving;
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) protocol_error<=1;
 if(x==WIDTH-1) begin x<=0;if(y==HEIGHT-1) begin y<=0;busy<=0;end else begin y<=y+1'b1;busy<=1;end end
 else begin x<=x+1'b1;busy<=1;end
 end
 end
 end
 end
endmodule
