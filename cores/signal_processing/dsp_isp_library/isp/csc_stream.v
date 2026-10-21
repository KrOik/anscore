// Isolated candidate: four registered arithmetic stages, II=1.
// Global stall freezes all payload/sideband stages; no combinational arithmetic
// path crosses more than one partial product, product merge, row sum or quantizer.
module csc_stream #(parameter BITS=8)(
 input wire clk,rst_n,
 input wire [3*BITS-1:0] s_tdata,input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,output reg [3*BITS-1:0] m_tdata,
 output wire m_tvalid,m_tuser,m_tlast,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,input wire [1:0] cfg_mode,
 input wire cfg_standard,cfg_limited,output reg cfg_error
);
 reg [3:0] active,pending;
 reg pending_valid;
 reg [3:0] valid_pipe,user_pipe,last_pipe;
 wire advance=!valid_pipe[3] || m_tready;
 assign s_tready=advance;
 assign m_tvalid=valid_pipe[3];
 assign m_tuser=user_pipe[3];
 assign m_tlast=last_pipe[3];
 wire fire=s_tvalid && s_tready;
 wire commit=fire && s_tuser && pending_valid;
 assign cfg_ready=!pending_valid || commit;
 wire [3:0] selected=(s_tuser && pending_valid)?pending:active;
 wire [1:0] mode=selected[3:2];
 wire standard=selected[1],limited=selected[0];
 reg signed [18:0] c00,c01,c02,c10,c11,c12,c20,c21,c22;
 reg signed [11:0] o0,o1,o2,b0,b1,b2;
 always @* begin
 c00=0;c01=0;c02=0;c10=0;c11=0;c12=0;c20=0;c21=0;c22=0;
 o0=0;o1=0;o2=0;b0=0;b1=0;b2=0;
 `include "csc_coeffs.vh"
 end
 wire signed [11:0] x[0:2];
 assign x[0]=$signed({1'b0,s_tdata[3*BITS-1:2*BITS]})+o0;
 assign x[1]=$signed({1'b0,s_tdata[2*BITS-1:BITS]})+o1;
 assign x[2]=$signed({1'b0,s_tdata[BITS-1:0]})+o2;
 wire signed [18:0] c[0:8];
 assign c[0]=c00;assign c[1]=c01;assign c[2]=c02;
 assign c[3]=c10;assign c[4]=c11;assign c[5]=c12;
 assign c[6]=c20;assign c[7]=c21;assign c[8]=c22;
 function signed [31:0] low_product;
 input signed [11:0] x;input signed [18:0] c;
 reg signed [31:0] xx,total;integer k;
 begin xx=x;total=0;for(k=0;k<9;k=k+1) if(c[k]) total=total+(xx<<<k);low_product=total;end
 endfunction
 function signed [31:0] high_product;
 input signed [11:0] x;input signed [18:0] c;
 reg signed [31:0] xx,total;integer k;
 begin xx=x;total=0;for(k=9;k<18;k=k+1) if(c[k]) total=total+(xx<<<k);
 if(c[18]) total=total-(xx<<<18);high_product=total;end
 endfunction
 reg signed [31:0] low_p[0:8],high_p[0:8],products[0:8];
 wire signed [31:0] low_comb[0:8],high_comb[0:8];
 genvar g;
 generate for(g=0;g<9;g=g+1) begin: partial_product_wires
 assign low_comb[g]=low_product(x[g%3],c[g]);
 assign high_comb[g]=high_product(x[g%3],c[g]);
 end endgenerate
 reg signed [31:0] bias1[0:2],bias2[0:2],sums[0:2];
 wire signed [31:0] bb0=b0,bb1=b1,bb2=b2;
 function [BITS-1:0] quantize;
 input signed [31:0] a;reg signed [31:0] q;
 begin
 if(a<0) q=-(((-a)+32768)>>>16);else q=(a+32768)>>>16;
 if(q<0) quantize=0;else if(q>((1<<BITS)-1)) quantize={BITS{1'b1}};else quantize=q[BITS-1:0];
 end
 endfunction
 integer i;
 always @(posedge clk) begin
 if(!rst_n) begin
 active<=0;pending<=0;pending_valid<=0;cfg_error<=0;
 valid_pipe<=0;user_pipe<=0;last_pipe<=0;m_tdata<=0;
 end else begin
 cfg_error<=0;
 if(commit) begin active<=pending;pending_valid<=0;end
 if(cfg_valid && cfg_ready) begin
 if(cfg_mode==3) cfg_error<=1;
 else begin pending<={cfg_mode,cfg_standard,cfg_limited};pending_valid<=1;end
 end
 if(advance) begin
 valid_pipe<={valid_pipe[2:0],s_tvalid};
 user_pipe<={user_pipe[2:0],s_tuser};last_pipe<={last_pipe[2:0],s_tlast};
 // stage1: two independent coefficient halves.
 if(s_tvalid) begin
 for(i=0;i<9;i=i+1) begin low_p[i]<=low_comb[i];high_p[i]<=high_comb[i];end
 bias1[0]<=bb0<<<16;bias1[1]<=bb1<<<16;bias1[2]<=bb2<<<16;
 end
 // stage2: exact signed product and delayed bias.
 if(valid_pipe[0]) begin
 for(i=0;i<9;i=i+1) products[i]<=low_p[i]+high_p[i];
 for(i=0;i<3;i=i+1) bias2[i]<=bias1[i];
 end
 // stage3: complete row accumulation without intermediate quantization.
 if(valid_pipe[1]) for(i=0;i<3;i=i+1) sums[i]<=products[3*i]+products[3*i+1]+products[3*i+2]+bias2[i];
 // stage4: only numerical quantization boundary.
 if(valid_pipe[2]) m_tdata<={quantize(sums[0]),quantize(sums[1]),quantize(sums[2])};
 end
 end
 end
 initial begin if(BITS!=8 && BITS!=10) $fatal(1,"BITS must be 8 or 10");end
endmodule
