// ============================================================================
// st_frame_diff -- selftest cell for idx20 FDIF (frame_diff).
// Contract per SPEC.md: clk/clk_en/rst_n/start -> done/pass/digest/cycles.
// Stimulus: w2_img_stim IMG_W=32 IMG_H=32 N_FRAMES=3 (bright square moves
// +2x/+1y per frame).  DUT emits |curr-prev|>THR mask bytes for frames 1..2;
// each emitted byte folds into FNV-1a.  EXP comes ONLY from
// tools/golden_temp.py (trap T1); verdict uses === (trap T6).
// ============================================================================
module st_frame_diff (
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
    localparam IMG_W    = 32;
    localparam IMG_H    = 32;
    localparam N_FRAMES = 3;
    localparam THR      = 32;
    localparam [31:0] EXP   = 32'h6A760EBD;   // golden_temp.py FDIF
    localparam [15:0] EXP_N = 16'd2048;       // 2 frames x 1024 px

    reg        go;
    reg  [3:0] tail;
    reg  [15:0] nbytes;

    wire stim_rst = rst_n & go;
    wire [7:0]  s_pix, s_fidx;
    wire        s_pv, s_nl;
    w2_img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H), .N_FRAMES(N_FRAMES)) u_stim (
        .clk(clk), .clk_en(clk_en), .rst_n(stim_rst),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(s_fidx), .stim_done());

    wire [7:0] d_ob, d_fo;
    wire       d_ov, d_nl, d_done;
    frame_diff #(.IMG_W(IMG_W), .IMG_H(IMG_H),
                 .N_FRAMES(N_FRAMES), .THR(THR)) u_dut (
        .clk(clk), .clk_en(clk_en), .rst_n(stim_rst),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl), .fidx(s_fidx),
        .mask_out(d_ob), .out_valid(d_ov), .nl_out(d_nl), .fidx_out(d_fo),
        .done(d_done));

    // TB-visible output stream for byte dump (hierarchical reference)
    wire [7:0] dbg_byte = d_ob;
    wire       dbg_v    = d_ov;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            go     <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            digest <= 32'h811C9DC5;
            cycles <= 16'd0;
            tail   <= 4'd0;
            nbytes <= 16'd0;
        end else if (clk_en) begin
            if (start && !go) begin
                go     <= 1'b1;
                digest <= 32'h811C9DC5;
                cycles <= 16'd0;
                nbytes <= 16'd0;
                tail   <= 4'd0;
                done   <= 1'b0;
                pass   <= 1'b0;
            end else if (go && !done) begin
                cycles <= cycles + 16'd1;
                if (d_ov) begin
                    digest <= fnv(digest, d_ob);
                    nbytes <= nbytes + 16'd1;
                end
                if (d_done) begin
                    tail <= tail + 4'd1;
                    if (tail == 4'd4) begin
                        done <= 1'b1;
                        pass <= (digest === EXP) && (nbytes === EXP_N);
                    end
                end
            end
        end
    end
endmodule
