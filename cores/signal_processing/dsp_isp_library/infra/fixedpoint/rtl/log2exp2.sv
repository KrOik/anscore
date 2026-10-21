// Shared fixed-point log2/exp2 via shift-add multiplicative normalization
// (Briggs pseudo-division). Table tab30[j] = round(log2(1+2^-j) * 2**30);
// at internal precision P the used entry is tab30[j] >> (30-P), matched by
// models/reference.py exactly. Internal precision P = FB+G.
//
// fp_log2_iter: input x unsigned IN_W (or signed when SIGNED_IN=1).
//   Normal range requires IN_W-1 <= P. Output y = log2(x) signed
//   Q(OUT_W-FB).FB with OUT_W = FB + $clog2(IN_W) + 1.
//   Abnormal input (x==0, or x<=0 when signed) -> y = OUT_MIN, m_tuser[0]=1.
// fp_exp2_iter: input xn signed Q(IW-FB).FB, output y = 2**(xn/2**FB)
//   unsigned Q(OUT_W-FRACO).FRACO. Overflow saturates with m_tuser[1]=clip;
//   result rounding to zero sets m_tuser[0]=under.
// Both are iterative: table steps j=1..P+2, one per clock. Latency P+4
// cycles from input transfer to earliest output transfer (abnormal log2
// input finishes in 3); one operation in flight. Pipelined variants are
// not provided; these are block-rate primitives for RMS/AGC/NLMS. Measured
// worst-case error at FB=12,G=6: log2 <=0.59 ulp of the 2^-FB output step,
// exp2 <=1.3e-5 relative plus output quantization (see SPEC.md).

module fp_log2_iter #(
 parameter integer IN_W=16,parameter integer FB=12,
 parameter integer G=6,parameter integer SIGNED_IN=0
)(
 input wire clk,rst_n,
 input wire [IN_W-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [FB+$clog2(IN_W):0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer P=FB+G;
 localparam integer J=P+3; // RUN finalizes at j==J, so steps j=1..J-1=P+2
 localparam integer OUT_W=FB+$clog2(IN_W)+1;
 localparam integer KW=$clog2(IN_W)+1;
 localparam IDLE=0,RUN=1,OUT=2;
 reg [1:0] state;reg [5:0] j;
 reg [P:0] m;reg [P:0] facc;reg [KW-1:0] k;reg abn;
 wire signed [IN_W-1:0] xs=s_tdata;
 wire abnormal=(SIGNED_IN!=0) ? (xs<=0) : (s_tdata==0);
 wire [IN_W-1:0] ux=abnormal ? {IN_W{1'b0}} : s_tdata;
 reg [KW-1:0] kc;integer bi;
 always @* begin kc=0;for(bi=0;bi<IN_W;bi=bi+1)if(ux[bi])kc=bi[KW-1:0];end
 function [31:0] tab30;input [5:0] jj;begin
  case(jj)
   1:tab30=628098702;2:tab30=345667660;3:tab30=182455581;4:tab30=93912511;
   5:tab30=47667823;6:tab30=24017256;7:tab30=12055174;8:tab30=6039314;
   9:tab30=3022600;10:tab30=1512037;11:tab30=756203;12:tab30=378148;
   13:tab30=189085;14:tab30=94546;15:tab30=47274;16:tab30=23637;
   17:tab30=11819;18:tab30=5909;19:tab30=2955;20:tab30=1477;
   21:tab30=739;22:tab30=369;23:tab30=185;24:tab30=92;
   25:tab30=46;26:tab30=23;27:tab30=12;28:tab30=6;
   29:tab30=3;30:tab30=1;31:tab30=1;default:tab30=0;
  endcase end
 endfunction
 wire [31:0] lj=tab30(j)>>(30-P);
 wire [P+1:0] tsum={1'b0,m}+({1'b0,m}>>j);
 wire take=tsum<{2'b10,{P{1'b0}}}; // < 2.0 in Q1.P
 wire m_free=!m_tvalid || m_tready;
 assign s_tready=rst_n && state==IDLE;
 // final value: log2(x)*2**P = (k+1)*2**P - facc, then RNE to FB bits
 wire [P+KW:0] val=({1'b0,k,{P{1'b0}}}+({{(P+KW){1'b0}},1'b1}<<P)) -
                  {{KW{1'b0}},facc};
 localparam integer RS=P-FB; // == G
 wire [P+KW:0] vq=val>>RS;
 wire [RS-1:0] vf=val[RS-1:0];
 wire vup=(vf>({{(RS-1){1'b0}},1'b1}<<(RS-1))) ||
          ((vf==({{(RS-1){1'b0}},1'b1}<<(RS-1))) && vq[0]);
 wire [OUT_W-1:0] yout=vq[OUT_W-1:0]+{{(OUT_W-1){1'b0}},vup};
 always @(posedge clk) begin
  if(!rst_n)begin state<=IDLE;m_tvalid<=0;j<=0;end
  else begin
   if(m_tready)m_tvalid<=1'b0;
   case(state)
    IDLE:if(s_tvalid)begin
     abn<=abnormal;k<=kc;
     m<=abnormal ? {(P+1){1'b0}} : ({{(P+1-IN_W){1'b0}},ux}<<(P-kc));
     facc<=0;j<=1;state<=RUN;
    end
    RUN:begin
     if(abn || j==J)begin
      if(m_free)begin
       m_tvalid<=1'b1;m_tdata<=abn ? {1'b1,{(OUT_W-1){1'b0}}} : yout;
       m_tuser<={1'b0,abn};state<=IDLE;
      end else state<=OUT;
     end else begin
      if(take)begin m<=tsum[P:0];facc<=facc+lj[P:0];end
      j<=j+1'b1;
     end
    end
    OUT:if(m_free)begin
     m_tvalid<=1'b1;m_tdata<=abn ? {1'b1,{(OUT_W-1){1'b0}}} : yout;
     m_tuser<={1'b0,abn};state<=IDLE;
    end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(IN_W<2 || FB<1 || FB>20 || G<2 || P<IN_W-1 || P>28 || SIGNED_IN<0 || SIGNED_IN>1)
   $fatal(1,"fp_log2_iter: unsupported static configuration");
 end
`endif
endmodule

module fp_exp2_iter #(
 parameter integer IW=16,parameter integer FB=12,parameter integer G=6,
 parameter integer OUT_W=28,parameter integer FRACO=12
)(
 input wire clk,rst_n,
 input wire [IW-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [OUT_W-1:0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer P=FB+G;
 localparam integer J=P+3; // RUN finalizes at j==J, so steps j=1..J-1=P+2
 localparam IDLE=0,RUN=1,OUT=2;
 reg [1:0] state;reg [5:0] j;
 reg signed [IW-FB-1:0] kr;reg [P-1:0] rem;reg [P+1:0] r;
 wire signed [IW-1:0] xs=s_tdata;
 function [31:0] tab30;input [5:0] jj;begin
  case(jj)
   1:tab30=628098702;2:tab30=345667660;3:tab30=182455581;4:tab30=93912511;
   5:tab30=47667823;6:tab30=24017256;7:tab30=12055174;8:tab30=6039314;
   9:tab30=3022600;10:tab30=1512037;11:tab30=756203;12:tab30=378148;
   13:tab30=189085;14:tab30=94546;15:tab30=47274;16:tab30=23637;
   17:tab30=11819;18:tab30=5909;19:tab30=2955;20:tab30=1477;
   21:tab30=739;22:tab30=369;23:tab30=185;24:tab30=92;
   25:tab30=46;26:tab30=23;27:tab30=12;28:tab30=6;
   29:tab30=3;30:tab30=1;31:tab30=1;default:tab30=0;
  endcase end
 endfunction
 wire [31:0] lj=tab30(j)>>(30-P);
 wire m_free=!m_tvalid || m_tready;
 assign s_tready=rst_n && state==IDLE;
 // result: y = r * 2**(k+FRACO-P); left path saturates, right path RNE
 wire signed [15:0] s=kr+FRACO-P;
 wire [OUT_W-1:0] lmax={OUT_W{1'b1}};
 wire [OUT_W+P+1:0] r_ext={{OUT_W{1'b0}},r};
 wire [OUT_W+P+1:0] lsh=r_ext<<s;
 wire [OUT_W+P+1:0] thr={1'b0,lmax}>>>s;
 wire clip_pos=(s>=0) && (r_ext>thr);
 wire [OUT_W-1:0] qpos=clip_pos ? lmax : lsh[OUT_W-1:0];
 // right-shift path: -s is bounded to P+2 by the parameter constraint
 wire signed [15:0] negs=(s<0) ? -s : 16'sd0;
 wire [7:0] rsh_amt=(negs>P+2) ? (P+2) : negs[7:0];
 wire [P+1:0] rq=r>>rsh_amt;
 wire [P+1:0] rmask=(rsh_amt>0) ? (r & ({(P+2){1'b1}}>>(P+2-rsh_amt))) : {(P+2){1'b0}};
 wire rup=(rsh_amt>0) && ((rmask>({{(P+1){1'b0}},1'b1}<<(rsh_amt-1))) ||
          ((rmask==({{(P+1){1'b0}},1'b1}<<(rsh_amt-1))) && rq[0]));
 wire [P+2:0] qsum={1'b0,rq}+{{(P+2){1'b0}},rup};
 wire clip_neg;wire [OUT_W-1:0] qneg;
 generate if(OUT_W>P+2) begin:g_noclip
  assign clip_neg=1'b0;
  assign qneg=qsum;
 end else begin:g_clip
  localparam [P+2:0] NMAX={{(P+3-OUT_W){1'b0}},{OUT_W{1'b1}}};
  assign clip_neg=(s<0) && (qsum>NMAX);
  assign qneg=clip_neg ? lmax : qsum[OUT_W-1:0];
 end endgenerate
 wire clip=clip_pos || clip_neg;
 wire [OUT_W-1:0] qfinal=(s>=0) ? qpos : qneg;
 wire under=(qfinal==0);
 always @(posedge clk) begin
  if(!rst_n)begin state<=IDLE;m_tvalid<=0;j<=0;end
  else begin
   if(m_tready)m_tvalid<=1'b0;
   case(state)
    IDLE:if(s_tvalid)begin
     kr<=xs[IW-1:FB];rem<={xs[FB-1:0],{G{1'b0}}};r<={2'b01,{P{1'b0}}};
     j<=1;state<=RUN;
    end
    RUN:begin
     if(j==J)begin
      if(m_free)begin
       m_tvalid<=1'b1;m_tdata<=qfinal;m_tuser<={under,clip};state<=IDLE;
      end else state<=OUT;
     end else begin
      if(rem>=lj)begin rem<=rem-lj[P-1:0];r<=r+(r>>j);end
      j<=j+1'b1;
     end
    end
    OUT:if(m_free)begin
     m_tvalid<=1'b1;m_tdata<=qfinal;m_tuser<={under,clip};state<=IDLE;
    end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(IW<4 || FB<1 || FB>=IW-1 || G<2 || P>28 || OUT_W<4 || FRACO<0 ||
     FRACO>=OUT_W || (1<<(IW-FB-1))>FRACO+2)
   $fatal(1,"fp_exp2_iter: unsupported static configuration");
 end
`endif
endmodule
