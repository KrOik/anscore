// ============================================================================
// st_img_scaler -- selftest cell for img_scaler (TAG SCL, idx15).
// Two sequential scenarios folded into one digest:
//   phase 0: 32x32 -> 16x16 downscale (DUT_A, stim A)
//   phase 1: 16x16 -> 32x32 upscale  (DUT_B, stim B)
// Each stimulus is held in reset until its phase starts, so the two output
// streams never interleave; digest = FNV-1a over A bytes then B bytes.
// EXP comes from tools/golden_geom.py only (T1).
// ============================================================================
module st_img_scaler (
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
    localparam [31:0] EXP = 32'hA34F3413;

    reg        running;
    reg        phase;
    reg  [1:0] tail;
    wire       arstA = rst_n & running & ~phase;
    wire       arstB = rst_n & running &  phase;

    wire [7:0] sa_pix, sb_pix;
    wire       sa_pv, sa_nl, sb_pv, sb_nl;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(1)) u_stim_a (
        .clk(clk), .clk_en(clk_en), .rst_n(arstA),
        .pix(sa_pix), .pix24(), .pix_valid(sa_pv), .new_line(sa_nl),
        .fidx(), .stim_done());
    w2_img_stim #(.IMG_W(16), .IMG_H(16), .N_FRAMES(1)) u_stim_b (
        .clk(clk), .clk_en(clk_en), .rst_n(arstB),
        .pix(sb_pix), .pix24(), .pix_valid(sb_pv), .new_line(sb_nl),
        .fidx(), .stim_done());

    wire [7:0] a_pix, b_pix;
    wire       a_v, a_nl, a_done, b_v, b_nl, b_done;
    img_scaler #(.IMG_W(32), .IMG_H(32), .OUT_W(16), .OUT_H(16)) u_dut_a (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(sa_pix), .pix_valid(sa_pv), .new_line(sa_nl),
        .pix_out(a_pix), .out_valid(a_v), .new_line_out(a_nl),
        .done(a_done));
    img_scaler #(.IMG_W(16), .IMG_H(16), .OUT_W(32), .OUT_H(32)) u_dut_b (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(sb_pix), .pix_valid(sb_pv), .new_line(sb_nl),
        .pix_out(b_pix), .out_valid(b_v), .new_line_out(b_nl),
        .done(b_done));

    wire [7:0] d_pix = phase ? b_pix : a_pix;
    wire       d_v   = phase ? b_v   : a_v;

    reg  [7:0] o_byte;
    reg        o_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            phase   <= 1'b0;
            tail    <= 2'd0;
            done    <= 1'b0;
            pass    <= 1'b0;
            digest  <= 32'h811C9DC5;
            cycles  <= 16'd0;
            o_byte  <= 8'd0;
            o_valid <= 1'b0;
        end else if (clk_en) begin
            if (start) running <= 1'b1;
            if (running && !done) cycles <= cycles + 16'd1;
            if (a_done && !phase) phase <= 1'b1;
            o_valid <= 1'b0;
            if (d_v) begin
                digest  <= fnv(digest, d_pix);
                o_byte  <= d_pix;
                o_valid <= 1'b1;
            end
            if (b_done && !done) begin
                tail <= tail + 2'd1;
                if (tail == 2'd2) begin
                    done <= 1'b1;
                    pass <= (digest === EXP);
                end
            end
        end
    end
endmodule
