// Streaming correlation / matched-filter core for DSP-06.
// Contract in ../SPEC.md: signed real/complex samples, runtime template of
// 1..MAX_TAPS signed DW-bit (re,im) taps, optional template conjugation and
// convolution/correlation direction, VALID/FULL block-tail modes, one
// full-precision correlation result per emitted position plus a per-frame
// earliest-tie argmax summary. Two DWxDW multipliers serve a serialized
// tap MAC (real: ntaps cycles/output, complex: 2*ntaps cycles/output);
// no II1 or routed-timing claim. History and template are plain registers;
// no RAM read data is held across stalls.
module correlation_stream #(
    parameter DW = 16,
    parameter MAX_TAPS = 64,
    parameter ACCW = 48,
    parameter POSW = 16
)(
    input  wire                    clk, rst_n,
    input  wire [2*DW-1:0]         s_tdata,   // {im, re}; im ignored in real mode
    input  wire                    s_tvalid, s_tuser, s_tlast,
    output wire                    s_tready,
    output reg  [2*ACCW-1:0]       m_tdata,   // {im, re} correlation value
    output reg  [POSW-1:0]         m_pos,     // lag index n of this output
    output reg                     m_tuser, m_tlast, m_tvalid,
    input  wire                    m_ready,
    output reg  [POSW-1:0]         p_pos,     // argmax lag, earliest on tie
    output reg  [2*ACCW-1:0]       p_tdata,   // correlation value at argmax
    output reg  [ACCW:0]           p_mag,     // winning |re|+|im| proxy
    output reg                     p_error,   // frame produced no output
    output reg                     p_valid,
    input  wire                    p_ready,
    input  wire                    cfg_valid,
    output wire                    cfg_ready,
    input  wire [6:0]              cfg_ntaps, // 1..MAX_TAPS
    input  wire [3:0]              cfg_mode,  // [0]=complex [1]=dir [2]=conj [3]=0
    input  wire [1:0]              cfg_tail,  // 0=VALID 1=FULL
    input  wire [MAX_TAPS*2*DW-1:0] cfg_taps, // tap k at [2*DW*k +: 2*DW]={im,re}
    output reg                     cfg_done, cfg_error,
    output reg                     marker_error
);
    localparam IDLE=2'd0, MAC=2'd1, EMIT=2'd2, PK=2'd3;
    reg [1:0] state;
    reg [6:0] ntaps;
    reg cplx, dir, conj, tail_full;
    reg signed [DW-1:0] hist_re [0:MAX_TAPS-1];
    reg signed [DW-1:0] hist_im [0:MAX_TAPS-1];
    reg signed [DW-1:0] tap_re  [0:MAX_TAPS-1];
    reg signed [DW-1:0] tap_im  [0:MAX_TAPS-1];
    reg signed [ACCW-1:0] acc_re, acc_im;
    reg [7:0] j;
    reg [POSW-1:0] idx, flen, n_out;
    reg in_frame, frame_done, group_started;
    reg [6:0] tail_cnt;
    reg [POSW-1:0] b_pos;
    reg signed [ACCW-1:0] b_re, b_im;
    reg [ACCW:0] b_mag;
    reg b_valid;

    assign s_tready  = rst_n && state==IDLE && !(cfg_valid && !in_frame);
    assign cfg_ready = rst_n && state==IDLE && !in_frame;
    wire accept = s_tvalid && s_tready;

    wire starting = s_tuser || !in_frame;
    wire idx_wrap = !starting && (idx=={POSW{1'b1}});
    wire [POSW-1:0] idx_next  = starting ? {POSW{1'b0}} : idx + 1'b1;
    wire [POSW-1:0] flen_next = starting ? {{POSW-1{1'b0}},1'b1} :
        (flen=={POSW{1'b1}} ? flen : flen + 1'b1);
    wire [POSW-1:0] ntaps_ext = {{(POSW-7){1'b0}}, ntaps};
    wire emit_now = tail_full || (idx_next + 1'b1 >= ntaps_ext);

    // Serialized MAC step operands. hist[k] holds the sample k positions back;
    // tap index tk selects correlation (reversed) or convolution order.
    wire [6:0] k  = cplx ? j[7:1] : j[6:0];
    wire [6:0] tk = dir ? k : ntaps - 7'd1 - k;
    wire ph = cplx && j[0];
    reg signed [DW-1:0] a0, b0, a1, b1;
    always @* begin
        a0 = hist_re[k]; b0 = {DW{1'b0}};
        a1 = {DW{1'b0}}; b1 = {DW{1'b0}};
        if (cplx) begin
            a1 = hist_im[k];
            if (ph) begin b0 = tap_im[tk]; b1 = tap_re[tk]; end
            else    begin b0 = tap_re[tk]; b1 = tap_im[tk]; end
        end else b0 = tap_re[tk];
    end
    wire signed [2*DW-1:0] p0 = a0 * b0;
    wire signed [2*DW-1:0] p1 = a1 * b1;
    wire signed [ACCW-1:0] p0e = {{(ACCW-2*DW){p0[2*DW-1]}}, p0};
    wire signed [ACCW-1:0] p1e = {{(ACCW-2*DW){p1[2*DW-1]}}, p1};
    reg signed [ACCW-1:0] d_re, d_im;
    always @* begin
        d_re = {ACCW{1'b0}}; d_im = {ACCW{1'b0}};
        if (cplx) begin
            if (ph) d_im = conj ? p1e - p0e : p0e + p1e;
            else    d_re = conj ? p0e + p1e : p0e - p1e;
        end else d_re = p0e;
    end
    wire signed [ACCW-1:0] nxt_re = acc_re + d_re;
    wire signed [ACCW-1:0] nxt_im = acc_im + d_im;
    wire [7:0] steps = cplx ? {ntaps, 1'b0} : {1'b0, ntaps};
    wire last_step = (j == steps - 8'd1);
    wire [ACCW-1:0] are = nxt_re[ACCW-1] ? -nxt_re : nxt_re;
    wire [ACCW-1:0] aim = nxt_im[ACCW-1] ? -nxt_im : nxt_im;
    wire [ACCW:0] mag = {1'b0, are} + {1'b0, aim};

    wire bad_cfg = (cfg_ntaps < 7'd1) || (cfg_ntaps > MAX_TAPS) ||
                   (cfg_tail > 2'd1) || cfg_mode[3] ||
                   (cfg_mode[2] && !cfg_mode[0]);

    integer t;
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE; ntaps <= 7'd1;
            cplx <= 1'b0; dir <= 1'b0; conj <= 1'b0; tail_full <= 1'b0;
            acc_re <= {ACCW{1'b0}}; acc_im <= {ACCW{1'b0}}; j <= 8'd0;
            idx <= {POSW{1'b0}}; flen <= {POSW{1'b0}}; n_out <= {POSW{1'b0}};
            in_frame <= 1'b0; frame_done <= 1'b0; group_started <= 1'b0;
            tail_cnt <= 7'd0;
            b_pos <= {POSW{1'b0}}; b_re <= {ACCW{1'b0}}; b_im <= {ACCW{1'b0}};
            b_mag <= {(ACCW+1){1'b0}}; b_valid <= 1'b0;
            m_tdata <= {(2*ACCW){1'b0}}; m_pos <= {POSW{1'b0}};
            m_tuser <= 1'b0; m_tlast <= 1'b0; m_tvalid <= 1'b0;
            p_pos <= {POSW{1'b0}}; p_tdata <= {(2*ACCW){1'b0}};
            p_mag <= {(ACCW+1){1'b0}}; p_error <= 1'b0; p_valid <= 1'b0;
            cfg_done <= 1'b0; cfg_error <= 1'b0; marker_error <= 1'b0;
            for (t = 0; t < MAX_TAPS; t = t + 1) begin
                hist_re[t] <= {DW{1'b0}}; hist_im[t] <= {DW{1'b0}};
                tap_re[t] <= {DW{1'b0}}; tap_im[t] <= {DW{1'b0}};
            end
            tap_re[0] <= {1'b0, {(DW-1){1'b1}}};  // +full-scale impulse
        end else begin
            cfg_done <= 1'b0; cfg_error <= 1'b0;
            if (cfg_valid && cfg_ready) begin
                cfg_done <= 1'b1; cfg_error <= bad_cfg;
                if (!bad_cfg) begin
                    ntaps <= cfg_ntaps; cplx <= cfg_mode[0];
                    dir <= cfg_mode[1]; conj <= cfg_mode[2];
                    tail_full <= cfg_tail[0];
                    for (t = 0; t < MAX_TAPS; t = t + 1) begin
                        tap_re[t] <= cfg_taps[2*DW*t +: DW];
                        tap_im[t] <= cfg_taps[2*DW*t + DW +: DW];
                    end
                end
            end else case (state)
                IDLE: if (accept) begin
                    if ((s_tuser && in_frame) || (!s_tuser && !in_frame) || idx_wrap)
                        marker_error <= 1'b1;
                    idx <= idx_next; flen <= flen_next;
                    in_frame <= !s_tlast; frame_done <= s_tlast; tail_cnt <= 7'd0;
                    for (t = MAX_TAPS-1; t > 0; t = t - 1) begin
                        hist_re[t] <= starting ? {DW{1'b0}} : hist_re[t-1];
                        hist_im[t] <= (starting || !cplx) ? {DW{1'b0}} : hist_im[t-1];
                    end
                    hist_re[0] <= s_tdata[DW-1:0];
                    hist_im[0] <= cplx ? s_tdata[2*DW-1:DW] : {DW{1'b0}};
                    acc_re <= {ACCW{1'b0}}; acc_im <= {ACCW{1'b0}}; j <= 8'd0;
                    if (starting) begin
                        group_started <= 1'b0; b_valid <= 1'b0;
                        b_pos <= {POSW{1'b0}}; b_re <= {ACCW{1'b0}};
                        b_im <= {ACCW{1'b0}}; b_mag <= {(ACCW+1){1'b0}};
                    end
                    if (emit_now) begin
                        n_out <= idx_next; state <= MAC;
                    end else if (s_tlast) begin
                        // VALID frame shorter than the template: no outputs.
                        p_pos <= {POSW{1'b1}}; p_tdata <= {(2*ACCW){1'b0}};
                        p_mag <= {(ACCW+1){1'b0}};
                        p_error <= 1'b1; p_valid <= 1'b1; state <= PK;
                    end
                end
                MAC: begin
                    acc_re <= nxt_re; acc_im <= nxt_im;
                    if (last_step) begin
                        m_tdata <= {nxt_im, nxt_re};
                        m_pos <= n_out;
                        m_tuser <= !group_started;
                        m_tlast <= frame_done && ((tail_cnt == 7'd0)
                            ? (!tail_full || ntaps == 7'd1)
                            : (tail_cnt == ntaps - 7'd1));
                        m_tvalid <= 1'b1;
                        group_started <= 1'b1;
                        if (!b_valid || mag > b_mag) begin
                            b_valid <= 1'b1; b_pos <= n_out;
                            b_re <= nxt_re; b_im <= nxt_im; b_mag <= mag;
                        end
                        state <= EMIT;
                    end else j <= j + 8'd1;
                end
                EMIT: if (m_ready) begin
                    m_tvalid <= 1'b0;
                    if (frame_done && tail_full && tail_cnt < ntaps - 7'd1) begin
                        // Zero tail input: emit remaining FULL-mode positions.
                        for (t = MAX_TAPS-1; t > 0; t = t - 1) begin
                            hist_re[t] <= hist_re[t-1];
                            hist_im[t] <= hist_im[t-1];
                        end
                        hist_re[0] <= {DW{1'b0}}; hist_im[0] <= {DW{1'b0}};
                        if (n_out == {POSW{1'b1}}) marker_error <= 1'b1;
                        tail_cnt <= tail_cnt + 7'd1;
                        n_out <= n_out + {{POSW-1{1'b0}}, 1'b1};
                        acc_re <= {ACCW{1'b0}}; acc_im <= {ACCW{1'b0}};
                        j <= 8'd0; state <= MAC;
                    end else if (frame_done) begin
                        p_pos <= b_pos; p_tdata <= {b_im, b_re}; p_mag <= b_mag;
                        p_error <= 1'b0; p_valid <= 1'b1; state <= PK;
                    end else state <= IDLE;
                end
                PK: if (p_ready) begin
                    p_valid <= 1'b0; p_error <= 1'b0; state <= IDLE;
                    in_frame <= 1'b0; frame_done <= 1'b0; group_started <= 1'b0;
                    tail_cnt <= 7'd0; idx <= {POSW{1'b0}}; flen <= {POSW{1'b0}};
                    b_valid <= 1'b0;
                end
            endcase
        end
    end
    initial begin
        if (DW < 4 || DW > 18 || MAX_TAPS < 1 || MAX_TAPS > 64 ||
            ACCW < 2*DW + 8 || POSW < 8)
            $fatal(1, "unsupported correlation_stream parameters");
    end
endmodule
