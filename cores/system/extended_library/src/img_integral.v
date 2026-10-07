// ============================================================================
// img_integral -- summed-area table (integral image), streaming (wave2 idx14).
//
//   I(y,x) = pix + I(y,x-1) + I(y-1,x) - I(y-1,x-1)
//          = pix + left + above - above_left
//
// Input stream follows the imgwin contract: per row one new_line beat (no
// pix_valid), then IMG_W pix_valid beats; IMG_H rows per frame.
//
// The previous integral row is stored in ONE w2_dpram (W=18, DEPTH=IMG_W):
//   max integral value for a 32x32 frame of 8-bit pixels = 32*32*255 =
//   261120 < 2^18 = 262144, so 18 bits are exact for the selftest geometry.
//   For larger/denser frames the stored row wraps modulo 2^18 -- this is a
//   documented cap (full 32-bit rows would need two W=18 banks; see
//   doc/units_feat.md).
//
// Pipeline: pixel beat issues the RAM read (registered DOB -> q next beat);
// one beat later the integral is computed and written back to the same RAM
// address.  Row 0 reads garbage (X) so `above` is forced to 0 while row 0 is
// in flight -- X never reaches the datapath.
//   int_out / out_valid lag pix_valid by one clk_en beat, 1:1 stream.
//   `done` rises one beat after the last pixel's integral is emitted.
// ============================================================================
module img_integral #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter LW    = (IMG_W > 1) ? $clog2(IMG_W) : 1,
    parameter RW    = (IMG_H > 1) ? $clog2(IMG_H) : 1
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [31:0] int_out,
    output reg         out_valid,
    output reg         done
);
    reg [LW-1:0] x;              // input column
    reg [RW-1:0] y;              // input row

    // stage-A -> stage-B pipeline registers
    reg [7:0]    pix_d;
    reg [LW-1:0] x_d;
    reg          row0_d;
    reg          last_d;         // last pixel of the frame
    reg          pv_d;

    // integral accumulators (stage B)
    reg [17:0]   left;           // I(y, x-1)
    reg [17:0]   above_left;     // I(y-1, x-1)

    wire [17:0]  q_above;        // I(y-1, x) from RAM (registered read)

    // stage-B combinational integral (all X masked while row 0 in flight)
    wire [17:0] above    = row0_d ? 18'd0 : q_above;
    wire [17:0] left_e   = (x_d == {LW{1'b0}}) ? 18'd0 : left;
    wire [17:0] aleft_e  = (x_d == {LW{1'b0}}) ? 18'd0 : above_left;
    wire [18:0] sum_ab   = {1'b0, left_e} + {1'b0, above};
    wire [18:0] sub      = sum_ab - {1'b0, aleft_e};   // never negative
    wire [17:0] iv       = sub[17:0] + {10'd0, pix_d};

    w2_dpram #(.W(18), .DEPTH(IMG_W)) u_prev (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d), .waddr(x_d), .wdata(iv),
        .re(pix_valid), .raddr(x), .q(q_above)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x          <= {LW{1'b0}};
            y          <= {RW{1'b1}};      // -1: first new_line makes it 0
            pix_d      <= 8'd0;
            x_d        <= {LW{1'b0}};
            row0_d     <= 1'b0;
            last_d     <= 1'b0;
            pv_d       <= 1'b0;
            left       <= 18'd0;
            above_left <= 18'd0;
            int_out    <= 32'd0;
            out_valid  <= 1'b0;
            done       <= 1'b0;
        end else if (clk_en) begin
            // ---- stage A: issue read, capture pixel -----------------------
            pv_d <= pix_valid;
            if (pix_valid) begin
                pix_d  <= pix;
                x_d    <= x;
                row0_d <= (y == {RW{1'b0}});
                last_d <= (x == IMG_W - 1) && (y == IMG_H - 1);
                x      <= (x == IMG_W - 1) ? {LW{1'b0}}
                                         : x + {{LW-1{1'b0}}, 1'b1};
            end
            if (new_line) begin
                y <= y + {{RW-1{1'b0}}, 1'b1};
                x <= {LW{1'b0}};
            end

            // ---- stage B: compute + write-back ----------------------------
            out_valid <= 1'b0;
            if (pv_d) begin
                int_out    <= {14'd0, iv};
                out_valid  <= 1'b1;
                left       <= iv;
                above_left <= above;
                if (last_d) done <= 1'b1;
            end
        end
    end
endmodule
