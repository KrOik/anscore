// PRBS-16 word source. Fibonacci right-shift LFSR, poly x^16+x^5+x^3+x^2+1
// (reciprocal of x^16+x^14+x^13+x^11+1; serial period 65535). Each beat packs
// 16 consecutive serial bits MSB-first: tdata[15] is first in time.
// Atomic cfg: a legal commit arms with word0 already on the held output
// slot (a reconfiguration is a defined stream discontinuity); an illegal
// commit pulses cfg_error and leaves the running stream untouched -- a beat
// consumed on the same edge is still honoured.
module prbs_source (
  input wire clk, rst_n,
  output reg [15:0] m_tdata,
  output reg m_tvalid, input wire m_tready,
  input wire cfg_valid, output wire cfg_ready,
  input wire [15:0] cfg_seed,
  input wire [31:0] cfg_nwords,          // 0 = unlimited
  input wire [2:0] cfg_trig_mode,        // 0 off, 1 every trig_period words
  input wire [31:0] cfg_trig_period,
  output reg cfg_done, cfg_error,
  output reg trigger,
  output reg [31:0] word_count,
  output reg done,                       // level: nwords reached
  output reg armed
);
  assign cfg_ready = rst_n;
  wire xfer = m_tvalid && m_tready;
  wire cfg_bad = cfg_trig_mode > 3'd1 ||
                 (cfg_trig_mode == 3'd1 && cfg_trig_period == 32'd0);
  wire cfg_ok = cfg_valid && cfg_ready && !cfg_bad;

  // {next_state[15:0], emitted_word[15:0]}: 16 serial steps, MSB-first bits.
  function [31:0] gen16(input [15:0] s);
    reg [15:0] t, w; integer i;
    begin
      t = s;
      for (i = 0; i < 16; i = i + 1) begin
        w[15 - i] = t[0];
        t = {^(t & 16'h002D), t[15:1]};
      end
      gen16 = {t, w};
    end
  endfunction

  reg [15:0] lfsr;
  reg [31:0] nwords, trig_period, trig_cnt, g;
  reg trig_mode1;

  always @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid <= 0; m_tdata <= 0; lfsr <= 0;
      nwords <= 0; trig_period <= 0; trig_cnt <= 0; trig_mode1 <= 0;
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      word_count <= 0; done <= 0; armed <= 0;
    end else begin
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      if (cfg_ok) begin
        g = gen16(cfg_seed);
        cfg_done <= 1; armed <= 1; done <= 0;
        lfsr <= g[31:16]; nwords <= cfg_nwords;
        trig_period <= cfg_trig_period; trig_cnt <= 0;
        trig_mode1 <= (cfg_trig_mode == 3'd1);
        word_count <= 0;
        m_tdata <= g[15:0];
        m_tvalid <= 1;
      end else begin
        if (cfg_valid && cfg_ready) cfg_error <= 1;
        if (xfer) begin
          g = gen16(lfsr);
          lfsr <= g[31:16];
          m_tdata <= g[15:0];
          if (word_count != 32'hFFFFFFFF) word_count <= word_count + 1'b1;
          if (nwords != 0 && word_count + 1'b1 == nwords) begin
            m_tvalid <= 0; done <= 1;
          end
          if (trig_mode1 && trig_cnt + 1'b1 == trig_period) begin
            trig_cnt <= 0; trigger <= 1;
          end else if (trig_mode1) begin
            trig_cnt <= trig_cnt + 1'b1;
          end
        end
      end
    end
  end
endmodule
