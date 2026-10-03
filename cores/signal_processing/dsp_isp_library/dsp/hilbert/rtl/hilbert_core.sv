// Hilbert analytic-signal core: antisymmetric FIR + aligned I path,
// envelope, instantaneous phase and instantaneous frequency.
//
// Single clk, synchronous active-low rst_n. Stream tdata/tvalid/tready.
// Output is one 80-bit word per accepted input:
//   m_tdata = {freq_s16, phase_u16, env_u16, q_s16, i_s16}
//   m_tuser = {zero, clip}   (m_tuser[1]=zero, m_tuser[0]=clip)
// Initiation interval 1, no-stall latency 28 clock edges.
//
// Atomic configuration: cfg_valid waits for an empty pipeline
// (cfg_ready), blocks new input while waiting, then applies
// active_pairs/coefficients/clear in one edge. cfg_pairs must be in
// 1..PAIRS; anything else pulses cfg_error and changes nothing.
// cfg_clear additionally empties history and the phase-unwrap state.
module hilbert_core #(
 parameter integer PAIRS=16,
 // Number of shared multipliers in the FIR MAC (1..4). LANES=4 keeps a
 // Gowin build at <=4 DSP-class cells even without -nodsp.
 parameter integer LANES=4,
 // Default: Blackman-windowed 63-tap Hilbert, c_0 innermost pair.
 // Regenerate with models/gen_coeffs.py (cfg_coeffs_hex field).
 parameter [PAIRS*18-1:0] DEFAULT_COEFFS=288'h3fffdfffd3ffe1ffeffff89ffcd3feb7ff80ffd05fee7ff99cfda3bf157f976baedb
)(
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,
 input wire s_tvalid,output wire s_tready,
 output wire [79:0] m_tdata,
 output wire m_tvalid,input wire m_tready,
 output wire [1:0] m_tuser,
 input wire cfg_valid,output wire cfg_ready,
 input wire [5:0] cfg_pairs,
 input wire [PAIRS*18-1:0] cfg_coeffs,
 input wire cfg_clear,
 output reg cfg_done,cfg_error
);
wire advance=(!m_tvalid || m_tready);
wire an_idle;
assign s_tready=rst_n && an_idle && !cfg_valid;
wire accept=s_tvalid && s_tready;
reg [5:0] pairs;
reg [PAIRS*18-1:0] coeffs;
wire an_valid,an_busy,pf_busy;
wire signed [15:0] ai16,aq16;
wire aclip;
wire cfg_legal=cfg_pairs>=1 && cfg_pairs<=PAIRS;
wire cfg_accept=cfg_valid && cfg_ready;
wire clear_pulse=cfg_accept && cfg_legal && cfg_clear;
assign cfg_ready=rst_n && !an_busy && !pf_busy;
hilbert_analytic #(.PAIRS(PAIRS),.LANES(LANES)) analytic (
 .clk(clk),.rst_n(rst_n),.advance(advance),.accept(accept),
 .s_tdata(s_tdata),.active_pairs(pairs),.coeffs_packed(coeffs),
 .clear_state(clear_pulse),
 .i_out(ai16),.q_out(aq16),.clip_out(aclip),
 .out_valid(an_valid),.busy(an_busy),.accept_idle(an_idle));
phase_freq meas (
 .clk(clk),.rst_n(rst_n),.advance(advance),.in_valid(an_valid),
 .i_in(ai16),.q_in(aq16),.clip_in(aclip),.clear_state(clear_pulse),
 .m_tdata(m_tdata),.m_tuser(m_tuser),.m_tvalid(m_tvalid),.busy(pf_busy));
always @(posedge clk)begin
 if(!rst_n)begin
  pairs<=PAIRS;coeffs<=DEFAULT_COEFFS;cfg_done<=0;cfg_error<=0;
 end else begin
  cfg_done<=0;cfg_error<=0;
  if(cfg_accept)begin
   cfg_done<=1;
   if(!cfg_legal)cfg_error<=1;
   else begin pairs<=cfg_pairs;coeffs<=cfg_coeffs;end
  end
 end
end
`ifndef SYNTHESIS
 initial if(PAIRS<1 || PAIRS>32)$fatal(1,"unsupported PAIRS");
`endif
endmodule
