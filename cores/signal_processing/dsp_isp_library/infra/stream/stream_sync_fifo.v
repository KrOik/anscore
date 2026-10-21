// Synchronous RAM read into an elastic output slot. No combinational ready chain.
module stream_sync_fifo #(parameter DATA_WIDTH=16, USER_WIDTH=1, RAM_DEPTH=16,
 parameter MEM_REGS=0)(
 input wire clk,rst_n,
 input wire [DATA_WIDTH-1:0] s_tdata,
 input wire [USER_WIDTH-1:0] s_tuser,
 input wire s_tlast,s_tvalid,output wire s_tready,
 output wire [DATA_WIDTH-1:0] m_tdata,
 output wire [USER_WIDTH-1:0] m_tuser,
 output wire m_tlast,output reg m_tvalid,input wire m_tready,
 output wire [$clog2(RAM_DEPTH+2)-1:0] level
);
 localparam AW=(RAM_DEPTH<2)?1:$clog2(RAM_DEPTH);
 localparam CW=$clog2(RAM_DEPTH+1);
 localparam BW=DATA_WIDTH+USER_WIDTH+1;
 // MEM_REGS=1 forces fabric storage.  The CE-gated DPX9B read pattern
 // (beat<=mem[rd_ptr] qualified by fetch) has diverged on real GW2A silicon
 // for small FIFOs (see docs/IP_OPTIMIZATION_STATUS.md window_probe notes),
 // so shallow skid FIFOs can opt out of BSRAM inference without changing
 // the synchronous-read contract.
 reg [BW-1:0] beat;
 reg [AW-1:0] wr_ptr,rd_ptr;
 reg [CW-1:0] used;
 wire push=s_tvalid && s_tready;
 wire fetch=(used!=0) && (!m_tvalid || m_tready);
 wire [BW-1:0] memq;
 generate if(MEM_REGS!=0) begin: g_fabric
  (* ram_style="registers" *) reg [BW-1:0] memr[0:RAM_DEPTH-1];
  always @(posedge clk) if(rst_n && push) memr[wr_ptr]<={s_tlast,s_tuser,s_tdata};
  assign memq=memr[rd_ptr];
 end else begin: g_block
  (* ram_style="block" *) reg [BW-1:0] mem[0:RAM_DEPTH-1];
  always @(posedge clk) if(rst_n && push) mem[wr_ptr]<={s_tlast,s_tuser,s_tdata};
  assign memq=mem[rd_ptr];
 end endgenerate
 assign s_tready=(used<RAM_DEPTH);
 assign level={1'b0,used}+m_tvalid;
 assign {m_tlast,m_tuser,m_tdata}=beat;
 // No RAM reset, no same-address read/write: full forbids push, empty forbids fetch.
 always @(posedge clk) begin
   if(rst_n && fetch) beat<=memq;
 end
 always @(posedge clk) begin
   if(!rst_n) begin wr_ptr<=0;rd_ptr<=0;used<=0;m_tvalid<=0;end
   else begin
     if(push) wr_ptr <= (wr_ptr==RAM_DEPTH-1)?0:wr_ptr+1'b1;
     if(fetch) rd_ptr <= (rd_ptr==RAM_DEPTH-1)?0:rd_ptr+1'b1;
     case({push,fetch})
       2'b10: used<=used+1'b1;
       2'b01: used<=used-1'b1;
     endcase
     if(fetch) m_tvalid<=1;
     else if(m_tready) m_tvalid<=0;
   end
 end
 initial begin
   if(DATA_WIDTH<1 || USER_WIDTH<1 || RAM_DEPTH<1) $fatal(1,"invalid parameter");
 end
endmodule
