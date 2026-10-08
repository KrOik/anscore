// ============================================================================
// tmr_voter -- triple-modular-redundancy majority voter (wave2 idx37, TAG TMR).
//
//   y[i]   = majority(a[i], b[i], c[i])        (bitwise)
//   mism_x = operand x disagrees with y        (per-operand flag)
//   err    = any operand disagrees this beat
//   err_cnt = sticky saturating count of err beats (clr_cnt clears)
//
// in_valid beat -> y/mism_*/err/out_valid registered the next clk_en beat
// (1-beat latency, fully pipelined).
//
// tmr_reg (same file): demo wrapper -- triplicated W-bit register with
// per-replica XOR fault-injection on write, voted one beat after each write
// (wr_d) so the voter sees the post-write replica state.  y stays correct
// under any single-replica fault; mism_* identify the bad replica.
//
// All registers clk_en gated (T2); no RAM, no multipliers.
// ============================================================================
module tmr_voter #(
    parameter W = 8
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire [W-1:0] c,
    input  wire        clr_cnt,
    output reg         out_valid,
    output reg  [W-1:0] y,
    output reg         mism_a,
    output reg         mism_b,
    output reg         mism_c,
    output reg         err,
    output reg  [15:0] err_cnt
);
    wire [W-1:0] maj  = (a & b) | (a & c) | (b & c);
    wire         e_a  = (a !== maj);   // case-inequality: X-safe flags
    wire         e_b  = (b !== maj);
    wire         e_c  = (c !== maj);
    wire         e_any = e_a | e_b | e_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            y         <= {W{1'b0}};
            mism_a    <= 1'b0;
            mism_b    <= 1'b0;
            mism_c    <= 1'b0;
            err       <= 1'b0;
            err_cnt   <= 16'd0;
        end else if (clk_en) begin
            out_valid <= in_valid;
            err       <= 1'b0;
            if (in_valid) begin
                y      <= maj;
                mism_a <= e_a;
                mism_b <= e_b;
                mism_c <= e_c;
                err    <= e_any;
                if (e_any && (err_cnt != 16'hFFFF))
                    err_cnt <= err_cnt + 16'd1;
            end
            if (clr_cnt) err_cnt <= 16'd0;
        end
    end
endmodule

// ----------------------------------------------------------------------------
// tmr_reg -- triplicated register + voter feedback (demo wrapper for TMR).
//   wr beat: ra<=din^fa, rb<=din^fb, rc<=din^fc  (fa/fb/fc = fault masks,
//   normally 0; the selftest drives a single-bit mask on one replica).
//   Next beat the voter samples ra/rb/rc: y = corrected value, mism_* flag
//   the faulted replica, err_cnt accumulates one count per bad write.
// ----------------------------------------------------------------------------
module tmr_reg #(
    parameter W = 8
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        wr,
    input  wire [W-1:0] din,
    input  wire [W-1:0] fa,
    input  wire [W-1:0] fb,
    input  wire [W-1:0] fc,
    input  wire        clr_cnt,
    output wire [W-1:0] y,
    output wire        y_valid,
    output wire        mism_a,
    output wire        mism_b,
    output wire        mism_c,
    output wire        err,
    output wire [15:0] err_cnt
);
    reg [W-1:0] ra, rb, rc;
    reg         wr_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ra   <= {W{1'b0}};
            rb   <= {W{1'b0}};
            rc   <= {W{1'b0}};
            wr_d <= 1'b0;
        end else if (clk_en) begin
            wr_d <= wr;
            if (wr) begin
                ra <= din ^ fa;
                rb <= din ^ fb;
                rc <= din ^ fc;
            end
        end
    end

    tmr_voter #(.W(W)) u_v (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .in_valid(wr_d), .a(ra), .b(rb), .c(rc), .clr_cnt(clr_cnt),
        .out_valid(y_valid), .y(y),
        .mism_a(mism_a), .mism_b(mism_b), .mism_c(mism_c),
        .err(err), .err_cnt(err_cnt));
endmodule
