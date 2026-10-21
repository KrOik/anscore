// ============================================================================
// ISP-08: AWB statistics source (gray-world estimator support).
//
// Pure observer on a pixel stream segment (in the top level this taps the
// post-BLC / pre-WB bus, the defined statistics source).  Per accepted pixel
// (s_tvalid && s_tready) it accumulates per-channel frame sums; at the frame's
// last pixel it commits the sums to the readable registers and pulses
// awb_new.  No flow control output: this module never backpressures.
//
// Sums are width-exact: SUMW = clog2(WIDTH*HEIGHT*MPX + 1), so overflow is
// impossible by construction (zone <= frame bound, ISP-10/12 proof style).
// Channels >= CH accumulate zero.  A mid-frame reset or frame restart
// discards the partial sums - they are never committed.
//
// Host/model contract: sums + npix feed models/reference.py
// gray_world_gains() which returns the UQ4.8 gains to commit through cfg_wb.
// ============================================================================
module isp_awb_stats #(
    parameter BITS   = 8,
    parameter CH     = 3,
    parameter WIDTH  = 32,
    parameter HEIGHT = 24,
    parameter MPX    = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FP     = (WIDTH<1 || HEIGHT<1) ? 1 : WIDTH*HEIGHT,
    parameter SUMW   = $clog2(FP*MPX+1)    // >= BITS for legal params
)(
    input  wire clk, rst_n,
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tready,        // observed transfer = both high
    output reg  [SUMW-1:0] awb_sum0, awb_sum1, awb_sum2,
    output reg  awb_new,                   // pulse: a frame's sums committed
    output reg  [7:0] awb_frame            // completed-frame counter, mod 256
);
    localparam CW = (FP<2) ? 1 : $clog2(FP);        // in-frame pixel counter
    localparam [CW-1:0] FL = FP - 1;                // last pixel index
    reg [SUMW-1:0] acc0, acc1, acc2;
    reg [CW-1:0]   pcnt;
    wire fire = s_tvalid && s_tready;
    wire last = fire && (pcnt == FL);

    wire [3*BITS-1:0] pext = s_tdata;      // implicit zero extension, CH=1
    wire [BITS-1:0] c0 = pext[0*BITS +: BITS];
    wire [BITS-1:0] c1 = (CH == 3) ? pext[1*BITS +: BITS] : {BITS{1'b0}};
    wire [BITS-1:0] c2 = (CH == 3) ? pext[2*BITS +: BITS] : {BITS{1'b0}};
    // Next-sum wires already include the frame-start reset (pcnt==0), so a
    // 1-pixel frame (pcnt==0 && last) commits the right value.
    wire [SUMW-1:0] n0 = (pcnt == 0) ? {{(SUMW-BITS){1'b0}}, c0} : acc0 + c0;
    wire [SUMW-1:0] n1 = (pcnt == 0) ? {{(SUMW-BITS){1'b0}}, c1} : acc1 + c1;
    wire [SUMW-1:0] n2 = (pcnt == 0) ? {{(SUMW-BITS){1'b0}}, c2} : acc2 + c2;

    always @(posedge clk) begin
        if (!rst_n) begin
            acc0 <= 0; acc1 <= 0; acc2 <= 0; pcnt <= 0;
            awb_sum0 <= 0; awb_sum1 <= 0; awb_sum2 <= 0;
            awb_new <= 0; awb_frame <= 0;
        end else begin
            awb_new <= 0;
            if (fire) begin
                acc0 <= n0; acc1 <= n1; acc2 <= n2;
                if (last) begin
                    pcnt <= 0;
                    awb_sum0 <= n0; awb_sum1 <= n1; awb_sum2 <= n2;
                    awb_new <= 1;
                    awb_frame <= awb_frame + 1'b1;
                end else pcnt <= pcnt + 1'b1;
            end
        end
    end
    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3) ||
            WIDTH < 1 || HEIGHT < 1)
            $fatal(1, "unsupported isp_awb_stats parameters");
    end
endmodule
