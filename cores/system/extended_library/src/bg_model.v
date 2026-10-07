// ============================================================================
// bg_model -- idx21 BGS: running-average background model + foreground mask.
//
//   frame 0 : bg[i] = pix            (direct init, no X dependence)
//   frame f : d  = pix - bg          (signed 9-bit)
//             fg = (|d| > THR)
//             bg = bg + (d >>> ALPHA)        (arithmetic shift, mod 256)
//
// The background image lives in an internal w2_dpram (T9).  Same pipeline as
// frame_diff: read bg[addr] on the pix_valid beat, compute + write back the
// updated background on the next beat (port A), so throughput is 1 px/beat.
//
// Output stream (out_valid/out_byte):
//   1) fg mask byte (0/1) per pixel of the FINAL frame only
//   2) then all IMG_W*IMG_H final background bytes, address order 0..NPIX-1
// `done` rises one beat after the last background byte and holds.
//
// NOTE on w2_img_stim: `fidx` increments on the edge that PRODUCES a frame's
// last pixel, so the last pix_valid beat of frame f already carries fidx=f+1.
// This unit therefore keys on `wr_frame` (count of frames whose last pixel has
// completed the write-back pipeline) instead of fidx at frame boundaries.
//
// All registers clk_en gated (T2).  No multipliers.  Requires N_FRAMES >= 2.
// `fidx` is accepted for stream-contract uniformity but not used.
// ============================================================================
module bg_model #(
    parameter IMG_W    = 32,
    parameter IMG_H    = 32,
    parameter N_FRAMES = 4,
    parameter ALPHA    = 4,
    parameter THR      = 32,
    parameter AW       = $clog2(IMG_W*IMG_H)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    input  wire [7:0]  fidx,
    output reg  [7:0]  out_byte,
    output reg         out_valid,
    output reg         done
);
    localparam NPIX = IMG_W*IMG_H;
    localparam S_RUN = 2'd0, S_DRAIN = 2'd1, S_DONE = 2'd2;

    reg  [1:0]    state;
    reg  [AW-1:0] addr;
    reg  [7:0]    pix_d1;
    reg  [AW-1:0] addr_d1;
    reg           pv_d1;
    reg  [7:0]    wr_frame;         // completed frames at write-back stage
    reg  [AW:0]   drain_iss;        // one extra bit: counts to NPIX inclusive
    reg           rd_flight;        // a drain read was issued last beat
    wire [7:0]    bg_q;

    // ---- next-background / foreground arithmetic (comb, clk_en-slack) ------
    wire              fg;
    wire [7:0]        bg_new;
    wire signed [8:0] delta  = $signed({1'b0, pix_d1}) - $signed({1'b0, bg_q});
    wire signed [8:0] dsh    = delta >>> ALPHA;      // floor(d / 2^ALPHA)
    assign            bg_new = (wr_frame == 8'd0) ? pix_d1
                                                : (bg_q + dsh[7:0]);
    wire [7:0]        adiff  = (pix_d1 >= bg_q) ? (pix_d1 - bg_q)
                                              : (bg_q - pix_d1);
    assign            fg     = (adiff > THR);
    wire              lastf  = (wr_frame == (N_FRAMES-1));

    // ---- background RAM: port A writes bg_new (t+1), port B reads (t) ------
    wire           ram_re = (state == S_RUN)   ? pix_valid
                          : (state == S_DRAIN) ? (drain_iss < NPIX) : 1'b0;
    wire [AW-1:0]  ram_ra = (state == S_DRAIN) ? drain_iss[AW-1:0] : addr;
    w2_dpram #(.W(8), .DEPTH(NPIX), .AW(AW)) u_bg (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d1), .waddr(addr_d1), .wdata(bg_new),
        .re(ram_re), .raddr(ram_ra), .q(bg_q));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_RUN;
            addr      <= {AW{1'b0}};
            pix_d1    <= 8'd0;
            addr_d1   <= {AW{1'b0}};
            pv_d1     <= 1'b0;
            wr_frame  <= 8'd0;
            drain_iss <= {(AW+1){1'b0}};
            rd_flight <= 1'b0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            // stream capture stage (always runs; harmless during drain)
            if (pix_valid) addr <= addr + 1'b1;
            pix_d1  <= pix;
            addr_d1 <= addr;
            pv_d1   <= pix_valid;
            out_valid <= 1'b0;

            case (state)
            S_RUN: begin
                if (pv_d1 && (addr_d1 == NPIX-1))
                    wr_frame <= wr_frame + 8'd1;
                // emit fg mask byte for pixels of the final frame
                if (pv_d1 && lastf) begin
                    out_byte  <= {7'd0, fg};
                    out_valid <= 1'b1;
                end
                if (pv_d1 && lastf && (addr_d1 == NPIX-1)) begin
                    state     <= S_DRAIN;
                    drain_iss <= {(AW+1){1'b0}};
                    rd_flight <= 1'b0;
                end
            end
            S_DRAIN: begin
                // issue one read per beat (ram_re/ram_ra above), emit the
                // previous beat's word: 1 byte/beat background dump.
                if (drain_iss < NPIX)
                    drain_iss <= drain_iss + 1'b1;
                rd_flight <= (drain_iss < NPIX);
                if (rd_flight) begin
                    out_byte  <= bg_q;
                    out_valid <= 1'b1;
                    if (drain_iss == NPIX)
                        state <= S_DONE;      // last byte emitted this beat
                end
            end
            default: begin                     // S_DONE
                done <= 1'b1;
            end
            endcase
        end
    end
endmodule
