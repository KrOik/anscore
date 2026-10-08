// ============================================================================
// st_isp_rgb2gray -- selftest cell for isp_rgb2gray (wave2 unit contract).
//   stim (w2_img_stim 32x32x1, `pix24`) -> isp_rgb2gray -> FNV fold of Y.
// EXP comes ONLY from tools/golden_isp.py (T1).  Verdict uses === (T6).
// ============================================================================
module st_isp_rgb2gray (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam [31:0] EXP    = 32'h9D413162;   // golden_isp.py GRY DIGEST
    localparam        IMG_W  = 32;
    localparam        IMG_H  = 32;
    localparam [15:0] NPIX   = IMG_W * IMG_H;

    `include "w2_fnv.vh"

    reg run = 1'b0;
    wire cev = (clk_en & run) | ~rst_n;

    wire [23:0] s_p24;
    wire        s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix(), .pix24(s_p24), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done));

    wire [7:0] o_dat;
    wire       o_v, o_nl;
    isp_rgb2gray u_dut (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix24(s_p24), .pix_valid(s_pv), .new_line(s_nl),
        .pix_out(o_dat), .out_valid(o_v), .nl_out(o_nl));

    reg [3:0]  tail;
    reg [15:0] ocnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run    <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            digest <= 32'h811C9DC5;
            cycles <= 16'd0;
            tail   <= 4'd0;
            ocnt   <= 16'd0;
        end else if (clk_en) begin
            if (start && !run) run <= 1'b1;
            if (run && !done) begin
                cycles <= cycles + 16'd1;
                if (o_v) begin
                    digest <= fnv(digest, o_dat);
                    ocnt   <= ocnt + 16'd1;
                end
                if (s_done) begin
                    if (tail == 4'd8) begin
                        done <= 1'b1;
                        pass <= (digest === EXP) && (ocnt === NPIX);
                    end else begin
                        tail <= tail + 4'd1;
                    end
                end
            end
        end
    end
endmodule
