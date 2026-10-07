// ============================================================================
// img_histogram -- 256-bin frame histogram (wave2 unit idx16, TAG HST).
//
// Bins live in one w2_dpram (W=18 counters, DEPTH=256; T9).  Accumulation is
// read-modify-write through the registered-DO read port, so a RMW hazard
// exists.  Timing (clk_en beats):
//   read issued at beat a  -> DOB captured end of a+1 -> q usable at a+2
//   write-back issued at a+2 -> commits at end of a+3
// A read issued at beat b therefore misses exactly the writes whose owning
// pixel was issued at b-2 or b-1 (distance 1..2).  To stay correct when
// pixels arrive with gaps (new_line beats), each pending-update queue entry
// carries the 16-bit issue beat; forwarding applies only when
// (cur_issue_beat - entry_issue_beat) is 1 or 2.  Queue depth 2 suffices
// because at most two pixels can have been issued in the last 2 beats.
//
// Flow: S_CLR zeroes all 256 bins (RAM starts as X) -> S_ACC consumes
// pix_valid beats -> S_FLUSH waits for the tail write -> S_DRN re-reads bins
// 0..255 and emits {count[7:0], count[15:8]} per bin while writing 0 back
// (clear-on-drain, so the unit is re-usable without a reset).
//
// NOTE: pixels are only counted in S_ACC -- drive the source only while the
// `rdy` output is high (it rises after the 256-beat bin clear).
//
// Internal check: drained counts are summed; bins_ok = (sum == IMG_W*IMG_H).
// ============================================================================
module img_histogram #(
    parameter IMG_W = 32,
    parameter IMG_H = 32
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         done,
    output reg         bins_ok,
    output wire        rdy          // high in S_ACC: source may stream
);
    localparam NPIX = IMG_W*IMG_H;
    localparam S_CLR = 3'd0, S_ACC = 3'd1, S_FLUSH = 3'd2,
               S_DRN = 3'd3, S_DONE = 3'd4;

    // ---- bin RAM (18-bit counters, depth 256) -------------------------------
    reg           hre, hwe;
    reg  [7:0]    hraddr, hwaddr;
    reg  [17:0]   hwdata;
    wire [17:0]   hq;
    w2_dpram #(.W(18), .DEPTH(256), .AW(8)) u_bins (
        .clk(clk), .clk_en(clk_en),
        .we(hwe), .waddr(hwaddr), .wdata(hwdata),
        .re(hre), .raddr(hraddr), .q(hq));

    reg  [2:0]  state;
    reg  [1:0]  ph;              // drain sub-phase
    reg  [8:0]  clr_i;           // clear / drain bin index
    reg  [15:0] npix;
    reg  [15:0] bc;              // free-running issue-beat tag counter
    // issue pipeline: pix@t -> iss@t+1 (re/raddr regs) -> read port during
    // t+1 -> DOB loads end of t+1 -> q valid at t+2 = d1 stage.  Capture at d1.
    reg         iss_v, d1_v;
    reg  [7:0]  iss_bin, d1_bin;
    reg  [15:0] iss_tag, d1_tag;
    reg         iss_last, d1_last;
    // forwarding queue (newest = p1, older = p0); tag = issue beat of pixel
    reg         p0_v, p1_v;
    reg  [7:0]  p0_bin, p1_bin;
    reg  [15:0] p0_tag, p1_tag;
    reg  [17:0] p0_val, p1_val;
    reg  [1:0]  fcnt;
    reg  [17:0] dsum;

    // forwarded count for the bin whose q just arrived: entry applies only if
    // this read was issued 1 or 2 beats after the entry's pixel (fd in {1,2})
    wire [15:0] fd1 = d1_tag - p1_tag;
    wire [15:0] fd0 = d1_tag - p0_tag;
    wire        f1  = p1_v && (d1_bin == p1_bin) &&
                      (fd1 == 16'd1 || fd1 == 16'd2);
    wire        f0  = p0_v && (d1_bin == p0_bin) &&
                      (fd0 == 16'd1 || fd0 == 16'd2);
    wire [17:0] cnt  = f1 ? p1_val : (f0 ? p0_val : hq);
    wire [17:0] nval = cnt + 18'd1;
    assign rdy = (state == S_ACC);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_CLR;
            ph      <= 2'd0;
            clr_i   <= 9'd0;
            npix    <= 16'd0;
            bc      <= 16'd0;
            iss_v   <= 1'b0;
            d1_v    <= 1'b0;
            iss_bin <= 8'd0;  d1_bin <= 8'd0;
            iss_tag <= 16'd0; d1_tag <= 16'd0;
            iss_last<= 1'b0;  d1_last<= 1'b0;
            p0_v    <= 1'b0;  p1_v   <= 1'b0;
            p0_bin  <= 8'd0;  p1_bin <= 8'd0;
            p0_tag  <= 16'd0; p1_tag <= 16'd0;
            p0_val  <= 18'd0; p1_val <= 18'd0;
            fcnt    <= 2'd0;
            dsum    <= 18'd0;
            hre     <= 1'b0;  hwe    <= 1'b0;
            hraddr  <= 8'd0;  hwaddr <= 8'd0;  hwdata <= 18'd0;
            pix_out <= 8'd0;  out_valid <= 1'b0;
            done    <= 1'b0;  bins_ok   <= 1'b0;
        end else if (clk_en) begin
            bc        <= bc + 16'd1;
            hre       <= 1'b0;
            hwe       <= 1'b0;
            out_valid <= 1'b0;
            case (state)
                // ---- zero the bin RAM --------------------------------------
                S_CLR: begin
                    hwe    <= 1'b1;
                    hwaddr <= clr_i[7:0];
                    hwdata <= 18'd0;
                    if (clr_i == 9'd255) begin
                        clr_i <= 9'd0;
                        p0_v  <= 1'b0;          // stale forwards must not
                        p1_v  <= 1'b0;          // leak into a reuse pass
                        state <= S_ACC;
                    end else begin
                        clr_i <= clr_i + 9'd1;
                    end
                end
                // ---- accumulate --------------------------------------------
                S_ACC: begin
                    if (pix_valid) begin
                        hre     <= 1'b1;
                        hraddr  <= pix;
                        iss_bin <= pix;
                        iss_tag <= bc;
                        iss_v   <= 1'b1;
                        iss_last<= (npix == NPIX-1);
                        npix    <= npix + 16'd1;
                    end else begin
                        iss_v    <= 1'b0;
                        iss_last <= 1'b0;
                    end
                    d1_v    <= iss_v;    d1_bin  <= iss_bin;
                    d1_tag  <= iss_tag;  d1_last <= iss_last;
                    if (d1_v) begin
                        hwe    <= 1'b1;
                        hwaddr <= d1_bin;
                        hwdata <= nval;
                        p0_v   <= p1_v;   p0_bin <= p1_bin;
                        p0_tag <= p1_tag; p0_val <= p1_val;
                        p1_v   <= 1'b1;   p1_bin <= d1_bin;
                        p1_tag <= d1_tag; p1_val <= nval;
                        if (d1_last) begin
                            state <= S_FLUSH;
                            fcnt  <= 2'd0;
                        end
                    end
                end
                // ---- let the tail write commit ------------------------------
                S_FLUSH: begin
                    if (fcnt == 2'd2) begin
                        state <= S_DRN;
                        ph    <= 2'd0;
                        clr_i <= 9'd0;
                    end else begin
                        fcnt <= fcnt + 2'd1;
                    end
                end
                // ---- drain bins 0..255, lo then hi, clear-on-read -----------
                S_DRN: begin
                    case (ph)
                        2'd0: begin
                            hre    <= 1'b1;
                            hraddr <= clr_i[7:0];
                            ph     <= 2'd1;
                        end
                        2'd1: ph <= 2'd2;              // q lands next beat
                        2'd2: begin
                            pix_out   <= hq[7:0];
                            out_valid <= 1'b1;
                            hwe       <= 1'b1;         // clear-on-drain
                            hwaddr    <= clr_i[7:0];
                            hwdata    <= 18'd0;
                            dsum      <= dsum + hq;
                            ph        <= 2'd3;
                        end
                        2'd3: begin
                            pix_out   <= hq[15:8];
                            out_valid <= 1'b1;
                            if (clr_i == 9'd255) begin
                                bins_ok <= (dsum == NPIX);  // dsum already
                                                            // incl. bin255
                                state   <= S_DONE;
                                done    <= 1'b1;
                            end else begin
                                clr_i <= clr_i + 9'd1;
                                ph    <= 2'd0;
                            end
                        end
                    endcase
                end
                S_DONE: done <= 1'b1;
                default: state <= S_CLR;
            endcase
        end
    end
endmodule
