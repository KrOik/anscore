// ============================================================================
// st_img_crop -- selftest cell for img_crop (TAG CRP, unit idx19).
// ROI = (x0,y0,cw,ch) = (5,7,13,9) over the 32x32 w2_img_stim frame.
// Digest = FNV-1a over cropped pixel bytes (new_line_out beats carry no byte).
// EXP comes from tools/golden_geom.py only (T1).
// ============================================================================
module st_img_crop (
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
    localparam [31:0] EXP = 32'h450E7855;

    reg        running;
    reg  [1:0] tail;
    wire       arst = rst_n & running;      // hold stimulus in reset till start

    wire [7:0] s_pix;
    wire       s_pv, s_nl;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(clk_en), .rst_n(arst),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done());

    wire [7:0] o_pix;
    wire       o_v, o_nl, o_done;
    img_crop #(.IMG_W(32), .IMG_H(32)) u_dut (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .x0(8'd5), .y0(8'd7), .cw(8'd13), .ch(8'd9),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .pix_out(o_pix), .out_valid(o_v), .new_line_out(o_nl),
        .done(o_done));

    // folded-byte mirror for TB dump (sample on clk_en beats)
    reg  [7:0] o_byte;
    reg        o_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
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
                    pass <= (digest === EXP);
                end
            end
        end
    end
endmodule
