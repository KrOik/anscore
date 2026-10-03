// DSP-05 window multiplier: unity/Hann/Hamming/Blackman/custom-table.
// signed16 Q1.15 in -> signed16 Q1.15 out, II=1 global-stall pipeline.
// See SPEC.md for formats, coherent gain, scaling and config contract.
module window_mult #(
 parameter integer MAX_LOG2N=12
) (
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg signed [15:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [3:0] cfg_log2n,input wire [2:0] cfg_window,
 input wire signed [4:0] cfg_shift,
 output reg cfg_done,output reg cfg_error,
 input wire signed [17:0] coe_tdata,input wire coe_tvalid,output wire coe_tready
);
 localparam integer MAXN=1<<MAX_LOG2N;
 localparam [3:0] MAXL4=MAX_LOG2N;
 // active configuration
 reg [3:0] log2n;reg[2:0] wtype;reg signed [4:0] shift;
 reg [MAX_LOG2N-1:0] index;
 reg [MAX_LOG2N:0] up_count;
 // pipeline registers (all stages advance together)
 reg v1,v2,v3,v4;
 reg signed [15:0] x1,x2,x3;
 reg [2:0] wt1,wt2;
 reg signed [4:0] sh1,sh2,sh3,sh4;
 reg sgn1a,sgn1b;
 reg signed [17:0] c1_2,c2_2,cw_2;
 reg signed [17:0] w3;
 reg signed [33:0] prod4;
 wire pipe_active=v1|v2|v3|v4;
 wire advance=rst_n && (!m_tvalid || m_tready);
 wire [MAX_LOG2N:0] up_limit={{MAX_LOG2N{1'b0}},1'b1}<<log2n;
 wire [MAX_LOG2N-1:0] block_last=up_limit[MAX_LOG2N-1:0]-1'b1;
 wire table_ok=(wtype!=3'd4)||(up_count>=up_limit);
 assign s_tready=advance && table_ok && !cfg_valid;
 assign cfg_ready=rst_n && !m_tvalid && !pipe_active;
 assign coe_tready=rst_n && !m_tvalid && !pipe_active && !cfg_valid
                   && !(s_tvalid && s_tready) && up_count<up_limit;
 wire s_fire=s_tvalid && s_tready;
 wire coe_fire=coe_tvalid && coe_tready;
 // cosine phases: index n -> theta = n*4096/N, 2*theta mod 4096
 wire [11:0] index12=index;
 wire [11:0] ph=index12<<(12-log2n);
 wire [11:0] ph2=ph<<1;
 // quarter-wave addressing: idx=ph[10]?1024-r:r, sign=ph[11]^ph[10]
 wire [10:0] addra=ph[10] ? 11'd1024-{1'b0,ph[9:0]} : {1'b0,ph[9:0]};
 wire [10:0] addrb=ph2[10] ? 11'd1024-{1'b0,ph2[9:0]} : {1'b0,ph2[9:0]};
 wire sgna=ph[11]^ph[10],sgnb=ph2[11]^ph2[10];
 wire signed [17:0] da,db;
 window_cos_rom urom(.clk(clk),.en(advance),.addra(addra),.douta(da),
                     .addrb(addrb),.doutb(db));
 // uploaded custom table RAM
 reg signed [17:0] tram[0:MAXN-1];
 reg signed [17:0] tram_dout;
 always @(posedge clk) begin
  if(coe_fire)tram[up_count[MAX_LOG2N-1:0]]<=coe_tdata;
  if(advance)tram_dout<=tram[index];
 end
 // window constant selection (signed18 Q3.15)
 reg signed [17:0] a0,a1,a2;
 always @* begin
  case(wt2)
   3'd0:begin a0=18'sd32768;a1=18'sd0;a2=18'sd0;end
   3'd1:begin a0=18'sd16384;a1=18'sd16384;a2=18'sd0;end
   3'd2:begin a0=18'sd17695;a1=18'sd15073;a2=18'sd0;end
   3'd3:begin a0=18'sd13763;a1=18'sd16384;a2=18'sd2621;end
   default:begin a0=18'sd0;a1=18'sd0;a2=18'sd0;end
  endcase
 end
 wire signed [35:0] a0e={{18{a0[17]}},a0};
 wire signed [35:0] p1=a1*c1_2;
 wire signed [35:0] p2=a2*c2_2;
 wire signed [35:0] wnum=(a0e<<<15)-p1+p2;
 // arithmetic right shift with round-nearest-ties-even, v signed36, k 1..30
 function signed [35:0] rshift_rne;
  input signed [35:0] v;input [5:0] k;
  reg signed [35:0] q;reg [35:0] rem,half;
  begin
   q=v>>>k;rem=v&((36'd1<<k)-36'd1);half=36'd1<<(k-1'b1);
   if(rem>half || (rem==half && q[0]))q=q+36'd1;
   rshift_rne=q;
  end
 endfunction
 wire signed [35:0] wq=rshift_rne(wnum,6'd15);
 wire signed [17:0] w_named=wq>36'sd131071 ? 18'sd131071 :
                            wq< -36'sd131072 ? -18'sd131072 : wq[17:0];
 wire signed [35:0] prod4e={{2{prod4[33]}},prod4};
 wire [5:0] out_k=6'd15+$signed({sh4[4],sh4});
 wire signed [35:0] oq=rshift_rne(prod4e,out_k);
 wire signed [15:0] out_data=oq>36'sd32767 ? 16'sh7fff :
                             oq< -36'sd32768 ? 16'sh8000 : oq[15:0];
 wire out_clip=oq>36'sd32767 || oq< -36'sd32768;
 always @(posedge clk) begin
  if(!rst_n) begin
   log2n<=4'd4;wtype<=3'd0;shift<=5'sd0;index<=0;up_count<=0;
   v1<=0;v2<=0;v3<=0;v4<=0;x1<=0;x2<=0;x3<=0;
   wt1<=0;wt2<=0;sh1<=0;sh2<=0;sh3<=0;sh4<=0;sgn1a<=0;sgn1b<=0;
   c1_2<=0;c2_2<=0;cw_2<=0;w3<=0;prod4<=0;
   m_tdata<=0;m_tuser<=0;m_tvalid<=0;cfg_done<=0;cfg_error<=0;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(advance) begin
    m_tvalid<=v4;
    if(v4)begin m_tdata<=out_data;m_tuser<=out_clip;end
    v4<=v3;
    if(v3)begin prod4<=x3*w3;sh4<=sh3;end
    v3<=v2;
    if(v2)begin w3<=wt2==3'd4 ? cw_2 : w_named;x3<=x2;sh3<=sh2;end
    v2<=v1;
    if(v1)begin
     c1_2<=sgn1a ? -da : da;c2_2<=sgn1b ? -db : db;cw_2<=tram_dout;
     x2<=x1;wt2<=wt1;sh2<=sh1;
    end
    v1<=s_fire;
    if(s_fire)begin
     x1<=s_tdata;wt1<=wtype;sh1<=shift;sgn1a<=sgna;sgn1b<=sgnb;
     index<=index==block_last ? {MAX_LOG2N{1'b0}} : index+1'b1;
    end
   end
   if(coe_fire)up_count<=up_count+1'b1;
   if(cfg_valid && cfg_ready) begin
    cfg_done<=1;
    if(cfg_log2n<4'd4 || cfg_log2n>MAXL4 || cfg_window>3'd4
       || cfg_shift< -5'sd8) begin
     cfg_error<=1;
    end else begin
     log2n<=cfg_log2n;wtype<=cfg_window;shift<=cfg_shift;
     index<=0;up_count<=0;
    end
   end
  end
 end
`ifndef SYNTHESIS
 initial if(MAX_LOG2N<4 || MAX_LOG2N>12)$fatal(1,"unsupported MAX_LOG2N");
`endif
endmodule
