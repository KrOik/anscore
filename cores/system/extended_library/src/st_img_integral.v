// ============================================================================
// st_img_integral -- selftest cell for img_integral (wave2 idx14, TAG=INT).
// Chain: w2_img_stim(32x32) -> img_integral -> FNV-1a digest.
// Output stream folded per pixel: 4 bytes little-endian of int_out.
// EXP digest comes from tools/golden_feat.py (trap T1 -- never backfill).
// ============================================================================
module st_img_integral (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam [31:0] EXP  = 32'h18ED7B54;
    localparam [15:0] NEXP = 16'd1024;

`include "w2_fnv.vh"

    reg run;
    wire ce = (clk_en & run) | ~rst_n;

    wire [7:0]  s_pix;
    wire        s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done));

    wire [31:0] o_int;
    wire        o_v, d_done;
    img_integral #(.IMG_W(32), .IMG_H(32)) u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .int_out(o_int), .out_valid(o_v), .done(d_done));

    reg [15:0] nout;
    reg [3:0]  tail;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run    <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            digest <= 32'h811C9DC5;
            cycles <= 16'd0;
            nout   <= 16'd0;
            tail   <= 4'd0;
        end else if (clk_en) begin
            if (start && !run) begin
                run    <= 1'b1;
                cycles <= 16'd0;
            end else if (run && !done) begin
                cycles <= cycles + 16'd1;
            end
            if (run && !done) begin
                if (o_v) begin
                    digest <= fnv(fnv(fnv(fnv(digest,
                        o_int[7:0]), o_int[15:8]),
                        o_int[23:16]), o_int[31:24]);
                    nout   <= nout + 16'd1;
                end
                if (d_done) begin
                    tail <= tail + 4'd1;
                    if (tail == 4'd10) begin
                        done <= 1'b1;
                        pass <= (digest === EXP) && (nout === NEXP);
                    end
                end
            end
        end
    end
endmodule
