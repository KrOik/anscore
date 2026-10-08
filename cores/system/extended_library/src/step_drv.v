// ============================================================================
// step_drv -- step/dir pulse generator with linear-in-period trapezoidal
// accel/decel profile.
//
// Register port (reg_wr/reg_addr/reg_data):
//   0: tgt     target position in steps
//   1: tstart  initial step interval (clk_en beats)
//   2: tmin    minimum step interval (vmax)
//   3: tdec    interval decrement per step while accelerating
//
// `go` (1 clk_en pulse) latches dir_in and starts the move. `step` pulses
// once per emitted step; `pos` counts emitted steps; `done` pulses at target.
//
// Profile rule per emitted step (pos becomes k):
//   if   (tgt - k <= acnt)             decelerate: interval += tdec
//   elif (interval > tmin)             accelerate: interval -= tdec (>= tmin),
//                                      acnt++
//   else                               cruise.
// This yields a symmetric trapezoid for long moves and a triangle for short
// ones. All registers clk_en gated.
// ============================================================================
module step_drv (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        reg_wr,
    input  wire [1:0]  reg_addr,
    input  wire [15:0] reg_data,
    input  wire        dir_in,
    input  wire        go,
    output reg         step,
    output reg         dir,
    output reg  [15:0] pos,
    output wire [15:0] cur_interval,   // current step interval (beats)
    output reg         busy,
    output reg         done
);

reg [15:0] tgt, tstart, tmin, tdec;
reg [15:0] interval, tmr, acnt;

assign cur_interval = interval;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tgt <= 16'd0; tstart <= 16'd0; tmin <= 16'd0; tdec <= 16'd0;
        interval <= 16'd0; tmr <= 16'd0; acnt <= 16'd0;
        step <= 1'b0; dir <= 1'b0; pos <= 16'd0;
        busy <= 1'b0; done <= 1'b0;
    end else if (clk_en) begin
        step <= 1'b0;
        done <= 1'b0;
        if (reg_wr) begin
            case (reg_addr)
                2'd0: tgt    <= reg_data;
                2'd1: tstart <= reg_data;
                2'd2: tmin   <= reg_data;
                2'd3: tdec   <= reg_data;
                default: ;
            endcase
        end
        if (!busy) begin
            if (go) begin
                busy     <= 1'b1;
                pos      <= 16'd0;
                dir      <= dir_in;
                interval <= tstart;
                tmr      <= tstart;
                acnt     <= 16'd0;
            end
        end else begin
            if (tmr == 16'd0) begin
                step <= 1'b1;
                pos  <= pos + 16'd1;
                if (pos + 16'd1 == tgt) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else if (tgt - (pos + 16'd1) <= acnt) begin
                    // decelerate
                    interval <= interval + tdec;
                    tmr      <= interval + tdec;
                end else if (interval > tmin) begin
                    // accelerate
                    interval <= (interval - tdec < tmin) ? tmin :
                                interval - tdec;
                    tmr      <= (interval - tdec < tmin) ? tmin :
                                interval - tdec;
                    acnt     <= acnt + 16'd1;
                end else begin
                    tmr <= interval;             // cruise
                end
            end else tmr <= tmr - 16'd1;
        end
    end
end

endmodule
