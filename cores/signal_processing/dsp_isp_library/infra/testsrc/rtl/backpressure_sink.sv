// Controlled-backpressure stream sink with an observability tap.
// s_tready = rst_n && armed && pattern. The pattern is a free-running
// function of the clock (advances every armed cycle, independent of
// transfers) so a seed fully determines the stall sequence:
//   mode0 always ready; mode1 lfsr[7:0] >= threshold (PRBS-16 step/clock);
//   mode2 cyclic: ready `run` clocks then stalled `stall` clocks.
// beat/beat_data/beat_user/beat_last register each accepted beat one cycle
// later: wire `beat` to a checker's s_tvalid to observe transferred beats.
// Atomic cfg semantics identical to prbs_source: a legal commit clears
// state; an illegal commit pulses cfg_error and normal operation continues.
module backpressure_sink #(parameter integer DATA_WIDTH=16) (
  input wire clk, rst_n,
  input wire [DATA_WIDTH-1:0] s_tdata,
  input wire s_tuser, s_tlast,
  input wire s_tvalid, output wire s_tready,
  input wire cfg_valid, output wire cfg_ready,
  input wire [2:0] cfg_mode,             // 0..2
  input wire [15:0] cfg_seed,
  input wire [7:0] cfg_threshold,
  input wire [15:0] cfg_run, cfg_stall,
  input wire [2:0] cfg_trig_mode,        // 0 off, 1 every trig_period beats
  input wire [31:0] cfg_trig_period,
  output reg cfg_done, cfg_error,
  output reg beat,
  output reg [DATA_WIDTH-1:0] beat_data,
  output reg beat_user, beat_last,
  output reg trigger,
  output reg [31:0] count,
  output reg armed
);
  assign cfg_ready = rst_n;
  wire cfg_bad = cfg_mode > 3'd2 ||
                 (cfg_mode == 3'd2 && {1'b0, cfg_run} + {1'b0, cfg_stall} == 17'd0) ||
                 cfg_trig_mode > 3'd1 ||
                 (cfg_trig_mode == 3'd1 && cfg_trig_period == 32'd0);
  wire cfg_ok = cfg_valid && cfg_ready && !cfg_bad;

  reg [1:0] mode;
  reg [15:0] lfsr, run, stall;
  reg [7:0] threshold;
  reg [16:0] pos;
  reg trig_mode1;
  reg [31:0] trig_period, trig_cnt;

  reg ready_pat;
  always @* begin
    case (mode)
      2'd0: ready_pat = 1'b1;
      2'd1: ready_pat = (lfsr[7:0] >= threshold);
      default: ready_pat = (pos < {1'b0, run});
    endcase
  end
  assign s_tready = rst_n && armed && ready_pat;
  wire accept = s_tvalid && s_tready;

  always @(posedge clk) begin
    if (!rst_n) begin
      mode <= 0; lfsr <= 0; run <= 1; stall <= 0; threshold <= 0; pos <= 0;
      trig_mode1 <= 0; trig_period <= 0; trig_cnt <= 0;
      cfg_done <= 0; cfg_error <= 0;
      beat <= 0; beat_data <= 0; beat_user <= 0; beat_last <= 0;
      trigger <= 0; count <= 0; armed <= 0;
    end else begin
      cfg_done <= 0; cfg_error <= 0; trigger <= 0; beat <= 0;
      if (cfg_ok) begin
        cfg_done <= 1; armed <= 1;
        mode <= cfg_mode[1:0];
        lfsr <= cfg_seed; threshold <= cfg_threshold;
        run <= cfg_run; stall <= cfg_stall; pos <= 0;
        trig_mode1 <= (cfg_trig_mode == 3'd1);
        trig_period <= cfg_trig_period; trig_cnt <= 0;
        count <= 0;
      end else begin
        if (cfg_valid && cfg_ready) cfg_error <= 1;
        if (armed) begin
          // free-running pattern state: advances every armed clock
          lfsr <= {^(lfsr & 16'h002D), lfsr[15:1]};
          if (mode == 2'd2) pos <= (pos + 1'b1 == {1'b0, run} + {1'b0, stall}) ? 17'd0 : pos + 1'b1;
          if (accept) begin
            beat <= 1; beat_data <= s_tdata;
            beat_user <= s_tuser; beat_last <= s_tlast;
            if (count != 32'hFFFFFFFF) count <= count + 1'b1;
            if (trig_mode1 && trig_cnt + 1'b1 == trig_period) begin
              trig_cnt <= 0; trigger <= 1;
            end else if (trig_mode1) begin
              trig_cnt <= trig_cnt + 1'b1;
            end
          end
        end
      end
    end
  end
`ifndef SYNTHESIS
  initial if (DATA_WIDTH < 1 || DATA_WIDTH > 64) $fatal(1, "unsupported DATA_WIDTH");
`endif
endmodule
