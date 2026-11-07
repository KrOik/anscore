// SPDX-License-Identifier: Apache-2.0
// Original F(2x2,3x3) integer tile cross-correlation; see ARCHITECTURE.md.
module int4_winograd_tile #(
 parameter integer MAX_ROWS=8, TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_row,input wire [3:0] c_tap,
 input wire signed [3:0] c_weight,input wire signed [31:0] c_bias,
 input wire [15:0] c_scale,input wire [5:0] c_shift,
 input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_rows,
 input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [32:0] m_acc,
 output wire [15:0] m_row,output wire [1:0] m_pixel,
 output wire [15:0] m_scale,output wire [4:0] m_shift,
 output wire signed [7:0] m_zero,output wire [TAG_W-1:0] m_tag,
 output wire m_last,
 output wire rsp_valid,input wire rsp_ready,output wire [1:0] rsp_error,
 output wire [8:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag,
 output wire busy
);
 localparam IDLE=0,CFG_RSP=1,G_RD=2,G_TAKE=3,G_LEFT=4,G_RIGHT=5,
            CHECK=6,LOAD=7,D_LEFT=8,D_RIGHT=9,ROW=10,M_RD=11,
            M_MUL=12,Y_LEFT=13,Y_RIGHT=14,SEND=15,RSP=16;
 reg [4:0] state;
 reg [MAX_ROWS-1:0] published,meta_valid;
 reg [8:0] tap_valid[0:MAX_ROWS-1];
 // Only validity is reset. Every payload is overwritten before it is read.
 reg signed [3:0] tap_mem[0:9*MAX_ROWS-1];
 reg signed [7:0] u_mem[0:16*MAX_ROWS-1];
 reg signed [31:0] bias_mem[0:MAX_ROWS-1];
 reg [15:0] scale_mem[0:MAX_ROWS-1];
 reg [4:0] shift_mem[0:MAX_ROWS-1];
 reg signed [7:0] zero_mem[0:MAX_ROWS-1];
 reg [5:0] publish_row,row_index;
 reg [6:0] rows;
 reg [4:0] index;
 reg [1:0] pixel;
 reg [7:0] x_zero;
 reg [TAG_W-1:0] tag;
 reg [1:0] error_code;
 reg [8:0] output_count;
 reg signed [3:0] tap_read,g[0:8];
 reg signed [5:0] gt[0:11];
 reg signed [8:0] d[0:15];
 reg signed [9:0] dt[0:15];
 reg signed [10:0] v[0:15],v_read;
 reg signed [7:0] u_read;
 reg signed [18:0] products[0:15];
 reg signed [20:0] yt[0:7];
 reg signed [32:0] accum[0:3];
 reg signed [31:0] bias;
 reg [15:0] scale;
 reg [4:0] shift;
 reg signed [7:0] zero;

 assign c_ready=!rst && state==IDLE;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign c_rsp_valid=!rst && state==CFG_RSP;
 assign s_ready=!rst && state==LOAD;
 assign m_valid=!rst && state==SEND;
 assign m_acc=accum[pixel];
 assign m_row={10'd0,row_index};assign m_pixel=pixel;
 assign m_scale=scale;assign m_shift=shift;assign m_zero=zero;
 assign m_tag=tag;
 assign m_last=({1'b0,row_index}==rows-7'd1) && pixel==2'd3;
 assign rsp_valid=!rst && state==RSP;
 assign rsp_error=error_code;assign rsp_outputs=output_count;assign rsp_tag=tag;
 assign busy=state!=IDLE;

 // Gp=2G. Both transforms are exact integer additions, without rounding.
 function automatic signed [5:0] gx6(
  input signed [5:0] a,b,c,input [1:0] phase
 );
  begin case(phase)
   0:gx6=a<<<1;1:gx6=a+b+c;2:gx6=a-b+c;default:gx6=c<<<1;
  endcase end
 endfunction
 function automatic signed [7:0] gx8(
  input signed [7:0] a,b,c,input [1:0] phase
 );
  begin case(phase)
   0:gx8=a<<<1;1:gx8=a+b+c;2:gx8=a-b+c;default:gx8=c<<<1;
  endcase end
 endfunction
 function automatic signed [9:0] bx10(
  input signed [9:0] a,b,c,e,input [1:0] phase
 );
  begin case(phase)
   0:bx10=a-c;1:bx10=b+c;2:bx10=c-b;default:bx10=e-b;
  endcase end
 endfunction
 function automatic signed [10:0] bx11(
  input signed [10:0] a,b,c,e,input [1:0] phase
 );
  begin case(phase)
   0:bx11=a-c;1:bx11=b+c;2:bx11=c-b;default:bx11=e-b;
  endcase end
 endfunction
 function automatic signed [20:0] ax21(
  input signed [20:0] a,b,c,e,input phase
 );
  begin ax21=phase ? b-c+e : a+b+c;end
 endfunction
 function automatic signed [22:0] ax23(
  input signed [22:0] a,b,c,e,input phase
 );
  begin ax23=phase ? b-c+e : a+b+c;end
 endfunction

 // These small transform scratchpads have intentional combinational reads;
 // resident raw/transformed kernels each use one scheduled synchronous read.
 wire [1:0] g_col=index%5'd3;
 wire [1:0] g_phase=index/5'd3;
 wire [3:0] g_base={index[3:2],1'b0}+{2'b0,index[3:2]};
 wire signed [5:0] ga={{2{g[g_col][3]}},g[g_col]};
 wire signed [5:0] gb={{2{g[g_col+4'd3][3]}},g[g_col+4'd3]};
 wire signed [5:0] gc={{2{g[g_col+4'd6][3]}},g[g_col+4'd6]};
 wire signed [7:0] gta={{2{gt[g_base][5]}},gt[g_base]};
 wire signed [7:0] gtb={{2{gt[g_base+4'd1][5]}},gt[g_base+4'd1]};
 wire signed [7:0] gtc={{2{gt[g_base+4'd2][5]}},gt[g_base+4'd2]};
 wire [3:0] d_col={2'd0,index[1:0]},d_base={index[3:2],2'd0};
 wire signed [9:0] da={d[d_col][8],d[d_col]};
 wire signed [9:0] db={d[d_col+4'd4][8],d[d_col+4'd4]};
 wire signed [9:0] dc={d[d_col+4'd8][8],d[d_col+4'd8]};
 wire signed [9:0] de={d[d_col+4'd12][8],d[d_col+4'd12]};
 wire signed [10:0] dta={dt[d_base][9],dt[d_base]};
 wire signed [10:0] dtb={dt[d_base+4'd1][9],dt[d_base+4'd1]};
 wire signed [10:0] dtc={dt[d_base+4'd2][9],dt[d_base+4'd2]};
 wire signed [10:0] dte={dt[d_base+4'd3][9],dt[d_base+4'd3]};
 wire signed [18:0] product=v_read*u_read;
 wire [3:0] y_col={2'd0,index[1:0]};
 wire signed [20:0] ya={{2{products[y_col][18]}},products[y_col]};
 wire signed [20:0] yb={{2{products[y_col+4'd4][18]}},products[y_col+4'd4]};
 wire signed [20:0] yc={{2{products[y_col+4'd8][18]}},products[y_col+4'd8]};
 wire signed [20:0] ye={{2{products[y_col+4'd12][18]}},products[y_col+4'd12]};
 wire [2:0] y_base={index[1],2'd0};
 wire signed [22:0] yta={{2{yt[y_base][20]}},yt[y_base]};
 wire signed [22:0] ytb={{2{yt[y_base+3'd1][20]}},yt[y_base+3'd1]};
 wire signed [22:0] ytc={{2{yt[y_base+3'd2][20]}},yt[y_base+3'd2]};
 wire signed [22:0] yte={{2{yt[y_base+3'd3][20]}},yt[y_base+3'd3]};
 wire signed [22:0] y4=ax23(yta,ytb,ytc,yte,index[0]);
 wire signed [22:0] exact_dot=y4>>>2;
 wire signed [32:0] bias_wide={bias[31],bias};
 wire signed [32:0] dot_wide={{10{exact_dot[22]}},exact_dot};

 integer reset_row;
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;published<=0;meta_valid<=0;c_error<=0;
   for(reset_row=0;reset_row<MAX_ROWS;reset_row=reset_row+1) tap_valid[reset_row]<=0;
   publish_row<=0;row_index<=0;rows<=0;index<=0;pixel<=0;
   x_zero<=0;tag<=0;error_code<=0;output_count<=0;
   bias<=0;scale<=0;shift<=0;zero<=0;
  end else case(state)
   IDLE: begin
    if(c_valid) begin
     c_error<=0;state<=CFG_RSP;
     case(c_op)
      0: if(c_row>=MAX_ROWS || c_tap>=9) c_error<=1;
         else begin
          tap_mem[c_row*9+c_tap]<=c_weight;tap_valid[c_row][c_tap]<=1;
          published[c_row]<=0;
         end
      1: if(c_row>=MAX_ROWS) c_error<=1;
         else if(c_shift>31) c_error<=2;
         else begin
          bias_mem[c_row]<=c_bias;scale_mem[c_row]<=c_scale;
          shift_mem[c_row]<=c_shift[4:0];zero_mem[c_row]<=c_zero;
          meta_valid[c_row]<=1;published[c_row]<=0;
         end
      2: if(c_row>=MAX_ROWS) c_error<=1;
         else if(!meta_valid[c_row] || tap_valid[c_row]!=9'h1ff) c_error<=3;
         else begin publish_row<=c_row[5:0];index<=0;state<=G_RD;end
      3: begin
          published<=0;meta_valid<=0;
          for(reset_row=0;reset_row<MAX_ROWS;reset_row=reset_row+1) tap_valid[reset_row]<=0;
         end
     endcase
    end else if(cmd_valid) begin
     rows<=cmd_rows[6:0];x_zero<=cmd_x_zero;tag<=cmd_tag;
     row_index<=0;index<=0;pixel<=0;error_code<=0;output_count<=0;
     if(cmd_rows==0 || cmd_rows>MAX_ROWS) begin error_code<=1;state<=RSP;end
     else state<=CHECK;
    end
   end
   CFG_RSP:if(c_rsp_ready) state<=IDLE;
   G_RD:begin tap_read<=tap_mem[publish_row*9+index];state<=G_TAKE;end
   G_TAKE:begin
    g[index]<=tap_read;
    if(index==8) begin index<=0;state<=G_LEFT;end
    else begin index<=index+1'b1;state<=G_RD;end
   end
   G_LEFT:begin
    gt[index]<=gx6(ga,gb,gc,g_phase);
    if(index==11) begin index<=0;state<=G_RIGHT;end else index<=index+1'b1;
   end
   G_RIGHT:begin
    u_mem[publish_row*16+index]<=gx8(gta,gtb,gtc,index[1:0]);
    if(index==15) begin published[publish_row]<=1;state<=CFG_RSP;end
    else index<=index+1'b1;
   end
   CHECK:begin
    if(!published[row_index]) begin error_code<=2;state<=RSP;end
    else if({1'b0,row_index}==rows-7'd1) begin row_index<=0;state<=LOAD;end
    else row_index<=row_index+1'b1;
   end
   LOAD:if(s_valid) begin
    d[index]<=$signed({1'b0,s_data})-$signed({1'b0,x_zero});
    if(s_last!=(index==15)) error_code<=3;
    if(index==15) begin index<=0;state<=D_LEFT;end else index<=index+1'b1;
   end
   D_LEFT:begin
    dt[index]<=bx10(da,db,dc,de,index[3:2]);
    if(index==15) begin index<=0;state<=D_RIGHT;end else index<=index+1'b1;
   end
   D_RIGHT:begin
    v[index]<=bx11(dta,dtb,dtc,dte,index[1:0]);
    if(index==15) begin index<=0;state<=ROW;end else index<=index+1'b1;
   end
   ROW:begin
    bias<=bias_mem[row_index];scale<=scale_mem[row_index];
    shift<=shift_mem[row_index];zero<=zero_mem[row_index];index<=0;state<=M_RD;
   end
   M_RD:begin
    u_read<=u_mem[row_index*16+index];v_read<=v[index];state<=M_MUL;
   end
   M_MUL:begin
    products[index]<=product;
    if(index==15) begin index<=0;state<=Y_LEFT;end
    else begin index<=index+1'b1;state<=M_RD;end
   end
   Y_LEFT:begin
    yt[index]<=ax21(ya,yb,yc,ye,index[2]);
    if(index==7) begin index<=0;state<=Y_RIGHT;end else index<=index+1'b1;
   end
   Y_RIGHT:begin
    // The Winograd identity makes y4[1:0] zero for every legal integer tile.
    // This shift is exact, including negative values; no rounding is applied.
    accum[index[1:0]]<=bias_wide+dot_wide;
    if(index==3) begin pixel<=0;state<=SEND;end else index<=index+1'b1;
   end
   SEND:if(m_ready) begin
    output_count<=output_count+9'd1;
    if(pixel==3) begin
     if({1'b0,row_index}==rows-7'd1) state<=RSP;
     else begin row_index<=row_index+1'b1;state<=ROW;end
    end else pixel<=pixel+1'b1;
   end
   RSP:if(rsp_ready) state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 initial begin
  if(MAX_ROWS<1 || MAX_ROWS>64 || TAG_W<1 || TAG_W>32)
   $fatal(1,"int4_winograd_tile parameter outside documented domain");
 end
endmodule
