// ============================================================================
// st_bnn_conv3x3 -- selftest cell for bnn_conv3x3 (idx35, TAG BC3).
//
// Stimulus: w2_img_stim 16x16x1 frame, binarised as bit = (pix > 8'd128).
// DUT: bnn_conv3x3 IMG_W=IMG_H=16, NCH=2 with fixed config
//   ch0: w9 = 9'b101100101 (0x165), thr = 5
//   ch1: w9 = 9'b011010011 (0x0D3), thr = 4
// Output stream folded into FNV-1a: one byte per emitted window,
//   byte = {6'b0, out[1], out[0]}  (256 windows -> 256 bytes).
// Internal checks: exactly 256 windows and 16 out_nl pulses seen.
// EXP comes from tools/golden_acc.py only (trap T1).
// ============================================================================
module st_bnn_conv3x3 (
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

    localparam [31:0] EXP = 32'hCE422C28;   // golden_acc.py BC3
    localparam        NBYTES = 256;         // IMG_W*IMG_H

    // config driven constant into the DUT
    localparam [17:0] WCFG  = {9'b011010011, 9'b101100101};  // {ch1, ch0}
    localparam [7:0]  THCFG = {4'd4, 4'd5};                  // {ch1, ch0}

    reg         running;
    reg  [31:0] dg;
    reg         ok;
    reg  [15:0] nwin;
    reg  [7:0]  nnl;
    // TB dump hook: mirrors every byte folded into the digest
    // (dbg_cnt bytes per beat, low byte first)
    reg  [31:0] dbg_data;
    reg  [2:0]  dbg_cnt;

    wire dut_ce = (clk_en && running) || !rst_n;

    // ---------------- stimulus: image stream -> binary -----------------
    wire [7:0] s_pix;
    wire       s_pv, s_nl;
    w2_img_stim #(.IMG_W(16), .IMG_H(16), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(dut_ce), .rst_n(rst_n),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done());

    wire s_bin = (s_pix > 8'd128);

    // ---------------- DUT ----------------------------------------------
    wire [1:0] d_out;
    wire       d_v, d_nl, d_done;
    bnn_conv3x3 #(.IMG_W(16), .IMG_H(16), .NCH(2)) u_dut (
        .clk(clk), .clk_en(dut_ce), .rst_n(rst_n),
        .pix(s_bin), .pix_valid(s_pv), .new_line(s_nl),
        .wcfg(WCFG), .thcfg(THCFG),
        .out(d_out), .out_valid(d_v), .out_nl(d_nl), .done(d_done));

    // ---------------- control / digest ---------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            done      <= 1'b0;
            pass      <= 1'b0;
            digest    <= 32'h811C9DC5;
            cycles    <= 16'd0;
            dg        <= 32'h811C9DC5;
            ok        <= 1'b1;
            nwin      <= 16'd0;
            nnl       <= 8'd0;
            dbg_data  <= 32'd0;
            dbg_cnt   <= 3'd0;
        end else if (clk_en) begin
            dbg_cnt <= 3'd0;
            if (start && !running && !done) begin
                running <= 1'b1;
                cycles  <= 16'd0;
                dg      <= 32'h811C9DC5;
                ok      <= 1'b1;
                nwin    <= 16'd0;
                nnl     <= 8'd0;
            end else if (running && !done) begin
                cycles <= cycles + 16'd1;
                if (d_v) begin
                    dg       <= fnv(dg, {6'b0, d_out});
                    dbg_data <= {24'b0, 6'b0, d_out};
                    dbg_cnt  <= 3'd1;
                    nwin     <= nwin + 16'd1;
                    if (d_nl) nnl <= nnl + 8'd1;
                end
                // finish one beat after the last window so dg has settled
                if (nwin == NBYTES[15:0]) begin
                    done   <= 1'b1;
                    digest <= dg;
                    pass   <= (dg === EXP) && ok && (nnl == 8'd16);
                end
            end
        end
    end
endmodule
