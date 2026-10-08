// ============================================================================
// st_canny_dth -- wave2 selftest cell for idx8 DTH (canny_dth).
//   start -> w2_img_stim (32x32 frame 0) -> canny_grad -> canny_dth
//   The DUT is fed the RAW Sobel magnitude stream (its input contract is
//   "mag stream + valid"); the NMS->DTH adjacency is exercised in
//   st_canny_hyst.  TH_LO=100 / TH_HI=200 gives a 21/54/949 none/weak/
//   strong mix on this stimulus.
//   digest = FNV-1a over the 2-bit class stream (zero-extended bytes).
//   EXP comes ONLY from tools/golden_canny.py (T1).  Verdict uses === (T6).
// ============================================================================
module st_canny_dth (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam IMG_W = 32;
    localparam IMG_H = 32;
    localparam [31:0] EXP = 32'hE2A5329F;   // golden_canny.py DTH DIGEST

    `include "w2_fnv.vh"

    reg  run;
    wire ce = clk_en & run;

    // stimulus -> gradient stage
    wire [7:0] s_pix;
    wire       s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done)
    );

    wire [7:0] g_mag;
    wire [1:0] g_dir;
    wire       g_v, g_nl, g_done;
    canny_grad #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_grad (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .mag_out(g_mag), .dir_out(g_dir),
        .out_valid(g_v), .nl_out(g_nl), .done(g_done)
    );

    // DUT
    wire [1:0] d_cls;
    wire       d_v, d_nl;
    canny_dth #(.TH_LO(8'd100), .TH_HI(8'd200)) u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(g_mag), .pix_valid(g_v), .new_line(g_nl),
        .cls_out(d_cls), .out_valid(d_v), .nl_out(d_nl)
    );

    // fold output stream (class as zero-extended byte)
    reg [15:0] npix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            digest <= 32'h811C9DC5;
            npix   <= 16'd0;
        end else if (ce) begin
            if (d_v) begin
                digest <= fnv(digest, {6'b0, d_cls});
                npix   <= npix + 16'd1;
            end
        end
    end

    // sequencer (dth is a pure pipeline: watch the upstream grad done)
    reg [3:0] tail;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run    <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            cycles <= 16'd0;
            tail   <= 4'd0;
        end else if (clk_en) begin
            if (start && !run) run <= 1'b1;
            if (run && !done)  cycles <= cycles + 16'd1;
            if (g_done && !done) begin
                tail <= tail + 4'd1;
                if (tail == 4'd8) begin
                    done <= 1'b1;
                    pass <= (digest === EXP) && (npix == IMG_W * IMG_H);
                end
            end
        end
    end
endmodule
