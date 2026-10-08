// ============================================================================
// st_canny_nms -- wave2 selftest cell for idx7 NMS (canny_nms).
//   start -> w2_img_stim (32x32 frame 0) -> canny_grad -> canny_nms
//   digest = FNV-1a over the thinned-magnitude output byte stream.
//   EXP comes ONLY from tools/golden_canny.py (T1).  Verdict uses === (T6).
// ============================================================================
module st_canny_nms (
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
    localparam [31:0] EXP = 32'hE28D6593;   // golden_canny.py NMS DIGEST

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
    wire [7:0] d_pix;
    wire       d_v, d_nl, d_done;
    canny_nms #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(g_mag), .dir(g_dir), .pix_valid(g_v), .new_line(g_nl),
        .pix_out(d_pix), .out_valid(d_v), .nl_out(d_nl), .done(d_done)
    );

    // fold output stream
    reg [15:0] npix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            digest <= 32'h811C9DC5;
            npix   <= 16'd0;
        end else if (ce) begin
            if (d_v) begin
                digest <= fnv(digest, d_pix);
                npix   <= npix + 16'd1;
            end
        end
    end

    // sequencer
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
            if (d_done && !done) begin
                tail <= tail + 4'd1;
                if (tail == 4'd8) begin
                    done <= 1'b1;
                    pass <= (digest === EXP) && (npix == IMG_W * IMG_H);
                end
            end
        end
    end
endmodule
