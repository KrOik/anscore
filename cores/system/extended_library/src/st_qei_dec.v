// ============================================================================
// st_qei_dec -- selftest cell for qei_dec (wave2 contract).
//
// Synthetic A/B waveform, x4 decode, one edge per clk_en beat.
// Segment table (dir,cycles): (fwd,20), (fwd,5), (rev,7), (fwd,3).
// Index events: after seg0 with idx_rst=1, after seg2 with idx_rst=0.
//
// Expected count trace: 0 -> +80 -> idx latch 80, count=0 -> +20 ->
// -28 (0xFFFFFFF8) -> idx latch FFFFFFF8 -> +12 = 4.
//
// Fold stream:
//   after each quadrature cycle: count[15:8], count[7:0]
//   after each index event:      idx_latch[15:8], idx_latch[7:0], {7'b0,idx_rst}
//   at end:                      {7'b0,dir}, total step edges[7:0] (=140)
// ============================================================================
module st_qei_dec (
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

localparam [31:0] EXP = 32'h6E057083;   // golden_comm.py: QEI DIGEST

// quadrature phase table: each emitted cycle produces exactly 4 edges ---------
//   fwd: 00 -> 10 -> 11 -> 01 -> 00   (emitted values: 10,11,01,00)
//   rev: 00 -> 01 -> 11 -> 10 -> 00   (emitted values: 01,11,10,00)
function [1:0] abv;
    input       fdir;
    input [1:0] ph;
    begin
        if (fdir)
            case (ph)
                2'd0: abv = 2'b10;
                2'd1: abv = 2'b11;
                2'd2: abv = 2'b01;
                default: abv = 2'b00;
            endcase
        else
            case (ph)
                2'd0: abv = 2'b01;
                2'd1: abv = 2'b11;
                2'd2: abv = 2'b10;
                default: abv = 2'b00;
            endcase
    end
endfunction

// segment table ---------------------------------------------------------------
function seg_dir;
    input [1:0] s;
    begin seg_dir = (s == 2'd2) ? 1'b0 : 1'b1; end
endfunction
function [5:0] seg_cyc;
    input [1:0] s;
    begin
        case (s)
            2'd0:    seg_cyc = 6'd20;
            2'd1:    seg_cyc = 6'd5;
            2'd2:    seg_cyc = 6'd7;
            default: seg_cyc = 6'd3;
        endcase
    end
endfunction
// index event after seg s? and its idx_rst flag
function seg_has_idx;
    input [1:0] s;
    begin seg_has_idx = (s == 2'd0) || (s == 2'd2); end
endfunction
function seg_idx_rst;
    input [1:0] s;
    begin seg_idx_rst = (s == 2'd0); end
endfunction

// DUT ------------------------------------------------------------------------
reg         qa, qb, qidx, idx_rst;
wire [31:0] count;
wire        dir, step_v, idx_evt;
wire [31:0] idx_latch;

qei_dec dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .qa(qa), .qb(qb), .qidx(qidx), .idx_rst(idx_rst),
    .count(count), .dir(dir), .step_v(step_v),
    .idx_latch(idx_latch), .idx_evt(idx_evt)
);

// selftest FSM ----------------------------------------------------------------
localparam [3:0] Q_IDLE = 4'd0, Q_EMIT = 4'd1, Q_FOLDC = 4'd2,
                 Q_IDXH = 4'd3, Q_IDXW = 4'd4, Q_IDXF  = 4'd5,
                 Q_NEXT = 4'd6, Q_FIN  = 4'd7;

reg [3:0]  qs;
reg [1:0]  seg;
reg [5:0]  cyc;                     // cycle counter within segment
reg [1:0]  ph;                      // phase within cycle
reg        running;
reg [7:0]  stepcnt;                 // total edges observed
reg [31:0] dg;
reg        dg_v;
reg [7:0]  dg_b;
reg [1:0]  foldsel;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0; pass <= 1'b0; digest <= 32'd0; cycles <= 16'd0;
        qs <= Q_IDLE; seg <= 2'd0; cyc <= 6'd0; ph <= 2'd0;
        running <= 1'b0; stepcnt <= 8'd0;
        qa <= 1'b0; qb <= 1'b0; qidx <= 1'b0; idx_rst <= 1'b0;
        dg <= 32'h811C9DC5; dg_v <= 1'b0; dg_b <= 8'd0; foldsel <= 2'd0;
    end else if (clk_en) begin
        dg_v <= 1'b0;
        if (running && !done) cycles <= cycles + 16'd1;
        if (step_v && running) stepcnt <= stepcnt + 8'd1;
        case (qs)
            Q_IDLE: if (start) begin
                running <= 1'b1;
                done    <= 1'b0;
                dg      <= 32'h811C9DC5;
                cycles  <= 16'd0;
                seg     <= 2'd0;
                cyc     <= 6'd0;
                ph      <= 2'd0;
                stepcnt <= 8'd0;
                qa <= 1'b0; qb <= 1'b0; qidx <= 1'b0; idx_rst <= 1'b0;
                qs <= Q_EMIT;
            end
            Q_EMIT: begin                       // emit one phase value
                {qa, qb} <= abv(seg_dir(seg), ph);
                if (ph == 2'd3) begin
                    ph      <= 2'd0;
                    foldsel <= 2'd0;
                    qs      <= Q_FOLDC;          // count settles, fold it
                end else ph <= ph + 2'd1;
            end
            Q_FOLDC: begin          // 3 beats: settle, count hi, count lo.
                                    // the cycle's 4th edge lands in beat 0.
                if (foldsel == 2'd1) begin
                    dg   <= fnv(dg, count[15:8]);
                    dg_b <= count[15:8];
                    dg_v <= 1'b1;
                end else if (foldsel == 2'd2) begin
                    dg   <= fnv(dg, count[7:0]);
                    dg_b <= count[7:0];
                    dg_v <= 1'b1;
                end
                foldsel <= foldsel + 2'd1;
                if (foldsel == 2'd2) begin
                    foldsel <= 2'd0;
                    if (cyc == seg_cyc(seg) - 6'd1) begin
                        cyc <= 6'd0;
                        qs  <= seg_has_idx(seg) ? Q_IDXH : Q_NEXT;
                    end else begin
                        cyc <= cyc + 6'd1;
                        qs  <= Q_EMIT;
                    end
                end
            end
            Q_IDXH: begin                       // drive index pulse 1 beat
                qidx    <= 1'b1;
                idx_rst <= seg_idx_rst(seg);
                qs      <= Q_IDXW;
            end
            Q_IDXW: begin                       // idx edge lands this beat;
                qidx    <= 1'b0;                 // idx_latch valid next beat
                idx_rst <= 1'b0;
                foldsel <= 2'd0;
                qs      <= Q_IDXF;
            end
            Q_IDXF: begin                       // fold idx_latch + flag
                if (foldsel == 2'd0) begin
                    dg   <= fnv(dg, idx_latch[15:8]);
                    dg_b <= idx_latch[15:8];
                    dg_v <= 1'b1;
                    foldsel <= 2'd1;
                end else if (foldsel == 2'd1) begin
                    dg   <= fnv(dg, idx_latch[7:0]);
                    dg_b <= idx_latch[7:0];
                    dg_v <= 1'b1;
                    foldsel <= 2'd2;
                end else begin
                    dg   <= fnv(dg, {7'b0000000, seg_idx_rst(seg)});
                    dg_b <= {7'b0000000, seg_idx_rst(seg)};
                    dg_v <= 1'b1;
                    qs   <= Q_NEXT;
                end
            end
            Q_NEXT: begin
                if (seg == 2'd3) qs <= Q_FIN;
                else begin
                    seg <= seg + 2'd1;
                    ph  <= 2'd0;
                    qs  <= Q_EMIT;
                end
            end
            Q_FIN: begin                        // fold dir + step count
                if (foldsel == 2'd0) begin
                    dg   <= fnv(dg, {7'b0000000, dir});
                    dg_b <= {7'b0000000, dir};
                    dg_v <= 1'b1;
                    foldsel <= 2'd1;
                end else begin
                    dg     <= fnv(dg, stepcnt);
                    dg_b   <= stepcnt;
                    dg_v   <= 1'b1;
                    digest <= fnv(dg, stepcnt);
                    pass   <= (fnv(dg, stepcnt) === EXP) &&
                              (stepcnt === 8'd140);
                    done   <= 1'b1;
                    qs     <= Q_IDLE;
                end
            end
            default: qs <= Q_IDLE;
        endcase
    end
end

endmodule
