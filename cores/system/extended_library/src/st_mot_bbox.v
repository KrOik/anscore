// ============================================================================
// st_mot_bbox -- selftest cell for idx22 BBOX (mot_bbox).
// Contract per SPEC.md: clk/clk_en/rst_n/start -> done/pass/digest/cycles.
// Chain under test: w2_img_stim (3 frames, moving square) -> frame_diff
// (|curr-prev|>32 mask) -> mot_bbox.  mot_bbox emits one 6-byte record
// (minx,miny,maxx,maxy,count_lo,count_hi) per received mask frame; all 12
// bytes fold into FNV-1a.
// EXP comes ONLY from tools/golden_temp.py (T1); verdict uses === (T6).
// ============================================================================
module st_mot_bbox (
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
    localparam [31:0] EXP   = 32'h221B2F39;   // golden_temp.py BBOX
    localparam [15:0] EXP_N = 16'd12;         // 2 records x 6 bytes

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

    // stage 1: frame difference mask stream (emitted for fidx >= 1)
    wire [7:0] m_ob, m_fo;
    wire       m_ov, m_nl;
    frame_diff #(.IMG_W(IMG_W), .IMG_H(IMG_H),
                 .N_FRAMES(N_FRAMES), .THR(THR)) u_fd (
        .clk(clk), .clk_en(clk_en), .rst_n(stim_rst),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl), .fidx(s_fidx),
        .mask_out(m_ob), .out_valid(m_ov), .nl_out(m_nl), .fidx_out(m_fo),
        .done());

    // stage 2: per-frame bounding box of the mask stream (NFR=2 frames)
    wire [7:0] d_ob;
    wire       d_ov, d_done;
    mot_bbox #(.IMG_W(IMG_W), .IMG_H(IMG_H), .NFR(N_FRAMES-1)) u_dut (
        .clk(clk), .clk_en(clk_en), .rst_n(stim_rst),
        .pix(m_ob), .pix_valid(m_ov), .new_line(m_nl), .fidx(m_fo),
        .out_byte(d_ob), .out_valid(d_ov), .done(d_done));

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
