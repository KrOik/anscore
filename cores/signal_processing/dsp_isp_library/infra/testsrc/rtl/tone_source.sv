// Multi-tone / swept-tone NCO source, signed16 Q1.15 output, II=1.
// Phase accumulators Q0.32 (cycles * 2^32). Quarter-wave sine ROM: 64
// midpoint-sampled entries, phase[31:30]=quadrant, phase[29:24]=index.
// Mix: acc = sum amp_i*sine_i; y = sat16((acc + 2^14) >>> 15) round half up.
// Sample k uses phase init + k*inc; phases advance after each transfer.
// Sweep (mode1): tone0 only; inc_cur += sw_step after each sw_dwell samples,
// wraps to inc0 past sw_stop (sawtooth; down-sweep for negative step).
// Atomic cfg semantics identical to prbs_source: legal commit re-arms,
// illegal commit pulses cfg_error and the running stream still advances.
// nph/namp/nt_eff are blocking temporaries feeding the mix so that both the
// config-time first sample and steady-state beats evaluate correctly.
module tone_source #(parameter integer MAX_TONES=4) (
  input wire clk, rst_n,
  output reg signed [15:0] m_tdata,
  output reg m_tvalid, input wire m_tready,
  input wire cfg_valid, output wire cfg_ready,
  input wire [2:0] cfg_mode,             // 0 multitone, 1 sweep
  input wire [3:0] cfg_ntone,            // 1..MAX_TONES (mode 0)
  input wire [32*MAX_TONES-1:0] cfg_inc,   // tone i at bits [32i +: 32]
  input wire [32*MAX_TONES-1:0] cfg_phase,
  input wire [16*MAX_TONES-1:0] cfg_amp,   // signed Q1.15 at [16i +: 16]
  input wire signed [31:0] cfg_sw_step,
  input wire [31:0] cfg_sw_stop,
  input wire [15:0] cfg_sw_dwell,
  input wire [31:0] cfg_nsamp,           // 0 = unlimited
  input wire [2:0] cfg_trig_mode,        // 0 off, 1 sweep wrap, 2 period
  input wire [31:0] cfg_trig_period,
  output reg cfg_done, cfg_error,
  output reg trigger,
  output reg [31:0] sample_count,
  output reg done, armed
);
  assign cfg_ready = rst_n;
  wire xfer = m_tvalid && m_tready;
  wire cfg_bad = cfg_mode > 3'd1 ||
      (cfg_mode == 3'd0 && (cfg_ntone < 4'd1 || cfg_ntone > MAX_TONES[3:0])) ||
      (cfg_mode == 3'd1 && cfg_sw_dwell == 16'd0) ||
      cfg_trig_mode > 3'd2 ||
      (cfg_trig_mode == 3'd2 && cfg_trig_period == 32'd0);
  wire cfg_ok = cfg_valid && cfg_ready && !cfg_bad;

  // Quarter-wave sine ROM, midpoint sampled Q1.15.
  function signed [15:0] lut(input [5:0] i);
    case (i)
      0:lut=402;   1:lut=1206;  2:lut=2009;  3:lut=2811;
      4:lut=3612;  5:lut=4410;  6:lut=5205;  7:lut=5998;
      8:lut=6786;  9:lut=7571; 10:lut=8351; 11:lut=9126;
      12:lut=9896; 13:lut=10659;14:lut=11417;15:lut=12167;
      16:lut=12910;17:lut=13645;18:lut=14372;19:lut=15090;
      20:lut=15800;21:lut=16499;22:lut=17189;23:lut=17869;
      24:lut=18537;25:lut=19195;26:lut=19841;27:lut=20475;
      28:lut=21096;29:lut=21705;30:lut=22301;31:lut=22884;
      32:lut=23452;33:lut=24007;34:lut=24547;35:lut=25072;
      36:lut=25582;37:lut=26077;38:lut=26556;39:lut=27019;
      40:lut=27466;41:lut=27896;42:lut=28310;43:lut=28706;
      44:lut=29085;45:lut=29447;46:lut=29791;47:lut=30117;
      48:lut=30424;49:lut=30714;50:lut=30985;51:lut=31237;
      52:lut=31470;53:lut=31685;54:lut=31880;55:lut=32057;
      56:lut=32213;57:lut=32351;58:lut=32469;59:lut=32567;
      60:lut=32646;61:lut=32705;62:lut=32745;63:lut=32765;
    endcase
  endfunction

  function signed [15:0] sine(input [31:0] ph);
    reg [5:0] idx;
    begin
      idx = ph[29:24];
      case (ph[31:30])
        2'd0: sine = lut(idx);
        2'd1: sine = lut(6'd63 - idx);
        2'd2: sine = -lut(idx);
        default: sine = -lut(6'd63 - idx);
      endcase
    end
  endfunction

  function signed [15:0] clip(input signed [33:0] v);
    clip = v > 34'sd32767 ? 16'sd32767 : v < -34'sd32768 ? -16'sd32768 : v[15:0];
  endfunction

  reg [31:0] phase [0:MAX_TONES-1];
  reg [31:0] inc   [0:MAX_TONES-1];
  reg signed [15:0] amp [0:MAX_TONES-1];
  reg [3:0] ntone;
  reg mode_sweep;
  reg [31:0] inc_cur, sw_stop;
  reg signed [31:0] sw_step;
  reg [15:0] sw_dwell, dwell_cnt;
  reg [31:0] nsamp, trig_period, trig_cnt;
  reg [1:0] trig_mode;

  // Blocking temporaries for the candidate mix (assigned before use).
  reg [31:0] nph [0:MAX_TONES-1];
  reg signed [15:0] namp [0:MAX_TONES-1];
  reg [31:0] inc_next;
  reg wrap;
  reg signed [33:0] acc;
  reg signed [15:0] smp;
  integer i;

  always @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid <= 0; m_tdata <= 0;
      ntone <= 1; mode_sweep <= 0;
      inc_cur <= 0; sw_stop <= 0; sw_step <= 0; sw_dwell <= 1; dwell_cnt <= 0;
      nsamp <= 0; trig_period <= 0; trig_cnt <= 0; trig_mode <= 0;
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      sample_count <= 0; done <= 0; armed <= 0;
      for (i = 0; i < MAX_TONES; i = i + 1) begin
        phase[i] <= 0; inc[i] <= 0; amp[i] <= 0;
      end
    end else begin
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      if (cfg_ok) begin
        cfg_done <= 1; armed <= 1; done <= 0;
        mode_sweep <= (cfg_mode == 3'd1);
        ntone <= (cfg_mode == 3'd1) ? 4'd1 : cfg_ntone;
        inc_cur <= cfg_inc[31:0];
        sw_step <= cfg_sw_step; sw_stop <= cfg_sw_stop;
        sw_dwell <= (cfg_mode == 3'd1) ? cfg_sw_dwell : 16'd1;
        dwell_cnt <= 0;
        nsamp <= cfg_nsamp;
        trig_period <= cfg_trig_period; trig_cnt <= 0;
        trig_mode <= cfg_trig_mode[1:0];
        sample_count <= 0;
        for (i = 0; i < MAX_TONES; i = i + 1) begin
          phase[i] <= cfg_phase[32*i +: 32];
          inc[i]   <= cfg_inc[32*i +: 32];
          amp[i]   <= cfg_amp[16*i +: 16];
          nph[i]   = cfg_phase[32*i +: 32];
          namp[i]  = cfg_amp[16*i +: 16];
        end
        // First output sample from the configured initial phases.
        acc = 34'sd0;
        for (i = 0; i < MAX_TONES; i = i + 1)
          if (i < ((cfg_mode == 3'd1) ? 1 : cfg_ntone))
            acc = acc + namp[i] * sine(nph[i]);
        m_tdata <= clip((acc + 34'sd16384) >>> 15);
        m_tvalid <= 1;
      end else begin
        if (cfg_valid && cfg_ready) cfg_error <= 1;
        if (xfer) begin
          wrap = 1'b0;
          inc_next = inc_cur;
          if (mode_sweep) begin
            // dwell/inc bookkeeping affects the NEXT advance.
            if (dwell_cnt + 1'b1 == sw_dwell) begin
              dwell_cnt <= 0;
              inc_next = inc_cur + sw_step;
              if ((!sw_step[31] && sw_step != 32'd0 && inc_next > sw_stop) ||
                  (sw_step[31] && inc_next < sw_stop)) begin
                inc_next = inc[0];
                wrap = 1'b1;
              end
              inc_cur <= inc_next;
            end else begin
              dwell_cnt <= dwell_cnt + 1'b1;
            end
            nph[0] = phase[0] + inc_cur;
            namp[0] = amp[0];
            phase[0] <= phase[0] + inc_cur;
          end else begin
            for (i = 0; i < MAX_TONES; i = i + 1) begin
              nph[i] = phase[i] + inc[i];
              namp[i] = amp[i];
              phase[i] <= phase[i] + inc[i];
            end
          end
          acc = 34'sd0;
          for (i = 0; i < MAX_TONES; i = i + 1)
            if (i < ntone)
              acc = acc + namp[i] * sine(nph[i]);
          m_tdata <= clip((acc + 34'sd16384) >>> 15);
          if (sample_count != 32'hFFFFFFFF) sample_count <= sample_count + 1'b1;
          if (nsamp != 0 && sample_count + 1'b1 == nsamp) begin
            m_tvalid <= 0; done <= 1;
          end
          if (trig_mode == 2'd1 && wrap) trigger <= 1;
          if (trig_mode == 2'd2 && trig_cnt + 1'b1 == trig_period) begin
            trig_cnt <= 0; trigger <= 1;
          end else if (trig_mode == 2'd2) begin
            trig_cnt <= trig_cnt + 1'b1;
          end
        end
      end
    end
  end
`ifndef SYNTHESIS
  initial if (MAX_TONES < 1 || MAX_TONES > 8) $fatal(1, "unsupported MAX_TONES");
`endif
endmodule
