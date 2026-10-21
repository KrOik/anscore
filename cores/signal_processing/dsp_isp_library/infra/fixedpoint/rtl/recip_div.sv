// Shared signed fixed-point division: q = sat_OUT_W(RNE(a * 2**FB / b)).
// s_tdata = {b,a} packed: [AW-1:0]=a, [AW+BW-1:AW]=b, both two's complement.
// m_tuser = {div0, clip}: b==0 -> q = a<0 ? OUT_MIN : OUT_MAX, flags 2'b11.
// Reciprocal of b in Q(FB) is fp_div with a == 1 (q = RNE(2**FB / b)).
// fp_div_iter: one quotient bit per clock. Worst-case latency AW+FB+1 cycles
//   from input transfer to earliest output transfer (b==0 finishes in 2);
//   one operation in flight, so initiation interval equals that latency.
// fp_div_pipe: fully unrolled digit recurrence, II=1, latency AW+FB+1 cycles.

module fp_div_iter #(
 parameter integer AW=16,parameter integer BW=16,
 parameter integer FB=15,parameter integer OUT_W=18
)(
 input wire clk,rst_n,
 input wire [AW+BW-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [OUT_W-1:0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer N=AW+FB;
 localparam IDLE=0,RUN=1,OUT=2;
 reg [1:0] state;reg [7:0] cnt;
 reg [BW:0] rem;reg [N-1:0] quot;reg [BW-1:0] ub;
 reg [AW-1:0] ua_r;reg sgn,asign,d0;
 wire signed [AW-1:0] a_in=s_tdata[AW-1:0];
 wire signed [BW-1:0] b_in=s_tdata[AW+BW-1:AW];
 wire [AW-1:0] ua=a_in[AW-1] ? (~a_in+1'b1) : a_in;
 wire [BW-1:0] ubin=b_in[BW-1] ? (~b_in+1'b1) : b_in;
 wire m_free=!m_tvalid || m_tready;
 assign s_tready=rst_n && state==IDLE;
 // numerator is ua_r<<FB; iteration cnt consumes bit N-1-cnt = ua_r[AW-1-cnt]
 // for cnt<AW else 0
 wire nbit=(cnt<AW) ? ua_r[AW-1-cnt] : 1'b0;
 wire [BW:0] rem_sh={rem[BW-1:0],nbit};
 wire ge=rem_sh>={1'b0,ub};
 wire [BW:0] rem_n=ge ? rem_sh-{1'b0,ub} : rem_sh;
 wire [N-1:0] quot_n={quot[N-2:0],ge};
 // final RNE + sign + saturation, evaluated on the last RUN cycle
 wire [BW+1:0] rem2={rem_n,1'b0};
 wire [BW+1:0] ub2={2'b00,ub};
 wire up=rem2>ub2 || (rem2==ub2 && quot_n[0]);
 wire [N:0] qr={1'b0,quot_n}+{{N{1'b0}},up};
 wire signed [N:0] sq=sgn ? -$signed(qr) : $signed(qr);
 localparam signed [N:0] OMAX={{(N-OUT_W+2){1'b0}},{(OUT_W-1){1'b1}}};
 localparam signed [N:0] OMIN={{(N-OUT_W+2){1'b1}},{(OUT_W-1){1'b0}}};
 wire clip=d0 || sq>OMAX || sq<OMIN;
 wire signed [OUT_W-1:0] result=d0 ? (asign ? OMIN[OUT_W-1:0] : OMAX[OUT_W-1:0]) :
   clip ? (sq>OMAX ? OMAX[OUT_W-1:0] : OMIN[OUT_W-1:0]) : sq[OUT_W-1:0];
 always @(posedge clk) begin
  if(!rst_n)begin state<=IDLE;m_tvalid<=0;cnt<=0;end
  else begin
   if(m_tready)m_tvalid<=1'b0;
   case(state)
    IDLE:if(s_tvalid)begin
     ua_r<=ua;ub<=ubin;
     sgn<=a_in[AW-1]^b_in[BW-1];asign<=a_in[AW-1];d0<=(b_in==0);
     rem<=0;quot<=0;cnt<=0;state<=RUN;
    end
    RUN:begin
     if(d0 || cnt==N-1)begin
      if(m_free)begin
       m_tvalid<=1'b1;m_tdata<=result;m_tuser<={d0,clip};state<=IDLE;
      end else state<=OUT;
     end else begin
      rem<=rem_n;quot<=quot_n;cnt<=cnt+1'b1;
     end
    end
    OUT:if(m_free)begin
     m_tvalid<=1'b1;m_tdata<=result;m_tuser<={d0,clip};state<=IDLE;
    end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(AW<2 || BW<2 || FB<0 || FB>24 || N>255 || OUT_W<2 || OUT_W>N+1)
   $fatal(1,"fp_div_iter: unsupported static configuration");
 end
`endif
endmodule

module fp_div_pipe #(
 parameter integer AW=16,parameter integer BW=16,
 parameter integer FB=15,parameter integer OUT_W=18
)(
 input wire clk,rst_n,
 input wire [AW+BW-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [OUT_W-1:0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 localparam integer N=AW+FB;
 wire m_free=!m_tvalid || m_tready;
 wire advance=m_free;
 assign s_tready=rst_n && advance;
 wire signed [AW-1:0] a_in=s_tdata[AW-1:0];
 wire signed [BW-1:0] b_in=s_tdata[AW+BW-1:AW];
 wire [AW-1:0] ua=a_in[AW-1] ? (~a_in+1'b1) : a_in;
 wire [BW-1:0] ubin=b_in[BW-1] ? (~b_in+1'b1) : b_in;
 // stage s computes quotient bit N-1-s; numerator is ua<<FB so the consumed
 // bit is ua[AW-1-s] for s<AW else 0. Each stage carries remainder, partial
 // quotient, divisor, magnitude numerator, signs and the div0 flag.
 reg vld[0:N-1];
 reg [BW:0] rem_s[0:N-1];reg [N-1:0] q_s[0:N-1];
 reg [BW-1:0] ub_s[0:N-1];reg [AW-1:0] ua_s[0:N-1];
 reg sgn_s[0:N-1],asg_s[0:N-1],d0_s[0:N-1];
 // stage 0 computes from the freshly accepted operands
 wire ge0={{BW{1'b0}},ua[AW-1]}>={1'b0,ubin};
 always @(posedge clk) begin
  if(!rst_n)vld[0]<=1'b0;
  else if(advance)begin
   vld[0]<=s_tvalid;
   if(s_tvalid)begin
    rem_s[0]<=ge0 ? {1'b0,ua[AW-1]}-{1'b0,ubin} : {1'b0,ua[AW-1]};
    q_s[0]<={{(N-1){1'b0}},ge0};ub_s[0]<=ubin;ua_s[0]<=ua;
    sgn_s[0]<=a_in[AW-1]^b_in[BW-1];asg_s[0]<=a_in[AW-1];d0_s[0]<=(b_in==0);
   end
  end
 end
 genvar gs;
 generate for(gs=1;gs<N;gs=gs+1) begin:stage
  wire [AW-1:0] shu=ua_s[gs-1]<<gs; // ua bit AW-1-gs lands on the MSB
  wire nbit=(gs<AW) && shu[AW-1];
  wire [BW:0] rsh={rem_s[gs-1][BW-1:0],nbit};
  wire ge=rsh>={1'b0,ub_s[gs-1]};
  always @(posedge clk) begin
   if(!rst_n)vld[gs]<=1'b0;
   else if(advance)begin
    vld[gs]<=vld[gs-1];
    if(vld[gs-1])begin
     rem_s[gs]<=ge ? rsh-{1'b0,ub_s[gs-1]} : rsh;
     q_s[gs]<={q_s[gs-1][N-2:0],ge};
     ub_s[gs]<=ub_s[gs-1];ua_s[gs]<=ua_s[gs-1];
     sgn_s[gs]<=sgn_s[gs-1];asg_s[gs]<=asg_s[gs-1];d0_s[gs]<=d0_s[gs-1];
    end
   end
  end
 end endgenerate
 // final RNE + sign + saturation stage writes the output slot
 wire [BW+1:0] rem2={rem_s[N-1],1'b0};
 wire [BW+1:0] ub2={2'b00,ub_s[N-1]};
 wire up=rem2>ub2 || (rem2==ub2 && q_s[N-1][0]);
 wire [N:0] qr={1'b0,q_s[N-1]}+{{N{1'b0}},up};
 wire signed [N:0] sq=sgn_s[N-1] ? -$signed(qr) : $signed(qr);
 localparam signed [N:0] OMAX={{(N-OUT_W+2){1'b0}},{(OUT_W-1){1'b1}}};
 localparam signed [N:0] OMIN={{(N-OUT_W+2){1'b1}},{(OUT_W-1){1'b0}}};
 wire clip=d0_s[N-1] || sq>OMAX || sq<OMIN;
 wire signed [OUT_W-1:0] result=d0_s[N-1] ?
   (asg_s[N-1] ? OMIN[OUT_W-1:0] : OMAX[OUT_W-1:0]) :
   clip ? (sq>OMAX ? OMAX[OUT_W-1:0] : OMIN[OUT_W-1:0]) : sq[OUT_W-1:0];
 always @(posedge clk) begin
  if(!rst_n)m_tvalid<=1'b0;
  else if(advance)begin
   m_tvalid<=vld[N-1];
   if(vld[N-1])begin m_tdata<=result;m_tuser<={d0_s[N-1],clip};end
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(AW<2 || BW<2 || FB<0 || FB>24 || OUT_W<2 || OUT_W>N+1)
   $fatal(1,"fp_div_pipe: unsupported static configuration");
 end
`endif
endmodule
