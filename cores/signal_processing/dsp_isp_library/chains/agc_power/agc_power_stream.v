// Delivery bundle: stereo AGC feeding complex power measurement.
//
// The 25K dock has no working statistics chain (DSP-04 diverges on silicon), so
// the DSP-side metering delivery is recomposed from the three leaves that are
// board-verified: two independent DSP-07 AGC lanes -- one per quadrature channel
// -- whose gained samples are re-paired for DSP-05 mag_squared.  Both AGC lanes
// carry the same 23-bit control word, so a single configuration sets the whole
// bundle; the 5-bit power shift belongs to the magnitude stage alone.
//
// Latency: the AGC pipeline is 4 globally stalled II=1 slots and mag_squared is
// another 4, so the bundle presents one elastic pipeline of 8 stages.  Both lanes
// see the same m_tready and the same accept decisions, so their outputs pair up
// without a skid buffer; s_tvalid into the magnitude stage is the AND of the two
// lane valids, which can only ever stall, never drop or duplicate a beat.
//
// Markers: s_tuser/s_tlast are AGC-side delimiters.  mag_squared carries no
// stream markers -- its m_tuser is the output saturation flag, which is what this
// bundle reports.
module agc_power_stream(
 input wire clk,rst_n,
 input wire signed [31:0] s_tdata,
 input wire s_tvalid,s_tuser,s_tlast,
 output wire s_tready,
 output wire [31:0] m_tdata,
 output wire m_tvalid,m_tuser,
 input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [27:0] cfg_word,
 output wire cfg_done,output wire cfg_error
);
 localparam signed [8:0] GMIN = -9'sd96, GMAX = 9'sd32;

 wire signed [15:0] i_gain, q_gain;
 wire i_v, q_v, i_u, i_l, q_u, q_l, i_rdy, q_rdy, mag_rdy;
 wire i_cfg_ready, q_cfg_ready, m_cfg_ready;
 wire i_cfg_done, q_cfg_done, m_cfg_done;
 wire i_cfg_error, q_cfg_error, m_cfg_error;

 assign s_tready = i_rdy && q_rdy;
 wire take = s_tvalid && s_tready;

 agc_stream agc_i(.clk(clk),.rst_n(rst_n),
  .s_tdata(s_tdata[15:0]),.s_tvalid(take),.s_tready(i_rdy),
  .s_tuser(s_tuser),.s_tlast(s_tlast),
  .m_tdata(i_gain),.m_tuser(i_u),.m_tlast(i_l),.m_tvalid(i_v),.m_tready(mag_rdy),
  .cfg_valid(cfg_valid),.cfg_ready(i_cfg_ready),
  .cfg_target(cfg_word[6:0]),.cfg_gmin(GMIN),.cfg_gmax(GMAX),
  .cfg_attack(cfg_word[10:7]),.cfg_release(cfg_word[14:11]),.cfg_est(cfg_word[18:15]),
  .cfg_mode(cfg_word[19]),.cfg_mute(cfg_word[20]),.cfg_bypass(cfg_word[21]),
  .cfg_clear(cfg_word[22]),
  .cfg_done(i_cfg_done),.cfg_error(i_cfg_error),
  .clip_sticky(),.env_code(),.gain_code());

 agc_stream agc_q(.clk(clk),.rst_n(rst_n),
  .s_tdata(s_tdata[31:16]),.s_tvalid(take),.s_tready(q_rdy),
  .s_tuser(s_tuser),.s_tlast(s_tlast),
  .m_tdata(q_gain),.m_tuser(q_u),.m_tlast(q_l),.m_tvalid(q_v),.m_tready(mag_rdy),
  .cfg_valid(cfg_valid),.cfg_ready(q_cfg_ready),
  .cfg_target(cfg_word[6:0]),.cfg_gmin(GMIN),.cfg_gmax(GMAX),
  .cfg_attack(cfg_word[10:7]),.cfg_release(cfg_word[14:11]),.cfg_est(cfg_word[18:15]),
  .cfg_mode(cfg_word[19]),.cfg_mute(cfg_word[20]),.cfg_bypass(cfg_word[21]),
  .cfg_clear(cfg_word[22]),
  .cfg_done(q_cfg_done),.cfg_error(q_cfg_error),
  .clip_sticky(),.env_code(),.gain_code());

 wire [31:0] power;
 wire power_valid, power_sat, power_ready;

 assign m_tdata = power;
 assign m_tvalid = power_valid;
 assign m_tuser = power_sat;

 mag_squared magnitude(.clk(clk),.rst_n(rst_n),
  .s_tdata({q_gain,i_gain}),.s_tvalid(i_v && q_v),.s_tready(mag_rdy),
  .m_tdata(power),.m_tuser(power_sat),.m_tvalid(power_valid),.m_tready(m_tready),
  .cfg_valid(cfg_valid),.cfg_ready(m_cfg_ready),.cfg_shift(cfg_word[27:23]),
  .cfg_done(m_cfg_done),.cfg_error(m_cfg_error));

 // Configuration is atomic across the bundle: the harness leaves CONFIG only
 // when every stage has taken the word, so a stage that lags cannot be starved.
 reg latched_i, latched_q, latched_m;
 always @(posedge clk) begin
  if(!rst_n) begin latched_i<=0; latched_q<=0; latched_m<=0; end
  else begin
   if(i_cfg_done) latched_i<=1;
   if(q_cfg_done) latched_q<=1;
   if(m_cfg_done) latched_m<=1;
  end
 end
 assign cfg_ready = i_cfg_ready && q_cfg_ready && m_cfg_ready;
 assign cfg_done = latched_i && latched_q && latched_m;
 assign cfg_error = i_cfg_error | q_cfg_error | m_cfg_error;
endmodule
