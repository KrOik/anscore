// ============================================================================
// st_step_drv -- selftest cell for step_drv (wave2 contract).
//
// Two moves:
//   M0: dir=1 tgt=30 tstart=24 tmin=6 tdec=4  (trapezoid)
//   M1: dir=0 tgt=12 tstart=20 tmin=8 tdec=5  (deeper profile)
//
// Per emitted step pulse (while busy): fold cur_interval[7:0] -- the value
// present during the pulse, i.e. the interval governing the gap that starts
// at this step (i_2 .. i_tgt of the profile sequence, i_1 = tstart).
// At done: fold pos[7:0], {7'b0,dir}.
// Internal check: interval sequence must be non-increasing then
// non-decreasing (single pivot = trapezoid/triangle), and the number of
// folded step pulses must equal tgt-1 (last step coincides with done).
// ============================================================================
module st_step_drv (
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

localparam [31:0] EXP = 32'hAAF87DCF;   // golden_comm.py: STP DIGEST

// move table: {dir,tgt,tstart,tmin,tdec} --------------------------------------
function [15:0] mv;
    input        m;
    input  [2:0] field;
    begin
        if (!m) begin
            case (field)
                3'd0:    mv = 16'd30;   // tgt
                3'd1:    mv = 16'd24;   // tstart
                3'd2:    mv = 16'd6;    // tmin
                3'd3:    mv = 16'd4;    // tdec
                default: mv = 16'd1;    // dir
            endcase
        end else begin
            case (field)
                3'd0:    mv = 16'd12;
                3'd1:    mv = 16'd20;
                3'd2:    mv = 16'd8;
                3'd3:    mv = 16'd5;
                default: mv = 16'd0;
            endcase
        end
    end
endfunction

// DUT ------------------------------------------------------------------------
reg         reg_wr;
reg  [1:0]  reg_addr;
reg  [15:0] reg_data;
reg         dir_in, go;
wire        step, dir, busy, ddone;
wire [15:0] pos, cur_interval;

step_drv dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_data(reg_data),
    .dir_in(dir_in), .go(go),
    .step(step), .dir(dir), .pos(pos), .cur_interval(cur_interval),
    .busy(busy), .done(ddone)
);

// selftest FSM ----------------------------------------------------------------
localparam [2:0] S_IDLE = 3'd0, S_CFG = 3'd1, S_GO = 3'd2,
                 S_RUN  = 3'd3, S_FIN = 3'd4, S_NEXT = 3'd5;

reg [2:0]  ss;
reg        mv_i;
reg        running;
reg [1:0]  wcnt;
reg [15:0] scnt;                    // step pulses seen
reg [15:0] prev_iv;
reg        rising;                  // profile entered decel phase
reg        mono_ok;
reg [1:0]  fsel;
reg [31:0] dg;
reg        dg_v;
reg [7:0]  dg_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0; pass <= 1'b0; digest <= 32'd0; cycles <= 16'd0;
        ss <= S_IDLE; mv_i <= 1'b0; running <= 1'b0;
        reg_wr <= 1'b0; reg_addr <= 2'd0; reg_data <= 16'd0;
        dir_in <= 1'b0; go <= 1'b0;
        scnt <= 16'd0; prev_iv <= 16'd0; rising <= 1'b0; mono_ok <= 1'b1;
        fsel <= 2'd0;
        dg <= 32'h811C9DC5; dg_v <= 1'b0; dg_b <= 8'd0;
    end else if (clk_en) begin
        dg_v   <= 1'b0;
        reg_wr <= 1'b0;
        go     <= 1'b0;
        if (running && !done) cycles <= cycles + 16'd1;
        case (ss)
            S_IDLE: if (start) begin
                running <= 1'b1;
                done    <= 1'b0;
                dg      <= 32'h811C9DC5;
                cycles  <= 16'd0;
                mv_i    <= 1'b0;
                wcnt    <= 2'd0;
                ss      <= S_CFG;
            end
            S_CFG: begin                        // write tgt,tstart,tmin,tdec
                reg_wr   <= 1'b1;
                reg_addr <= wcnt;
                reg_data <= mv(mv_i, {1'b0, wcnt});
                if (wcnt == 2'd3) begin
                    dir_in  <= (mv(mv_i, 3'd4) != 16'd0);
                    scnt    <= 16'd0;
                    prev_iv <= mv(mv_i, 3'd1);  // tstart: first interval
                    rising  <= 1'b0;
                    mono_ok <= 1'b1;
                    ss      <= S_GO;
                end else wcnt <= wcnt + 2'd1;
            end
            S_GO: begin
                go <= 1'b1;
                ss <= S_RUN;
            end
            S_RUN: begin
                if (step && busy) begin         // fold current interval
                    dg   <= fnv(dg, cur_interval[7:0]);
                    dg_b <= cur_interval[7:0];
                    dg_v <= 1'b1;
                    scnt <= scnt + 16'd1;
                    // monotone profile check (non-inc then non-dec)
                    if (scnt != 16'd0) begin
                        if (rising && cur_interval < prev_iv)
                            mono_ok <= 1'b0;
                        if (cur_interval > prev_iv)
                            rising <= 1'b1;
                    end
                    prev_iv <= cur_interval;
                end
                if (ddone) begin
                    fsel <= 2'd0;
                    ss   <= S_FIN;
                end
            end
            S_FIN: begin                        // fold pos + dir
                if (fsel == 2'd0) begin
                    dg   <= fnv(dg, pos[7:0]);
                    dg_b <= pos[7:0];
                    dg_v <= 1'b1;
                    fsel <= 2'd1;
                end else begin
                    dg   <= fnv(dg, {7'b0000000, dir});
                    dg_b <= {7'b0000000, dir};
                    dg_v <= 1'b1;
                    // internal check: pulse count == tgt, profile monotone
                    if (scnt != mv(mv_i, 3'd0) - 16'd1 || !mono_ok)
                        mono_ok <= 1'b0;        // sticky fail
                    ss <= S_NEXT;
                end
            end
            S_NEXT: begin
                if (mv_i) begin
                    digest <= dg;
                    pass   <= (dg === EXP) && mono_ok;
                    done   <= 1'b1;
                    ss     <= S_IDLE;
                end else begin
                    mv_i <= 1'b1;
                    wcnt <= 2'd0;
                    ss   <= S_CFG;
                end
            end
            default: ss <= S_IDLE;
        endcase
    end
end

endmodule
