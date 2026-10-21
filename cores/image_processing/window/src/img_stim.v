// ============================================================================
// img_stim -- deterministic 16x16 test-image streamer for the selftest.
// Per clk_en beat: one new_line beat, then IMG_W pix_valid beats; repeats
// for IMG_H rows, then idles (stim_done).  Runs autonomously after reset.
//
// Pixel formula (must match tools/golden_model.py EXACTLY):
//   base = (x + x<<4) ^ (y + y<<3 + y<<5) ^ ((x & y) << 3)      [8-bit]
//   pix  = base + 8'h50 when 6<=x<=9 && 5<=y<=10 (bright square), else base
// All arithmetic is shift/add on 8-bit values (no multipliers, wraps mod 256).
// pix is registered so it is stable for the whole pix_valid beat.
// ============================================================================
module img_stim #(
    parameter IMG_W = 16,
    parameter IMG_H = 16
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    output reg  [7:0] pix,
    output reg        pix_valid,
    output reg        new_line,
    output reg        stim_done
);
    localparam CW = (IMG_W > 1) ? $clog2(IMG_W) : 1;
    localparam RW = (IMG_H > 1) ? $clog2(IMG_H) : 1;

    reg [RW-1:0] y;
    reg [CW-1:0] x;
    reg          nl_pending;   // next beat issues the new_line pulse

    wire [7:0] x8 = {{(8-CW){1'b0}}, x};
    wire [7:0] y8 = {{(8-RW){1'b0}}, y};
    wire [7:0] base = (x8 + (x8 << 4)) ^ (y8 + (y8 << 3) + (y8 << 5)) ^
                      ((x8 & y8) << 3);
    wire boost = (x >= 6) && (x <= 9) && (y >= 5) && (y <= 10);
    wire [7:0] fpix = boost ? (base + 8'h50) : base;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y          <= {RW{1'b0}};
            x          <= {CW{1'b0}};
            nl_pending <= 1'b1;             // row 0 starts with new_line
            pix        <= 8'd0;
            pix_valid  <= 1'b0;
            new_line   <= 1'b0;
            stim_done  <= 1'b0;
        end else if (clk_en) begin
            new_line  <= 1'b0;
            pix_valid <= 1'b0;
            if (!stim_done && nl_pending) begin
                new_line   <= 1'b1;
                nl_pending <= 1'b0;
                x          <= {CW{1'b0}};
            end else if (!stim_done && x < IMG_W) begin
                pix       <= fpix;
                pix_valid <= 1'b1;
                if (x == IMG_W - 1) begin
                    x <= {CW{1'b0}};
                    if (y == IMG_H - 1) begin
                        stim_done <= 1'b1;
                    end else begin
                        y          <= y + 1'b1;
                        nl_pending <= 1'b1;
                    end
                end else begin
                    x <= x + 1'b1;
                end
            end
        end
    end
endmodule
