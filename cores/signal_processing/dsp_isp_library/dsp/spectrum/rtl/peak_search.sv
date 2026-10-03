// DSP-05 peak search: unsigned32 bins -> one record per complete block of
// N=2**log2n accepted samples. m_tdata={index[15:0], magnitude[31:0]}.
// Earliest index wins magnitude ties. m_tuser = threshold met
// (!thr_en || magnitude >= threshold). Partial blocks dropped on
// reset or an accepted legal config.
module peak_search #(
 parameter integer MAX_LOG2N=12
) (
 input wire clk,rst_n,
 input wire [31:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [47:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [3:0] cfg_log2n,input wire [1:0] cfg_thr_en,
 input wire [31:0] cfg_threshold,
 output reg cfg_done,output reg cfg_error
);
 localparam [3:0] MAXL4=MAX_LOG2N;
 reg [3:0] log2n;
 reg thr_en;
 reg [31:0] threshold;
 reg [31:0] maxv;
 reg [15:0] maxi;
 reg [MAX_LOG2N-1:0] cnt;
 wire advance=rst_n && (!m_tvalid || m_tready);
 wire [MAX_LOG2N:0] blk_n={{MAX_LOG2N{1'b0}},1'b1}<<log2n;
 wire [MAX_LOG2N-1:0] block_last=blk_n[MAX_LOG2N-1:0]-1'b1;
 assign s_tready=advance && !cfg_valid;
 assign cfg_ready=rst_n && !m_tvalid;
 wire s_fire=s_tvalid && s_tready;
 wire last=cnt==block_last;
 wire better=cnt==0 || s_tdata>maxv;
 wire [31:0] nv=better ? s_tdata : maxv;
 wire [15:0] ni=better ? {{(16-MAX_LOG2N){1'b0}},cnt} : maxi;
 always @(posedge clk) begin
  if(!rst_n) begin
   log2n<=4'd4;thr_en<=0;threshold<=0;maxv<=0;maxi<=0;cnt<=0;
   m_tdata<=0;m_tuser<=0;m_tvalid<=0;cfg_done<=0;cfg_error<=0;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(advance) begin
    m_tvalid<=s_fire && last;
    if(s_fire) begin
     if(last) begin
      m_tdata<={ni,nv};m_tuser<=!thr_en || nv>=threshold;
      maxv<=0;maxi<=0;cnt<=0;
     end else begin
      maxv<=nv;maxi<=ni;cnt<=cnt+1'b1;
     end
    end
   end
   if(cfg_valid && cfg_ready) begin
    cfg_done<=1;
    if(cfg_log2n<4'd4 || cfg_log2n>MAXL4 || cfg_thr_en>2'd1)cfg_error<=1;
    else begin
     log2n<=cfg_log2n;thr_en<=cfg_thr_en[0];threshold<=cfg_threshold;
     maxv<=0;maxi<=0;cnt<=0;
    end
   end
  end
 end
`ifndef SYNTHESIS
 initial if(MAX_LOG2N<4 || MAX_LOG2N>12)$fatal(1,"unsupported MAX_LOG2N");
`endif
endmodule
