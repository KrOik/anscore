// ============================================================================
// st_isp_dpc -- selftest cell for isp_dpc (wave2 unit contract, see SPEC.md).
//   stim (w2_img_stim 32x32x1, `pix`) -> win3x3_gen -> isp_dpc -> FNV fold.
// EXP comes ONLY from tools/golden_isp.py (T1).  Verdict uses === (T6).
// ============================================================================
module st_isp_dpc (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam [31:0] EXP    = 32'h660DE1FA;   // golden_isp.py DPC DIGEST
    localparam        IMG_W  = 32;
    localparam        IMG_H  = 32;
    localparam [15:0] NPIX   = IMG_W * IMG_H;

    `include "w2_fnv.vh"

    reg run = 1'b0;
    wire cev = (clk_en & run) | ~rst_n;

    wire [7:0]  s_pix;
    wire        s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done));

    wire [71:0] w_win;
    wire        w_v, w_nl, w_done;
    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .win(w_win), .win_valid(w_v), .new_line_out(w_nl), .done(w_done));

    wire [7:0] o_dat;
    wire       o_v, o_nl;
    isp_dpc #(.THR(8'd32)) u_dut (
        .clk(clk), .clk_en(cev), .rst_n(rst_n),
        .win(w_win), .win_valid(w_v), .new_line_out(w_nl),
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
                if (w_done) begin
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
