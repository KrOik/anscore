// ============================================================================
// st_pwm_gen -- selftest cell for pwm_gen (wave2 contract).
//
// Phase 0: period=24, duty={0,7,13,24}  (always-off, two mid, saturated)
//          run window = 3 periods = 72 beats
// Phase 1: period=16, duty={5,12,16,0}
//          run window = 2 periods = 32 beats
//
// Per phase the cell counts rising edges and high beats per channel, then
// folds: for ch0..3 {rise[7:0], high[15:8], high[7:0]}, then {4'b0, pwm_last}.
// ============================================================================
module st_pwm_gen (
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

localparam [31:0] EXP = 32'h89356055;   // golden_comm.py: PWM DIGEST

// config table: idx 0 = period, idx 1..4 = duty0..3 ---------------------------
function [15:0] cfgv;
    input        ph;
    input  [2:0] idx;
    begin
        if (!ph) begin
            case (idx)
                3'd0:    cfgv = 16'd24;
                3'd1:    cfgv = 16'd0;
                3'd2:    cfgv = 16'd7;
                3'd3:    cfgv = 16'd13;
                default: cfgv = 16'd24;
            endcase
        end else begin
            case (idx)
                3'd0:    cfgv = 16'd16;
                3'd1:    cfgv = 16'd5;
                3'd2:    cfgv = 16'd12;
                3'd3:    cfgv = 16'd16;
                default: cfgv = 16'd0;
            endcase
        end
    end
endfunction

function [7:0] wlen;                    // run window length per phase
    input ph;
    begin wlen = ph ? 8'd32 : 8'd72; end
endfunction

// DUT ------------------------------------------------------------------------
reg        reg_wr;
reg  [2:0] reg_addr;
reg  [15:0] reg_data;
reg        en;
wire [3:0] pwm;

pwm_gen dut (
    .clk(clk), .clk_en(clk_en || !rst_n), .rst_n(rst_n),
    .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_data(reg_data),
    .en(en), .pwm(pwm)
);

// selftest FSM ----------------------------------------------------------------
localparam [2:0] P_IDLE = 3'd0, P_CFG = 3'd1, P_SETL = 3'd4,
                 P_RUN  = 3'd2, P_FOLD = 3'd3, P_NEXT = 3'd5;

reg [2:0]  ps;
reg        phase;
reg        running;
reg [2:0]  wcnt;
reg [7:0]  rcnt;
reg [31:0] risef;                     // 8b rise count per channel
reg [63:0] highf;                     // 16b high count per channel
reg [3:0]  prev;
reg [1:0]  fch;                       // fold channel 0..3
reg [1:0]  fb;                        // fold byte within channel 0..2
reg        fin;                       // final fold beat (prev nibble)
reg [31:0] dg;
reg        dg_v;
reg [7:0]  dg_b;

wire [7:0] fold_b =
    fin          ? {4'd0, prev} :
    (fb == 2'd0) ? risef[{fch, 3'b000} +: 8] :
    (fb == 2'd1) ? highf[{fch, 4'b0000} + 8 +: 8] :
                   highf[{fch, 4'b0000} +: 8];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done <= 1'b0; pass <= 1'b0; digest <= 32'd0; cycles <= 16'd0;
        ps <= P_IDLE; phase <= 1'b0; running <= 1'b0;
        reg_wr <= 1'b0; reg_addr <= 3'd0; reg_data <= 16'd0; en <= 1'b0;
        wcnt <= 3'd0; rcnt <= 8'd0; risef <= 32'd0; highf <= 64'd0;
        prev <= 4'd0; fch <= 2'd0; fb <= 2'd0; fin <= 1'b0;
        dg <= 32'h811C9DC5; dg_v <= 1'b0; dg_b <= 8'd0;
    end else if (clk_en) begin
        dg_v   <= 1'b0;
        reg_wr <= 1'b0;
        if (running && !done) cycles <= cycles + 16'd1;
        case (ps)
            P_IDLE: if (start) begin
                running <= 1'b1;
                done    <= 1'b0;
                dg      <= 32'h811C9DC5;
                cycles  <= 16'd0;
                phase   <= 1'b0;
                wcnt    <= 3'd0;
                ps      <= P_CFG;
            end
            P_CFG: begin                        // write period + 4 duties
                reg_wr   <= 1'b1;
                reg_addr <= wcnt;
                reg_data <= cfgv(phase, wcnt);
                if (wcnt == 3'd4) begin
                    risef <= 32'd0;
                    highf <= 64'd0;
                    prev  <= 4'd0;
                    rcnt  <= 8'd0;
                    ps    <= P_SETL;    // let the last duty write commit
                end else wcnt <= wcnt + 3'd1;
            end
            P_SETL: begin                       // pending reg write commits
                en <= 1'b1;                     // here; en rises next beat
                ps <= P_RUN;
            end
            P_RUN: begin                        // sample pwm for wlen beats
                if (pwm[0] && !prev[0]) risef[7:0]   <= risef[7:0]   + 8'd1;
                if (pwm[1] && !prev[1]) risef[15:8]  <= risef[15:8]  + 8'd1;
                if (pwm[2] && !prev[2]) risef[23:16] <= risef[23:16] + 8'd1;
                if (pwm[3] && !prev[3]) risef[31:24] <= risef[31:24] + 8'd1;
                if (pwm[0]) highf[15:0]  <= highf[15:0]  + 16'd1;
                if (pwm[1]) highf[31:16] <= highf[31:16] + 16'd1;
                if (pwm[2]) highf[47:32] <= highf[47:32] + 16'd1;
                if (pwm[3]) highf[63:48] <= highf[63:48] + 16'd1;
                prev <= pwm;
                if (rcnt == wlen(phase) - 8'd1) ps <= P_FOLD;
                else rcnt <= rcnt + 8'd1;
            end
            P_FOLD: begin                       // 13 fold beats
                dg   <= fnv(dg, fold_b);
                dg_b <= fold_b;
                dg_v <= 1'b1;
                if (fin) begin
                    fin <= 1'b0;
                    fch <= 2'd0;
                    fb  <= 2'd0;
                    en  <= 1'b0;
                    ps  <= P_NEXT;
                end else if (fch == 2'd3 && fb == 2'd2) begin
                    fin <= 1'b1;
                end else if (fb == 2'd2) begin
                    fb  <= 2'd0;
                    fch <= fch + 2'd1;
                end else fb <= fb + 2'd1;
            end
            P_NEXT: begin
                if (phase) begin
                    digest <= dg;
                    pass   <= (dg === EXP);
                    done   <= 1'b1;
                    ps     <= P_IDLE;
                end else begin
                    phase <= 1'b1;
                    wcnt  <= 3'd0;
                    ps    <= P_CFG;
                end
            end
            default: ps <= P_IDLE;
        endcase
    end
end

endmodule
