// Exact raster spatial moments, synchronous reset, CE-qualified transfers.
module image_spatial_moments #(
 parameter integer WIDTH=16, HEIGHT=16, BITS=8, MASK_ENABLE=0
)(
 input wire clk,rst_n,ce,
 input wire [BITS-1:0] s_pixel,
 input wire s_mask,s_valid,s_sof,s_eol,binary_mode,
 output wire s_ready,
 output reg [63:0] m00,m10,m01,m20,m11,m02,
 output reg [31:0] centroid_x_q16,centroid_y_q16,
 output reg centroid_valid,m_valid,
 input wire m_ready,
 output wire busy,
 output reg done,
 output reg [3:0] error_code
);
 localparam [63:0] PIXELS=64'(WIDTH)*64'(HEIGHT);
 initial begin
  if(WIDTH<1 || HEIGHT<1 || WIDTH>4096 || HEIGHT>4096 || PIXELS>65536 ||
     BITS<8 || BITS>12 || (MASK_ENABLE!=0 && MASK_ENABLE!=1))
   $fatal(1,"invalid moments parameters");
 end
 localparam CAP=0,PREPX=1,DIVX=2,PREPY=3,DIVY=4,OUT=5;
 reg [2:0] state;
 reg [11:0] x,y;
 reg active,binary_q;
 reg [79:0] quotient;
 reg [64:0] remainder;
 reg [6:0] step;
 wire use_binary=active ? binary_q : binary_mode;
 wire [11:0] weight=(MASK_ENABLE && !s_mask) ? 12'd0 :
                           (use_binary ? {11'd0,|s_pixel} : s_pixel);
 // Explicit operand sizes prevent expression-context truncation.
 wire [23:0] xx={12'd0,x}*{12'd0,x};
 wire [23:0] xy={12'd0,x}*{12'd0,y};
 wire [23:0] yy={12'd0,y}*{12'd0,y};
 wire [35:0] wx={24'd0,weight}*{24'd0,x};
 wire [35:0] wy={24'd0,weight}*{24'd0,y};
 wire [35:0] wxx={24'd0,weight}*{12'd0,xx};
 wire [35:0] wxy={24'd0,weight}*{12'd0,xy};
 wire [35:0] wyy={24'd0,weight}*{12'd0,yy};
 wire [64:0] trial={remainder[63:0],quotient[79]};
 wire subtract=trial>={1'b0,m00};
 wire [79:0] next_quotient={quotient[78:0],subtract};
 assign s_ready=(state==CAP);
 assign busy=active || state!=CAP;
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=CAP; x<=0; y<=0; active<=0; binary_q<=0;
   m00<=0;m10<=0;m01<=0;m20<=0;m11<=0;m02<=0;
   centroid_x_q16<=0;centroid_y_q16<=0;centroid_valid<=0;
   m_valid<=0;done<=0;error_code<=0;
   quotient<=0;remainder<=0;step<=0;
  end else if(ce) begin
   done<=0;
   case(state)
    CAP: if(s_valid) begin
     if(s_sof!=(x==0 && y==0) || s_eol!=(x==WIDTH-1)) begin
      x<=0;y<=0;active<=0;done<=1;error_code<=1;
      m_valid<=0;centroid_valid<=0;
      m00<=0;m10<=0;m01<=0;m20<=0;m11<=0;m02<=0;
     end else begin
      if(!active) begin
       binary_q<=binary_mode;active<=1;error_code<=0;centroid_valid<=0;
       m00<=weight;m10<=wx;m01<=wy;m20<=wxx;m11<=wxy;m02<=wyy;
      end else begin
       m00<=m00+weight;m10<=m10+wx;m01<=m01+wy;
       m20<=m20+wxx;m11<=m11+wxy;m02<=m02+wyy;
      end
      if(x==WIDTH-1) begin
       x<=0;
       if(y==HEIGHT-1) begin y<=0;state<=PREPX;end
       else y<=y+1'b1;
      end else x<=x+1'b1;
     end
    end
    PREPX: begin
     if(m00==0) begin
      centroid_x_q16<=0;centroid_y_q16<=0;centroid_valid<=0;
      m_valid<=1;state<=OUT;
     end else begin
      quotient<={m10,16'b0};remainder<=0;step<=0;state<=DIVX;
      centroid_valid<=1;
     end
    end
    DIVX,DIVY: begin
     quotient<=next_quotient;
     remainder<=subtract ? trial-{1'b0,m00} : trial;
     if(step==79) begin
      if(state==DIVX) begin centroid_x_q16<=next_quotient[31:0];state<=PREPY;end
      else begin centroid_y_q16<=next_quotient[31:0];m_valid<=1;state<=OUT;end
     end else step<=step+1'b1;
    end
    PREPY: begin quotient<={m01,16'b0};remainder<=0;step<=0;state<=DIVY;end
    OUT: if(m_ready) begin m_valid<=0;active<=0;done<=1;state<=CAP;end
    default: begin state<=CAP;active<=0;x<=0;y<=0;error_code<=2;done<=1;m_valid<=0;end
   endcase
  end
 end
endmodule
