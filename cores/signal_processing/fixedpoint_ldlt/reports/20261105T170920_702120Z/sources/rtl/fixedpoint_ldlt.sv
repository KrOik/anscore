// SPDX-License-Identifier: Apache-2.0
// Independent unpivoted fixed-point LDL^T factorization; no square root.
module fixedpoint_ldlt #(
 parameter integer MAX_N=4, DATA_W=16, FRAC=8, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid, output wire c_ready,
 input wire [31:0] c_dimension, input wire [TAG_W-1:0] c_tag,
 input wire s_valid, output wire s_ready,
 input wire signed [DATA_W-1:0] s_data,
 output reg m_valid, input wire m_ready,
 output reg [1:0] m_status,
 output reg [31:0] m_row,m_column,
 output reg signed [DATA_W-1:0] m_data,
 output reg m_diagonal,m_last,
 output reg [TAG_W-1:0] m_tag
);
 localparam integer IW=(MAX_N<2)?1:$clog2(MAX_N);
 localparam integer NW=(MAX_N<2)?1:$clog2(MAX_N+1);
 localparam integer MW=(MAX_N*MAX_N<2)?1:$clog2(MAX_N*MAX_N);
 localparam integer ACC_W=3*DATA_W+$clog2(MAX_N+1)+2;
 localparam [3:0] IDLE=0,LOAD=1,PREP=2,GET=3,PAIR=4,TRIPLE=5,
   ACCUM=6,DECIDE=7,DIV_SEND=8,DIV_WAIT=9,NEXT=10,EMIT=11,HOLD=12;
 reg [3:0] state;
 reg [NW-1:0] n;
 reg [IW-1:0] load_row,load_col,i,k,j,out_row,out_col;
 reg [TAG_W-1:0] tag;
 reg signed [DATA_W-1:0] matrix[0:MAX_N*MAX_N-1];
 reg signed [DATA_W-1:0] lower[0:MAX_N*MAX_N-1];
 reg signed [DATA_W-1:0] diagonal[0:MAX_N-1];
 reg signed [DATA_W-1:0] op_a,op_b,op_d;
 reg signed [2*DATA_W-1:0] pair_product;
 reg signed [3*DATA_W-1:0] triple_product;
 reg signed [ACC_W-1:0] residual,divisor;
 wire signed [ACC_W-1:0] shifted_pivot=residual >>> (2*FRAC);
 wire signed [ACC_W-1:0] div_result;
 wire div_s_ready,div_m_valid,div_zero,div_overflow;
 wire [ACC_W-1:0] div_remainder;
 wire div_s_valid=(state==DIV_SEND);
 wire div_m_ready=(state==DIV_WAIT);
 function automatic [MW-1:0] address(input [IW-1:0] row,column);
   address=row*MAX_N+column;
 endfunction
 function automatic fits(input signed [ACC_W-1:0] value);
   fits=(value=={{(ACC_W-DATA_W){value[DATA_W-1]}},value[DATA_W-1:0]});
 endfunction
 wire signed [ACC_W-1:0] original_value=
   {{(ACC_W-DATA_W){matrix[address(i,k)][DATA_W-1]}},matrix[address(i,k)]};
 wire signed [ACC_W-1:0] diagonal_value=
   {{(ACC_W-DATA_W){diagonal[k][DATA_W-1]}},diagonal[k]};
 wire signed [ACC_W-1:0] widened_triple=
   {{(ACC_W-3*DATA_W){triple_product[3*DATA_W-1]}},triple_product};
 signed_divider #(.W(ACC_W)) divider(
   .clk(clk),.rst(rst),.s_valid(div_s_valid),.s_ready(div_s_ready),
   .s_numerator(residual),.s_denominator(divisor),
   .m_valid(div_m_valid),.m_ready(div_m_ready),
   .m_quotient(div_result),.m_remainder(div_remainder),
   .m_divzero(div_zero),.m_overflow(div_overflow));
 assign c_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==LOAD;
 generate if(MAX_N<1 || MAX_N>8 || DATA_W<4 || DATA_W>16 ||
             FRAC<1 || FRAC>DATA_W-2 || TAG_W<1 || TAG_W>32) begin:invalid
   fixedpoint_ldlt_invalid_parameters__see_README bad_parameters();
 end endgenerate

 always @(posedge clk) begin
   // Only loaded lower-triangle entries are ever read. No payload RAM reset.
   if(s_valid && s_ready) matrix[address(load_row,load_col)]<=s_data;
 end
 always @(posedge clk) begin
   if(rst) begin
     state<=IDLE;n<=0;load_row<=0;load_col<=0;i<=0;k<=0;j<=0;
     out_row<=0;out_col<=0;tag<=0;op_a<=0;op_b<=0;op_d<=0;
     pair_product<=0;triple_product<=0;residual<=0;divisor<=0;
     m_valid<=0;m_status<=0;m_row<=0;m_column<=0;m_data<=0;
     m_diagonal<=0;m_last<=0;m_tag<=0;
   end else case(state)
     IDLE: if(c_valid && c_ready) begin
       tag<=c_tag;
       if(c_dimension==0 || c_dimension>MAX_N) begin
         m_valid<=1;m_status<=1;m_row<=0;m_column<=0;m_data<=0;
         m_diagonal<=0;m_last<=1;m_tag<=c_tag;state<=HOLD;
       end else begin
         n<=c_dimension[NW-1:0];load_row<=0;load_col<=0;state<=LOAD;
       end
     end
     LOAD: if(s_valid && s_ready) begin
       if(load_col==load_row) begin
         if(load_row==n-1'b1) begin i<=0;k<=0;state<=PREP;end
         else begin load_row<=load_row+1'b1;load_col<=0;end
       end else load_col<=load_col+1'b1;
     end
     PREP: begin
       residual<=original_value <<< (2*FRAC);j<=0;
       state<=(k==0)?DECIDE:GET;
     end
     GET: begin
       op_a<=lower[address(i,j)];op_b<=lower[address(k,j)];op_d<=diagonal[j];
       state<=PAIR;
     end
     PAIR: begin pair_product<=op_a*op_b;state<=TRIPLE;end
     TRIPLE: begin triple_product<=pair_product*op_d;state<=ACCUM;end
     ACCUM: begin
       residual<=residual-widened_triple;
       if(j==k-1'b1) state<=DECIDE;
       else begin j<=j+1'b1;state<=GET;end
     end
     DECIDE: if(i==k) begin
       if(shifted_pivot<=0 || !fits(shifted_pivot)) begin
         m_valid<=1;m_status<=(shifted_pivot<=0)?2:3;
         m_row<=i;m_column<=k;m_data<=0;m_diagonal<=1;
         m_last<=1;m_tag<=tag;state<=HOLD;
       end else begin diagonal[k]<=shifted_pivot[DATA_W-1:0];state<=NEXT;end
     end else begin divisor<=diagonal_value <<< FRAC;state<=DIV_SEND;end
     DIV_SEND: if(div_s_ready) state<=DIV_WAIT;
     DIV_WAIT: if(div_m_valid) begin
       if(div_zero || div_overflow || !fits(div_result)) begin
         m_valid<=1;m_status<=3;m_row<=i;m_column<=k;m_data<=0;
         m_diagonal<=0;m_last<=1;m_tag<=tag;state<=HOLD;
       end else begin lower[address(i,k)]<=div_result[DATA_W-1:0];state<=NEXT;end
     end
     NEXT: begin
       if(i==n-1'b1) begin
         if(k==n-1'b1) begin out_row<=0;out_col<=0;state<=EMIT;end
         else begin k<=k+1'b1;i<=k+1'b1;state<=PREP;end
       end else begin i<=i+1'b1;state<=PREP;end
     end
     EMIT: begin
       m_valid<=1;m_status<=0;m_row<=out_row;m_column<=out_col;
       m_data<=(out_row==out_col)?diagonal[out_row]:lower[address(out_row,out_col)];
       m_diagonal<=(out_row==out_col);
       m_last<=(out_row==n-1'b1 && out_col==out_row);m_tag<=tag;state<=HOLD;
     end
     HOLD: if(m_valid && m_ready) begin
       m_valid<=0;
       if(m_last) state<=IDLE;
       else begin
         if(out_col==out_row) begin out_row<=out_row+1'b1;out_col<=0;end
         else out_col<=out_col+1'b1;
         state<=EMIT;
       end
     end
     default:state<=IDLE;
   endcase
 end
endmodule
