// Passive statistics tap for a stream channel boundary.
//
// Every stream-facing terminal is an input only. The module drives nothing
// back into the observed channel, so it cannot influence the channel under
// observation (see README "no-influence gate"). Tap the s_* group on the
// ingress handshake of the observed block and the m_* group on its egress
// handshake; for a bare wire connect both groups to the same signals.
//
// rst_n is the same synchronous low-active reset as the channel modules.
// clr is a synchronous active-high pulse that clears all counters. All twelve
// counters are 32-bit saturating: a counter at 32'hFFFF_FFFF holds its value.
// Counting is qualified by the enable bit in the control register.
//
// Configuration/readout is a single index-addressable port: cfg_addr selects
// a register, cfg_rdata returns its value registered (one cycle of latency,
// the read samples pre-edge counter values), cfg_wdata/cfg_we write the only
// writable register. Address map:
//   0  accepted beats        s_tvalid && s_tready
//   1  emitted beats         m_tvalid && m_tready
//   2  source-stall cycles   s_tvalid && !s_tready
//   3  sink-stall cycles     m_tvalid && !m_tready
//   4  accepted beats with s_tlast
//   5  emitted beats  with m_tlast
//   6  accepted beats with s_tuser != 0
//   7  emitted beats  with m_tuser != 0
//   8  err input strobes
//   9  counted cycles        rst_n && enable (utilization denominator)
//   10 source-idle cycles    s_tready && !s_tvalid
//   11 sink-idle cycles      m_tready && !m_tvalid
//   15 control register      bit0 = enable (1 after reset); other bits reserved
//   others read as zero
module stream_stats #(parameter USER_WIDTH=1)(
  input wire clk, rst_n,
  input wire clr,
  input wire s_tvalid, s_tready, s_tlast,
  input wire [USER_WIDTH-1:0] s_tuser,
  input wire m_tvalid, m_tready, m_tlast,
  input wire [USER_WIDTH-1:0] m_tuser,
  input wire err,
  input wire [3:0] cfg_addr,
  input wire [31:0] cfg_wdata,
  input wire cfg_we,
  output reg [31:0] cfg_rdata
);
  reg ctrl_en;
  reg [31:0] c_accept,c_emit,c_src_stall,c_sink_stall;
  reg [31:0] c_s_last,c_m_last,c_s_user,c_m_user;
  reg [31:0] c_err,c_cycles,c_s_idle,c_m_idle;

  wire s_fire = s_tvalid && s_tready;
  wire m_fire = m_tvalid && m_tready;

  // clr has priority over counting; en=0 freezes every counter.
  always @(posedge clk) begin
    if(!rst_n || clr) begin
      c_accept<=0;c_emit<=0;c_src_stall<=0;c_sink_stall<=0;
      c_s_last<=0;c_m_last<=0;c_s_user<=0;c_m_user<=0;
      c_err<=0;c_cycles<=0;c_s_idle<=0;c_m_idle<=0;
    end else if(ctrl_en) begin
      if(s_fire && c_accept!=32'hFFFF_FFFF) c_accept<=c_accept+1'b1;
      if(m_fire && c_emit!=32'hFFFF_FFFF) c_emit<=c_emit+1'b1;
      if(s_tvalid && !s_tready && c_src_stall!=32'hFFFF_FFFF) c_src_stall<=c_src_stall+1'b1;
      if(m_tvalid && !m_tready && c_sink_stall!=32'hFFFF_FFFF) c_sink_stall<=c_sink_stall+1'b1;
      if(s_fire && s_tlast && c_s_last!=32'hFFFF_FFFF) c_s_last<=c_s_last+1'b1;
      if(m_fire && m_tlast && c_m_last!=32'hFFFF_FFFF) c_m_last<=c_m_last+1'b1;
      if(s_fire && s_tuser!=0 && c_s_user!=32'hFFFF_FFFF) c_s_user<=c_s_user+1'b1;
      if(m_fire && m_tuser!=0 && c_m_user!=32'hFFFF_FFFF) c_m_user<=c_m_user+1'b1;
      if(err && c_err!=32'hFFFF_FFFF) c_err<=c_err+1'b1;
      if(c_cycles!=32'hFFFF_FFFF) c_cycles<=c_cycles+1'b1;
      if(s_tready && !s_tvalid && c_s_idle!=32'hFFFF_FFFF) c_s_idle<=c_s_idle+1'b1;
      if(m_tready && !m_tvalid && c_m_idle!=32'hFFFF_FFFF) c_m_idle<=c_m_idle+1'b1;
    end
  end

  always @(posedge clk) begin
    if(!rst_n) begin ctrl_en<=1'b1; cfg_rdata<=0; end
    else begin
      if(cfg_we && cfg_addr==4'd15) ctrl_en<=cfg_wdata[0];
      case(cfg_addr)
        4'd0:  cfg_rdata<=c_accept;
        4'd1:  cfg_rdata<=c_emit;
        4'd2:  cfg_rdata<=c_src_stall;
        4'd3:  cfg_rdata<=c_sink_stall;
        4'd4:  cfg_rdata<=c_s_last;
        4'd5:  cfg_rdata<=c_m_last;
        4'd6:  cfg_rdata<=c_s_user;
        4'd7:  cfg_rdata<=c_m_user;
        4'd8:  cfg_rdata<=c_err;
        4'd9:  cfg_rdata<=c_cycles;
        4'd10: cfg_rdata<=c_s_idle;
        4'd11: cfg_rdata<=c_m_idle;
        4'd15: cfg_rdata<={31'b0,ctrl_en};
        default: cfg_rdata<=32'd0;
      endcase
    end
  end

  initial begin
    if(USER_WIDTH<1) $fatal(1,"invalid parameter");
  end
endmodule
