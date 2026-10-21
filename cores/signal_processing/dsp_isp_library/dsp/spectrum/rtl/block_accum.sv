// DSP-05 block accumulator: signed16 samples -> one record per complete
// block of N=2**log2n accepted samples. m_tdata={sum[31:0], mean[15:0]}.
// mean = RNE(sum, N) saturated to signed16 (unreachable; flag retained).
// Partial blocks are dropped on reset or an accepted legal config.
module block_accum #(
 parameter integer MAX_LOG2N=12
) (
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [47:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [3:0] cfg_log2n,
 output reg cfg_done,output reg cfg_error
);
 localparam [3:0] MAXL4=MAX_LOG2N;
 reg [3:0] log2n;
 reg signed [31:0] acc;
 reg [MAX_LOG2N-1:0] cnt;
 wire advance=rst_n && (!m_tvalid || m_tready);
 wire [MAX_LOG2N:0] blk_n={{MAX_LOG2N{1'b0}},1'b1}<<log2n;
 wire [MAX_LOG2N-1:0] block_last=blk_n[MAX_LOG2N-1:0]-1'b1;
 assign s_tready=advance && !cfg_valid;
 assign cfg_ready=rst_n && !m_tvalid;
 wire s_fire=s_tvalid && s_tready;
 wire last=cnt==block_last;
 wire signed [31:0] nsum=acc+s_tdata;
 function signed [31:0] rshift_rne;
  input signed [31:0] v;input [4:0] k;
  reg signed [31:0] q;reg [31:0] rem,half;
  begin
   q=v>>>k;rem=v&((32'd1<<k)-32'd1);half=32'd1<<(k-1'b1);
   if(rem>half || (rem==half && q[0]))q=q+32'd1;
   rshift_rne=q;
  end
 endfunction
 wire signed [31:0] mq=rshift_rne(nsum,{1'b0,log2n});
 wire signed [15:0] mean=mq>32'sd32767 ? 16'sh7fff :
                          mq< -32'sd32768 ? 16'sh8000 : mq[15:0];
 wire clip=mq>32'sd32767 || mq< -32'sd32768;
 always @(posedge clk) begin
  if(!rst_n) begin
   log2n<=4'd4;acc<=0;cnt<=0;
   m_tdata<=0;m_tuser<=0;m_tvalid<=0;cfg_done<=0;cfg_error<=0;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(advance) begin
    m_tvalid<=s_fire && last;
    if(s_fire) begin
     if(last) begin
      m_tdata<={nsum[31:0],mean};m_tuser<=clip;acc<=0;cnt<=0;
     end else begin
      acc<=nsum;cnt<=cnt+1'b1;
     end
    end
   end
   if(cfg_valid && cfg_ready) begin
    cfg_done<=1;
    if(cfg_log2n<4'd4 || cfg_log2n>MAXL4)cfg_error<=1;
    else begin log2n<=cfg_log2n;acc<=0;cnt<=0;end
   end
  end
 end
`ifndef SYNTHESIS
 initial if(MAX_LOG2N<4 || MAX_LOG2N>12)$fatal(1,"unsupported MAX_LOG2N");
`endif
endmodule
