// ============================================================================
// wdt_win -- window watchdog (wave2 idx38, TAG WDT).
//
// A kick must arrive within the (WMIN, WMAX) logical-beat window measured
// from the last accepted event (arm or previous kick):
//   kick with cnt <  WMIN        -> early-kick fault   (ev_early)
//   kick with WMIN <= cnt <= WMAX-> good kick          (ev_good), window resets
//   cnt reaches WMAX+1 (no kick) -> timeout fault      (ev_tout) + reset_req
//   kick while expired           -> late-kick fault    (ev_late), window resets
//
// `en` arms the watchdog (rising edge starts the counter at 0); while en=0
// the counter is held at 0 and kicks are ignored.  reset_req is sticky:
// once set it stays until clr or rst_n.  clr also clears the four event
// counters.  All counters saturate at 8'hFF.
//
// Beat semantics (all inside clk_en-gated always blocks, T2):
//   beat where en rises     : armed<=1, cnt<=0
//   each later beat, no kick: cnt++ until cnt==WMAX, then next beat expires
//                             (cnt=WMAX+1, ev_tout, reset_req<=1), then holds
//   kick beat               : classified by current cnt, cnt<=0
// Event strobes ev_* are registered pulses valid the beat after the cause.
// ============================================================================
module wdt_win #(
    parameter [7:0] WMIN = 8'd4,
    parameter [7:0] WMAX = 8'd9
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       en,
    input  wire       kick,
    input  wire       clr,
    output reg        reset_req,
    output reg        ev_good,
    output reg        ev_early,
    output reg        ev_late,
    output reg        ev_tout,
    output reg [7:0]  cnt_good,
    output reg [7:0]  cnt_early,
    output reg [7:0]  cnt_late,
    output reg [7:0]  cnt_tout
);
    reg       armed;
    reg [8:0] cnt;                 // counts 0..WMAX+1 (expired = cnt > WMAX)

    wire expired = (cnt > {1'b0, WMAX});

    function [7:0] sat8;
        input [7:0] v;
        begin sat8 = (v == 8'hFF) ? 8'hFF : v + 8'd1; end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            armed     <= 1'b0;
            cnt       <= 9'd0;
            reset_req <= 1'b0;
            ev_good   <= 1'b0;
            ev_early  <= 1'b0;
            ev_late   <= 1'b0;
            ev_tout   <= 1'b0;
            cnt_good  <= 8'd0;
            cnt_early <= 8'd0;
            cnt_late  <= 8'd0;
            cnt_tout  <= 8'd0;
        end else if (clk_en) begin
            ev_good  <= 1'b0;
            ev_early <= 1'b0;
            ev_late  <= 1'b0;
            ev_tout  <= 1'b0;
            if (clr) begin
                reset_req <= 1'b0;
                cnt_good  <= 8'd0;
                cnt_early <= 8'd0;
                cnt_late  <= 8'd0;
                cnt_tout  <= 8'd0;
            end
            if (!en) begin
                armed <= 1'b0;
                cnt   <= 9'd0;
            end else if (!armed) begin
                armed <= 1'b1;
                cnt   <= 9'd0;
            end else if (kick) begin
                if (expired) begin
                    ev_late  <= 1'b1;
                    cnt_late <= sat8(cnt_late);
                end else if (cnt < {1'b0, WMIN}) begin
                    ev_early <= 1'b1;
                    cnt_early <= sat8(cnt_early);
                end else begin
                    ev_good  <= 1'b1;
                    cnt_good <= sat8(cnt_good);
                end
                cnt <= 9'd0;
            end else if (expired) begin
                cnt <= cnt;          // hold expired until a kick or !en
            end else if (cnt == {1'b0, WMAX}) begin
                cnt       <= cnt + 9'd1;   // expire this beat
                ev_tout   <= 1'b1;
                cnt_tout  <= sat8(cnt_tout);
                reset_req <= 1'b1;
            end else begin
                cnt <= cnt + 9'd1;
            end
        end
    end
endmodule
