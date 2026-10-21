// ============================================================================
// w2_img_stim -- deterministic multi-frame test-image streamer (wave2).
//
// Per clk_en beat: one new_line beat, then IMG_W pix_valid beats; repeats for
// IMG_H rows = one frame; repeats for N_FRAMES frames, then stim_done.
// `fidx` is the current frame index (0-based), exposed for multi-frame units.
//
// PIXEL FORMULA (fixed -- golden models MUST replicate exactly):
//   base = (x + x<<4) ^ (y + y<<3 + y<<5) ^ ((x & y) << 3)      [mod 256]
//   boost region (moving bright square): sx0 = 6 + 2*fidx,
//        sy0 = 5 + fidx ;  boost = (sx0 <= x <= sx0+3) && (sy0 <= y <= sy0+5)
//        (coordinate compare done in full precision, then clamped by frame)
//   pix = base + 8'h50 when boost else base                    [mod 256]
//
//   pix24 = { r, g, b } with r = pix, g = pix ^ 8'h5A,
//                            b = pix + 8'h3C                  [mod 256]
// (fixed pseudo-colour mapping for RGB-input units; the Bayer units use `pix`
//  as the raw sensor value and derive colour phase from (x,y) parity).
//
// All arithmetic is shift/add on 8-bit values (no multipliers, wraps mod 256).
// pix/pix24 are registered so they are stable for the whole pix_valid beat.
// ============================================================================
module w2_img_stim #(
    parameter IMG_W    = 32,
    parameter IMG_H    = 32,
    parameter N_FRAMES = 1
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    output reg  [7:0]  pix,
    output wire [23:0] pix24,
    output reg         pix_valid,
    output reg         new_line,
    output reg  [7:0]  fidx,
    output reg         stim_done
);
    localparam CW = (IMG_W > 1) ? $clog2(IMG_W) : 1;
    localparam RW = (IMG_H > 1) ? $clog2(IMG_H) : 1;
    localparam FW = (N_FRAMES > 1) ? $clog2(N_FRAMES) : 1;

    reg [RW-1:0] y;
    reg [CW-1:0] x;
    reg          nl_pending;   // next beat issues the new_line pulse

    wire [7:0] x8 = {{(8-CW){1'b0}}, x};
    wire [7:0] y8 = {{(8-RW){1'b0}}, y};
    wire [7:0] f8 = fidx;
    wire [7:0] base = (x8 + (x8 << 4)) ^ (y8 + (y8 << 3) + (y8 << 5)) ^
                      ((x8 & y8) << 3);
    wire [15:0] sx0 = 16'd6 + {9'd0, f8, 1'b0};      // 6 + 2*fidx
    wire [15:0] sy0 = 16'd5 + {8'd0, f8};            // 5 + fidx
    wire boost = ({8'd0, x8} >= sx0) && ({8'd0, x8} <= sx0 + 16'd3) &&
                 ({8'd0, y8} >= sy0) && ({8'd0, y8} <= sy0 + 16'd5);
    wire [7:0] fpix = boost ? (base + 8'h50) : base;

    assign pix24 = {fpix, fpix ^ 8'h5A, fpix + 8'h3C};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y          <= {RW{1'b0}};
            x          <= {CW{1'b0}};
            fidx       <= {FW{1'b0}};
            nl_pending <= 1'b1;
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
                        y <= {RW{1'b0}};
                        if (fidx == N_FRAMES - 1) begin
                            stim_done <= 1'b1;
                        end else begin
                            fidx       <= fidx + 1'b1;
                            nl_pending <= 1'b1;
                        end
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
