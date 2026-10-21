// Passive stream checker: counts transfers, tracks a CRC-32, optional
// sequence and image-marker (SOF/EOL position) checks, sticky error flags,
// first_error beat index, done level at cfg_expected beats, trigger output.
// s_tready = rst_n && armed: the checker never stalls a source.
// CRC compare fires one edge after the done beat so the post-beat state
// is used; first_error for a CRC mismatch is the done-beat index.
// Atomic cfg semantics identical to prbs_source: a legal commit clears all
// state and re-arms; an illegal commit pulses cfg_error and a beat accepted
// on the same edge is still processed.
module stream_sink_checker #(parameter integer DATA_WIDTH=8) (
  input wire clk, rst_n,
  input wire [DATA_WIDTH-1:0] s_tdata,
  input wire s_tuser, s_tlast,
  input wire s_tvalid, output wire s_tready,
  input wire cfg_valid, output wire cfg_ready,
  input wire [31:0] cfg_expected,        // beats to a clean done, >=1
  input wire cfg_crc_en, input wire [31:0] cfg_crc,
  input wire cfg_seq_en,
  input wire [DATA_WIDTH-1:0] cfg_seq_start, cfg_seq_step,
  input wire cfg_img_en,
  input wire [15:0] cfg_img_w, cfg_img_h,
  input wire [2:0] cfg_trig_mode,        // 0..3
  input wire [31:0] cfg_trig_period,
  output reg cfg_done, cfg_error,
  output reg [31:0] count, frames,
  output reg done,
  output reg err_crc, err_seq, err_sof, err_eol, err_extra,
  output reg [31:0] first_error,         // 0-based beat index; FFFFFFFF none
  output reg trigger,
  output reg armed
);
  assign cfg_ready = rst_n;
  assign s_tready = rst_n && armed;
  wire accept = s_tvalid && s_tready;
  wire cfg_bad = cfg_expected == 32'd0 ||
                 (cfg_img_en && (cfg_img_w == 16'd0 || cfg_img_h == 16'd0)) ||
                 cfg_trig_mode > 3'd3 ||
                 (cfg_trig_mode == 3'd3 && cfg_trig_period == 32'd0);
  wire cfg_ok = cfg_valid && cfg_ready && !cfg_bad;

  // Transport CRC over every accepted beat (result not used; compare is
  // done on the raw state one edge after the done beat).
  wire [31:0] crc_state;
  crc32 #(.DATA_WIDTH(DATA_WIDTH)) u_crc (
    .clk(clk), .rst_n(rst_n), .init(cfg_ok),
    .s_tdata(s_tdata), .s_tvalid(accept), .s_tready(),
    .s_tlast(1'b0), .state(crc_state), .result(), .done());

  reg [31:0] expected, trig_period, trig_cnt, crc_idx, crc_exp;
  reg [15:0] img_w, img_h;
  reg [DATA_WIDTH-1:0] seq_exp, seq_step;
  reg crc_en, seq_en, img_en, crc_pend;
  reg [1:0] trig_mode;
  reg [15:0] px, py;

  wire any_err = err_crc | err_seq | err_sof | err_eol | err_extra;
  wire exp_sof = (px == 16'd0 && py == 16'd0);
  wire exp_eol = (px == img_w - 1'b1);

  reg set_extra, set_seq, set_sof, set_eol, set_crc;
  reg [31:0] err_index;

  always @(posedge clk) begin
    if (!rst_n) begin
      expected <= 0; trig_period <= 0; trig_cnt <= 0; crc_idx <= 0;
      crc_exp <= 0; img_w <= 1; img_h <= 1;
      seq_exp <= 0; seq_step <= 0;
      crc_en <= 0; seq_en <= 0; img_en <= 0; crc_pend <= 0;
      trig_mode <= 0; px <= 0; py <= 0;
      cfg_done <= 0; cfg_error <= 0;
      count <= 0; frames <= 0; done <= 0;
      err_crc <= 0; err_seq <= 0; err_sof <= 0; err_eol <= 0; err_extra <= 0;
      first_error <= 32'hFFFFFFFF; trigger <= 0; armed <= 0;
    end else begin
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      if (cfg_ok) begin
        cfg_done <= 1; armed <= 1;
        expected <= cfg_expected;
        crc_en <= cfg_crc_en; crc_exp <= cfg_crc; crc_idx <= 0;
        seq_en <= cfg_seq_en;
        seq_exp <= cfg_seq_start; seq_step <= cfg_seq_step;
        img_en <= cfg_img_en; img_w <= cfg_img_w; img_h <= cfg_img_h;
        trig_mode <= cfg_trig_mode[1:0];
        trig_period <= cfg_trig_period; trig_cnt <= 0;
        crc_pend <= 0;
        count <= 0; frames <= 0; done <= 0;
        err_crc <= 0; err_seq <= 0; err_sof <= 0; err_eol <= 0; err_extra <= 0;
        first_error <= 32'hFFFFFFFF;
        px <= 0; py <= 0;
      end else begin
        if (cfg_valid && cfg_ready) cfg_error <= 1;
        set_extra = 0; set_seq = 0; set_sof = 0; set_eol = 0; set_crc = 0;
        err_index = 32'hFFFFFFFF;
        // CRC compare one edge after the done beat (state now includes it).
        if (crc_pend) begin
          crc_pend <= 0;
          if (crc_en && (crc_state ^ 32'hFFFFFFFF) != crc_exp) begin
            set_crc = 1; err_index = crc_idx;
          end
        end
        if (accept) begin
          if (done) set_extra = 1;
          if (seq_en) begin
            if (s_tdata != seq_exp) set_seq = 1;
            seq_exp <= seq_exp + seq_step;
          end
          if (img_en) begin
            if (s_tuser != exp_sof) set_sof = 1;
            if (s_tlast != exp_eol) set_eol = 1;
            if (exp_eol) begin
              px <= 0;
              py <= (py == img_h - 1'b1) ? 16'd0 : py + 1'b1;
            end else begin
              px <= px + 1'b1;
            end
          end
          if (s_tuser && frames != 32'hFFFFFFFF) frames <= frames + 1'b1;
          if (count != 32'hFFFFFFFF) count <= count + 1'b1;
          if (!done && count + 1'b1 == expected) begin
            done <= 1;
            if (crc_en) begin crc_pend <= 1; crc_idx <= count; end
            if (trig_mode == 2'd2) trigger <= 1;
          end
          if (trig_mode == 2'd3 && trig_cnt + 1'b1 == trig_period) begin
            trig_cnt <= 0; trigger <= 1;
          end else if (trig_mode == 2'd3) begin
            trig_cnt <= trig_cnt + 1'b1;
          end
        end
        // Commit flags; first_error = index of the flagging beat (current
        // count for beat-caused flags, stored index for the CRC compare).
        if (set_extra) begin
          err_extra <= 1; if (err_index == 32'hFFFFFFFF) err_index = count;
        end
        if (set_seq) begin
          err_seq <= 1; if (err_index == 32'hFFFFFFFF) err_index = count;
        end
        if (set_sof) begin
          err_sof <= 1; if (err_index == 32'hFFFFFFFF) err_index = count;
        end
        if (set_eol) begin
          err_eol <= 1; if (err_index == 32'hFFFFFFFF) err_index = count;
        end
        if (set_crc) begin
          err_crc <= 1;
        end
        if (set_extra | set_seq | set_sof | set_eol | set_crc) begin
          if (first_error == 32'hFFFFFFFF) first_error <= err_index;
          if (trig_mode == 2'd1 && !any_err) trigger <= 1;
        end
      end
    end
  end
`ifndef SYNTHESIS
  initial if (DATA_WIDTH < 1 || DATA_WIDTH > 64) $fatal(1, "unsupported DATA_WIDTH");
`endif
endmodule
