// ============================================================================
// frame_diff -- idx20 FDIF: |curr - prev| frame difference + binary threshold.
//
// Streaming unit: consumes the w2_img_stim pixel stream for N_FRAMES frames.
// The previous frame is kept in an internal w2_dpram (silicon-proven DPX9B
// wrapper -- trap T9).  Per incoming pixel (beat t) the OLD byte at the same
// raster address is read (port B, registered DOB -> data valid at t+1); at
// beat t+1 the current byte is written back (port A), so the RAM always holds
// "previous frame" while the pipeline emits the mask one beat after pix_valid.
//
// Output: one mask byte (8'h00 / 8'h01) per pixel of every frame fidx >= 1,
//   mask = (|curr - prev| > THR).  Frame 0 emits nothing (no valid previous
//   frame; RAM contents would be X).  nl_out/fidx_out are the new_line/fidx
//   inputs delayed by one beat, aligned with mask_out, so the stream keeps the
//   imgwin contract for downstream units (e.g. mot_bbox).
//
// NOTE on w2_img_stim: `fidx` increments on the edge that PRODUCES a frame's
// last pixel, so the last pix_valid beat of frame f already carries fidx=f+1.
// This unit therefore does NOT key on fidx at frame boundaries: `have_prev`
// (set when the first full frame has been written) gates reads and emits, and
// a completed-frame counter (`nfr_done`) drives `done`.  `done` rises with the
// last emitted pixel of the last frame and holds.
//
// All registers clk_en gated (T2).  No multipliers.  Requires N_FRAMES >= 2.
// ============================================================================
module frame_diff #(
    parameter IMG_W    = 32,
    parameter IMG_H    = 32,
    parameter N_FRAMES = 3,
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
    output reg  [7:0]  mask_out,
    output reg         out_valid,
    output reg         nl_out,
    output reg  [7:0]  fidx_out,
    output reg         done
);
    localparam NPIX = IMG_W*IMG_H;

    reg  [AW-1:0] addr;             // raster write/read address, wraps mod NPIX
    reg  [7:0]    pix_d1;
    reg  [AW-1:0] addr_d1;
    reg           pv_d1, nl_d1, hp_d1;
    reg  [7:0]    fidx_d1;
    reg           have_prev;        // a complete previous frame is stored
    reg  [7:0]    nfr_done;         // emitted-frame completions
    wire [7:0]    prev_q;

    // port B: read previous-frame byte only when a previous frame exists.
    // read (this beat) / write (next beat) of the same address never collide.
    wire rd_en = pix_valid & have_prev;
    w2_dpram #(.W(8), .DEPTH(NPIX), .AW(AW)) u_prev (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d1), .waddr(addr_d1), .wdata(pix_d1),
        .re(rd_en), .raddr(addr), .q(prev_q));

    wire [7:0] adiff = (pix_d1 >= prev_q) ? (pix_d1 - prev_q)
                                        : (prev_q - pix_d1);
    wire       emit_en = pv_d1 & hp_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr      <= {AW{1'b0}};
            pix_d1    <= 8'd0;
            addr_d1   <= {AW{1'b0}};
            pv_d1     <= 1'b0;
            nl_d1     <= 1'b0;
            hp_d1     <= 1'b0;
            fidx_d1   <= 8'd0;
            have_prev <= 1'b0;
            nfr_done  <= 8'd0;
            mask_out  <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
            fidx_out  <= 8'd0;
            done      <= 1'b0;
        end else if (clk_en) begin
            // stage 0: capture stream beat, issue prev-frame read
            if (pix_valid) begin
                addr <= addr + 1'b1;               // wraps at NPIX
                if (addr == NPIX-1)
                    have_prev <= 1'b1;             // frame f fully written at t+1
            end
            pix_d1  <= pix;
            addr_d1 <= addr;
            pv_d1   <= pix_valid;
            nl_d1   <= new_line;
            fidx_d1 <= fidx;
            hp_d1   <= have_prev;
            // stage 1: prev_q valid -> emit mask for frames >= 1
            out_valid <= emit_en;
            mask_out  <= {7'd0, (adiff > THR)};
            nl_out    <= nl_d1;
            fidx_out  <= fidx_d1;
            if (emit_en && (addr_d1 == NPIX-1)) begin
                nfr_done <= nfr_done + 8'd1;
                if (nfr_done == (N_FRAMES-2))
                    done <= 1'b1;
            end
        end
    end
endmodule
