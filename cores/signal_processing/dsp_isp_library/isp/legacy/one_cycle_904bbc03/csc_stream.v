// Full-rate color converter. Configuration commits on accepted SOF only.
module csc_stream #(parameter BITS=8)(
 input wire clk, rst_n,
 input wire [3*BITS-1:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 output reg [3*BITS-1:0] m_tdata,
 output reg m_tvalid,m_tuser,m_tlast,
 input wire m_tready,
 input wire cfg_valid,
 output wire cfg_ready,
 input wire [1:0] cfg_mode,
 input wire cfg_standard,cfg_limited,
 output reg cfg_error
);
 reg [3:0] active,pending;
 reg pending_valid;
 wire fire=s_tvalid && s_tready;
 wire commit=fire && s_tuser && pending_valid;
 assign cfg_ready=!pending_valid || commit;
 assign s_tready=!m_tvalid || m_tready;
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
 // Explicit shift-add multiplication prevents accidental Gowin DSP mapping.
 function signed [31:0] product;
 input signed [11:0] x;
 input signed [18:0] c;
 reg signed [31:0] xx,total;
 integer k;
 begin
 xx=x; total=0;
 for(k=0;k<18;k=k+1) if(c[k]) total=total+(xx<<<k);
 if(c[18]) total=total-(xx<<<18);
 product=total;
 end
 endfunction
 wire signed [11:0] x0=$signed({1'b0,s_tdata[3*BITS-1:2*BITS]})+o0;
 wire signed [11:0] x1=$signed({1'b0,s_tdata[2*BITS-1:BITS]})+o1;
 wire signed [11:0] x2=$signed({1'b0,s_tdata[BITS-1:0]})+o2;
 wire signed [31:0] bb0=b0,bb1=b1,bb2=b2;
 wire signed [31:0] a0=product(x0,c00)+product(x1,c01)+product(x2,c02)+(bb0<<<16);
 wire signed [31:0] a1=product(x0,c10)+product(x1,c11)+product(x2,c12)+(bb1<<<16);
 wire signed [31:0] a2=product(x0,c20)+product(x1,c21)+product(x2,c22)+(bb2<<<16);
 function [BITS-1:0] quantize;
 input signed [31:0] a;
 reg signed [31:0] q;
 begin
 if(a<0) q=-(((-a)+32768)>>>16); else q=(a+32768)>>>16;
 if(q<0) quantize=0; else if(q>((1<<BITS)-1)) quantize={BITS{1'b1}}; else quantize=q[BITS-1:0];
 end
 endfunction
 always @(posedge clk) begin
 if(!rst_n) begin
 active<=0;pending<=0;pending_valid<=0;cfg_error<=0;
 m_tvalid<=0;m_tdata<=0;m_tuser<=0;m_tlast<=0;
 end else begin
 cfg_error<=0;
 if(commit) begin active<=pending;pending_valid<=0;end
 if(cfg_valid && cfg_ready) begin
 if(cfg_mode==3) cfg_error<=1;
 else begin pending<={cfg_mode,cfg_standard,cfg_limited};pending_valid<=1;end
 end
 if(s_tready) begin
 m_tvalid<=s_tvalid;
 if(s_tvalid) begin m_tdata<={quantize(a0),quantize(a1),quantize(a2)};m_tuser<=s_tuser;m_tlast<=s_tlast;end
 end
 end
 end
 initial begin if(BITS!=8 && BITS!=10) $fatal(1,"BITS must be 8 or 10");end
endmodule
