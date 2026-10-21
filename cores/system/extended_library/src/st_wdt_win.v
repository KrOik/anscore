// ============================================================================
// st_wdt_win -- selftest cell for wdt_win (idx38, TAG WDT).
//
// DUT params: WMIN=4, WMAX=9 (logical beats).  `en` = running (level),
// `kick` pulsed on fixed beat numbers of the cell's own beat counter t
// (t counts clk_en beats since start; the DUT samples inputs on the same
// clk_en edge, so a kick at beat k is classified with cnt = beats since
// the last restart).
//
// Script (golden_acc.py models the same schedule):
//   t=0      en rises (arm; cnt starts counting)
//   t=7      kick, cnt=6 -> good      (ev @ t+1)
//   t=10     kick, cnt=2 -> early     (ev @ t+1)
//   t=16     kick, cnt=5 -> good
//   t=26     cnt reaches WMAX+1 -> timeout fault, reset_req sticky
//   t=29     kick while expired -> late
//   t=35     kick, cnt=5 -> good      (reset_req stays set)
//   t=40..   fold counters {good,early,late,tout} + reset_req byte, done
//
// Folded event bytes: good=8'h01, early=8'hE1, late=8'h1A, tout=8'h70.
// Internal checks: cnt_good==3, cnt_early==1, cnt_late==1, cnt_tout==1,
//   reset_req==1 at end.
// EXP comes from tools/golden_acc.py only (trap T1).
// ============================================================================
module st_wdt_win (
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

    localparam [31:0] EXP = 32'hB93E6C10;   // golden_acc.py WDT

    localparam [7:0] B_GOOD  = 8'h01;
    localparam [7:0] B_EARLY = 8'hE1;
    localparam [7:0] B_LATE  = 8'h1A;
    localparam [7:0] B_TOUT  = 8'h70;

    reg        running;
    reg [6:0]  t;
    reg        fin_ph;      // 0 = run script, 1 = fold counters
    reg [2:0]  fin;
    reg [31:0] dg;
    reg        ok;
    reg [31:0] dbg_data;
    reg [2:0]  dbg_cnt;

    // combinational stimulus (same clk_en beat semantics as the DUT)
    wire en   = running && !fin_ph;
    wire kick = running && !fin_ph &&
                ((t == 7'd7) || (t == 7'd10) || (t == 7'd16) ||
                 (t == 7'd29) || (t == 7'd35));

    wire       rr, eg, ee, el, et;
    wire [7:0] cgood, cearly, clate, ctout;
    wdt_win #(.WMIN(8'd4), .WMAX(8'd9)) u_dut (
        .clk(clk), .clk_en((clk_en && running) || !rst_n), .rst_n(rst_n),
        .en(en), .kick(kick), .clr(1'b0),
        .reset_req(rr),
        .ev_good(eg), .ev_early(ee), .ev_late(el), .ev_tout(et),
        .cnt_good(cgood), .cnt_early(cearly),
        .cnt_late(clate), .cnt_tout(ctout));

    reg [7:0] finb;
    always @(*) begin
        case (fin)
            3'd0:    finb = cgood;
            3'd1:    finb = cearly;
            3'd2:    finb = clate;
            3'd3:    finb = ctout;
            default: finb = {7'b0, rr};
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running  <= 1'b0;
            done     <= 1'b0;
            pass     <= 1'b0;
            digest   <= 32'h811C9DC5;
            cycles   <= 16'd0;
            t        <= 7'd0;
            fin_ph   <= 1'b0;
            fin      <= 3'd0;
            dg       <= 32'h811C9DC5;
            ok       <= 1'b1;
            dbg_data <= 32'd0;
            dbg_cnt  <= 3'd0;
        end else if (clk_en) begin
            dbg_cnt <= 3'd0;
            if (start && !running && !done) begin
                running <= 1'b1;
                cycles  <= 16'd0;
                t       <= 7'd0;
                fin_ph  <= 1'b0;
                fin     <= 3'd0;
                dg      <= 32'h811C9DC5;
                ok      <= 1'b1;
            end else if (running && !done) begin
                cycles <= cycles + 16'd1;
                if (!fin_ph) begin
                    t <= t + 7'd1;
                    // fold one event byte per strobe beat
                    if (eg) begin
                        dg <= fnv(dg, B_GOOD);
                        dbg_data <= {24'b0, B_GOOD}; dbg_cnt <= 3'd1;
                    end else if (ee) begin
                        dg <= fnv(dg, B_EARLY);
                        dbg_data <= {24'b0, B_EARLY}; dbg_cnt <= 3'd1;
                    end else if (el) begin
                        dg <= fnv(dg, B_LATE);
                        dbg_data <= {24'b0, B_LATE};  dbg_cnt <= 3'd1;
                    end else if (et) begin
                        dg <= fnv(dg, B_TOUT);
                        dbg_data <= {24'b0, B_TOUT};  dbg_cnt <= 3'd1;
                    end
                    if (t == 7'd40) fin_ph <= 1'b1;
                end else begin
                    if (fin < 3'd5) begin
                        dg       <= fnv(dg, finb);
                        dbg_data <= {24'b0, finb};
                        dbg_cnt  <= 3'd1;
                        fin      <= fin + 3'd1;
                    end else begin
                        done   <= 1'b1;
                        digest <= dg;
                        pass   <= (dg === EXP) && ok &&
                                  (cgood == 8'd3) && (cearly == 8'd1) &&
                                  (clate == 8'd1) && (ctout == 8'd1) && rr;
                    end
                end
            end
        end
    end
endmodule
