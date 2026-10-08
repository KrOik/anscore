// ============================================================================
// st_match_sad -- selftest cell for match_sad (TAG SAD, idx18).
// The 8x8 template is the exact w2_img_stim pixel formula evaluated at
// patch origin (TX,TY) = (10,9), loaded through the DUT's t_* port over
// 64 beats after start; matching begins once the frame is streamed AND the
// template is loaded.  Digest = FNV-1a over 625 x {sad_lo,sad_hi} plus
// {best_x,best_y,min_lo,min_hi}.  Internal check: best=(10,9), min=0.
// EXP comes from tools/golden_geom.py only (T1).
// ============================================================================
module st_match_sad (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    `include "w2_fnv.vh"
    localparam [31:0] EXP = 32'hA661F628;
    localparam [7:0]  TX  = 8'd10;
    localparam [7:0]  TY  = 8'd9;

    // stimulus pixel formula, verbatim copy of w2_img_stim (fidx=0)
    function [7:0] tpix;
        input [5:0] idx;
        reg [7:0] x, y, base;
        reg       boost;
        begin
            x     = TX + {5'd0, idx[2:0]};
            y     = TY + {5'd0, idx[5:3]};
            base  = (x + (x << 4)) ^ (y + (y << 3) + (y << 5)) ^
                    ((x & y) << 3);
            boost = (x >= 8'd6) && (x <= 8'd9) &&
                    (y >= 8'd5) && (y <= 8'd10);
            tpix  = boost ? (base + 8'h50) : base;
        end
    endfunction

    reg        running;
    reg  [1:0] tail;
    wire       arst = rst_n & running;

    wire [7:0] s_pix;
    wire       s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(clk_en), .rst_n(arst),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done));

    // template loader: 64 beats after start
    reg  [6:0] tli;              // 0..64
    reg        tpl_done;
    wire       t_we    = running && !tpl_done;
    wire [5:0] t_addr  = tli[5:0];
    wire [7:0] t_data  = tpix(tli[5:0]);

    // go: one-beat pulse when frame AND template are in place.
    // stim_done asserts during the LAST pix_valid beat (while the DUT is
    // still in S_WR), so delay it one beat to land the pulse inside S_IDLE.
    reg        sd_d;
    reg        go_sent;
    wire       go = running && tpl_done && sd_d && !go_sent;

    wire [7:0] o_pix;
    wire       o_v, o_done;
    wire [7:0] o_bx, o_by;
    wire [15:0] o_min;
    match_sad #(.IMG_W(32), .IMG_H(32)) u_dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .t_we(t_we), .t_addr(t_addr), .t_data(t_data),
        .go(go),
        .pix_out(o_pix), .out_valid(o_v), .done(o_done),
        .best_x(o_bx), .best_y(o_by), .min_sad(o_min));

    reg  [7:0] o_byte;
    reg        o_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running  <= 1'b0;
            tail     <= 2'd0;
            tli      <= 7'd0;
            tpl_done <= 1'b0;
            go_sent  <= 1'b0;
            sd_d     <= 1'b0;
            done     <= 1'b0;
            pass     <= 1'b0;
            digest   <= 32'h811C9DC5;
            cycles   <= 16'd0;
            o_byte   <= 8'd0;
            o_valid  <= 1'b0;
        end else if (clk_en) begin
            if (start) running <= 1'b1;
            if (running && !done) cycles <= cycles + 16'd1;
            if (t_we) begin
                tli <= tli + 7'd1;
                if (tli == 7'd63) tpl_done <= 1'b1;
            end
            sd_d <= s_done;
            if (go) go_sent <= 1'b1;
            o_valid <= 1'b0;
            if (o_v) begin
                digest  <= fnv(digest, o_pix);
                o_byte  <= o_pix;
                o_valid <= 1'b1;
            end
            if (o_done && !done) begin
                tail <= tail + 2'd1;
                if (tail == 2'd2) begin
                    done <= 1'b1;
                    pass <= (digest === EXP) &&
                            (o_bx === TX) && (o_by === TY) &&
                            (o_min === 16'd0);
                end
            end
        end
    end
endmodule
