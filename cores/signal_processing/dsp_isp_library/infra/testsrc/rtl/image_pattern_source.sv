// Sequence-numbered test-frame source, raster order (x fastest).
// tdata = DATA_WIDTH pixel, tuser = SOF at pixel (0,0), tlast = EOL at x=W-1.
// Pixel (0,0) carries the frame sequence number (frame mod 2^DATA_WIDTH);
// all other pixels follow cfg_pattern (see SPEC.md table).
// COLORBAR uses Bresenham bar/rem: bar = floor(8x/W), legal only for W>=8.
// Atomic cfg semantics identical to prbs_source.
module image_pattern_source #(
  parameter integer DATA_WIDTH=8,
  parameter integer MAX_W=4096,
  parameter integer MAX_H=4096
) (
  input wire clk, rst_n,
  output reg [DATA_WIDTH-1:0] m_tdata,
  output reg m_tuser,                      // SOF at (0,0)
  output reg m_tlast,                      // EOL at x==W-1
  output reg m_tvalid, input wire m_tready,
  input wire cfg_valid, output wire cfg_ready,
  input wire [15:0] cfg_w, cfg_h,
  input wire [2:0] cfg_pattern,            // 0..6
  input wire [15:0] cfg_nframes,           // 0 = unlimited
  input wire [2:0] cfg_trig_mode,          // 0..4
  input wire [15:0] cfg_trig_frame,
  output reg cfg_done, cfg_error,
  output reg trigger,
  output reg [31:0] frame_count,
  output reg [31:0] pixel_count,
  output reg done, armed
);
  localparam integer M = (1 << DATA_WIDTH) - 1;
  localparam integer STEP = M / 7;         // COLORBAR step (36 for 8-bit)

  assign cfg_ready = rst_n;
  wire xfer = m_tvalid && m_tready;
  wire cfg_bad = cfg_w == 16'd0 || cfg_w > MAX_W[15:0] ||
                 cfg_h == 16'd0 || cfg_h > MAX_H[15:0] ||
                 cfg_pattern > 3'd6 ||
                 (cfg_pattern == 3'd5 && cfg_w < 16'd8) ||
                 cfg_trig_mode > 3'd4;
  wire cfg_ok = cfg_valid && cfg_ready && !cfg_bad;

  reg [15:0] w, h, nframes, trig_frame;
  reg [2:0] pattern, trig_mode;
  reg [15:0] x, y, frame;
  reg [16:0] bar_rem;                      // 8*x mod w for COLORBAR
  reg [3:0] bar;

  // Pixel value for beat (x,y) of `frame`; (0,0) is the sequence number.
  function [DATA_WIDTH-1:0] pix(input [15:0] f, input [15:0] px,
                                input [15:0] py, input [2:0] pat,
                                input [3:0] b);
    reg [15:0] v;
    begin
      if (px == 16'd0 && py == 16'd0) v = f;
      else case (pat)
        3'd0: v = px;
        3'd1: v = py;
        3'd2: v = px + py;
        3'd3: v = (px + py) & 16'd1 ? 16'hFFFF : 16'd0;
        3'd4: v = (((px >> 3) + (py >> 3)) & 16'd1) ? 16'hFFFF : 16'd0;
        3'd5: v = {12'd0, b} * STEP;  // bounded by 7*STEP <= M
        default: v = 16'd37 * f;
      endcase
      pix = v[DATA_WIDTH-1:0];
    end
  endfunction

  reg [16:0] rem_next;
  reg eol, eof;
  reg trig_cause;

  always @(posedge clk) begin
    if (!rst_n) begin
      m_tvalid <= 0; m_tdata <= 0; m_tuser <= 0; m_tlast <= 0;
      w <= 1; h <= 1; nframes <= 0; trig_frame <= 0;
      pattern <= 0; trig_mode <= 0;
      x <= 0; y <= 0; frame <= 0; bar_rem <= 0; bar <= 0;
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      frame_count <= 0; pixel_count <= 0; done <= 0; armed <= 0;
    end else begin
      cfg_done <= 0; cfg_error <= 0; trigger <= 0;
      if (cfg_ok) begin
        cfg_done <= 1; armed <= 1; done <= 0;
        w <= cfg_w; h <= cfg_h; nframes <= cfg_nframes;
        trig_frame <= cfg_trig_frame; trig_mode <= cfg_trig_mode;
        pattern <= cfg_pattern;
        x <= 0; y <= 0; frame <= 0; bar_rem <= 0; bar <= 0;
        frame_count <= 0; pixel_count <= 0;
        // First pixel of frame 0 is the sequence number 0.
        m_tdata <= pix(16'd0, 16'd0, 16'd0, cfg_pattern, 4'd0);
        m_tuser <= 1'b1;
        m_tlast <= (cfg_w == 16'd1);
        m_tvalid <= 1;
      end else begin
        if (cfg_valid && cfg_ready) cfg_error <= 1;
        if (xfer) begin
          eol = (x == w - 1'b1);
          eof = eol && (y == h - 1'b1);
          // advance position
          if (eol) begin
            x <= 0; bar <= 0; bar_rem <= 0;
            if (y == h - 1'b1) begin
              y <= 0; frame <= frame + 1'b1;
              if (frame_count != 32'hFFFFFFFF) frame_count <= frame_count + 1'b1;
              if (nframes != 0 && frame + 1'b1 == nframes) begin
                m_tvalid <= 0; done <= 1;
              end
            end else begin
              y <= y + 1'b1;
            end
          end else begin
            x <= x + 1'b1;
            rem_next = bar_rem + 17'd8;
            if (rem_next >= {1'b0, w}) begin
              rem_next = rem_next - {1'b0, w};
              bar <= bar + 1'b1;
            end
            bar_rem <= rem_next;
          end
          if (pixel_count != 32'hFFFFFFFF) pixel_count <= pixel_count + 1'b1;
          // next beat fields
          m_tdata <= pix(eof ? frame + 1'b1 : frame,
                         eol ? 16'd0 : x + 1'b1,
                         eol ? ((y == h - 1'b1) ? 16'd0 : y + 1'b1) : y,
                         pattern,
                         eol ? 4'd0 :
                            ((bar_rem + 17'd8 >= {1'b0, w}) ? bar + 4'd1 : bar));
          m_tuser <= eof;                    // next (0,0) iff frame wrapped
          m_tlast <= eol ? (w == 16'd1) : (x + 1'b1 == w - 1'b1);
          // trigger causes (coincident with the beat just consumed)
          trig_cause = (trig_mode == 3'd1 && x == 16'd0 && y == 16'd0) ||
                       (trig_mode == 3'd2 && eol) ||
                       (trig_mode == 3'd3 && x == 16'd0 && y == 16'd0 &&
                        frame == trig_frame) ||
                       (trig_mode == 3'd4 && eof);
          if (trig_cause) trigger <= 1;
        end
      end
    end
  end
`ifndef SYNTHESIS
  initial begin
    if (DATA_WIDTH < 1 || DATA_WIDTH > 16) $fatal(1, "unsupported DATA_WIDTH");
    if (MAX_W < 1 || MAX_W > 65535 || MAX_H < 1 || MAX_H > 65535)
      $fatal(1, "unsupported MAX_W/MAX_H");
  end
`endif
endmodule
