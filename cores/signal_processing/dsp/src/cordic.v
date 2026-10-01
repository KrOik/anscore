// ============================================================================
// cordic.v -- 16-stage pipelined CORDIC, Q2.14 fixed point, zero multipliers.
//
//   mode=0 ROTATION : (x_in,y_in) rotated by z_in radians -> (x_out,y_out).
//                     z_in may be any representable Q2.14 value (-2..2 rad);
//                     inputs with |z_in|>pi/2 are pre-rotated by +/-pi
//                     (x,y negated, z folded) so the full representable
//                     domain converges. Gain: outputs are 1.6468x the true
//                     rotated vector; feed x_in=9949 (K*2^14), y_in=0 to get
//                     unit-amplitude cos(z)/sin(z).
//   mode=1 VECTORING: drives y->0.
//                     x_out = gain * sqrt(x_in^2+y_in^2)  (gain 1.6468,
//                     i.e. true magnitude = x_out * 0.607253).
//                     z_out = z_in + atan2(y_in,x_in), 18-bit radians*2^14,
//                     covers the full circle (-pi..pi] via x<0 pre-rotation.
//
// Latency: STAGES+1 enabled clock periods from the input acceptance edge
// to the out_valid edge (STAGES+2 register boundaries including acceptance).
// Protocol: all registers gated by clk_en; rst_n async active-low.
// ============================================================================
module cordic #(
    parameter integer IW     = 16,   // x/y port width (Q2.14)
    parameter integer ZW     = 18,   // angle datapath width (radians*2^14)
    parameter integer STAGES = 16
) (
    input  wire               clk,
    input  wire               clk_en,
    input  wire               rst_n,
    input  wire               mode,        // 0=rotation, 1=vectoring
    input  wire               in_valid,
    input  wire signed [IW-1:0] x_in,
    input  wire signed [IW-1:0] y_in,
    input  wire signed [IW-1:0] z_in,
    output reg  signed [IW-1:0] x_out,
    output reg  signed [IW-1:0] y_out,
    output reg  signed [ZW-1:0] z_out,
    output reg                out_valid
);

localparam signed [ZW-1:0] PI_Q  = 18'd51472;  // round(pi   * 2^14)
localparam signed [ZW-1:0] PI2_Q = 18'd25736;  // round(pi/2 * 2^14)

// atan(2^-i) * 2^14, i = 0..15 (round-to-nearest; table shared with golden)
function signed [ZW-1:0] atan_lut;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  atan_lut = 18'd12868;
            4'd1:  atan_lut = 18'd7596;
            4'd2:  atan_lut = 18'd4014;
            4'd3:  atan_lut = 18'd2037;
            4'd4:  atan_lut = 18'd1023;
            4'd5:  atan_lut = 18'd512;
            4'd6:  atan_lut = 18'd256;
            4'd7:  atan_lut = 18'd128;
            4'd8:  atan_lut = 18'd64;
            4'd9:  atan_lut = 18'd32;
            4'd10: atan_lut = 18'd16;
            4'd11: atan_lut = 18'd8;
            4'd12: atan_lut = 18'd4;
            4'd13: atan_lut = 18'd2;
            4'd14: atan_lut = 18'd1;
            default: atan_lut = 18'd0;   // i=15: atan(2^-15)*2^14 = 0.5 -> 0
        endcase
    end
endfunction

// saturate signed 18-bit -> signed 16-bit
function signed [IW-1:0] sat16;
    input signed [ZW-1:0] v;
    begin
        if (v > 18'sd32767)       sat16 = 16'sd32767;
        else if (v < -18'sd32768) sat16 = -16'sd32768;
        else                      sat16 = v[IW-1:0];
    end
endfunction

reg signed [IW+1:0] x_pipe [0:STAGES];   // 18-bit internal, Q?.14
reg signed [IW+1:0] y_pipe [0:STAGES];
reg signed [ZW-1:0] z_pipe [0:STAGES];
reg                 m_pipe [0:STAGES];
reg [STAGES+1:0]    v_sh;

wire signed [IW+1:0] x_ext = {{2{x_in[IW-1]}}, x_in};
wire signed [IW+1:0] y_ext = {{2{y_in[IW-1]}}, y_in};
wire signed [ZW-1:0] z_ext = {{ZW-IW{z_in[IW-1]}}, z_in};

// ---------------------------------------------------------------------------
// stage 0: quadrant pre-rotation
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        x_pipe[0] <= 18'sd0;
        y_pipe[0] <= 18'sd0;
        z_pipe[0] <= 18'sd0;
        m_pipe[0] <= 1'b0;
    end else if (clk_en) begin
        m_pipe[0] <= mode;
        if (mode) begin
            // vectoring: fold x<0 by rotating pi; angle offset pushed into z
            if (x_in[IW-1]) begin
                x_pipe[0] <= -x_ext;
                y_pipe[0] <= -y_ext;
                z_pipe[0] <= z_ext + (y_in[IW-1] ? -PI_Q : PI_Q);
            end else begin
                x_pipe[0] <= x_ext;
                y_pipe[0] <= y_ext;
                z_pipe[0] <= z_ext;
            end
        end else begin
            // rotation: fold |z|>pi/2 by rotating +/-pi (negates x,y)
            if (z_ext > PI2_Q) begin
                x_pipe[0] <= -x_ext;
                y_pipe[0] <= -y_ext;
                z_pipe[0] <= z_ext - PI_Q;
            end else if (z_ext < -PI2_Q) begin
                x_pipe[0] <= -x_ext;
                y_pipe[0] <= -y_ext;
                z_pipe[0] <= z_ext + PI_Q;
            end else begin
                x_pipe[0] <= x_ext;
                y_pipe[0] <= y_ext;
                z_pipe[0] <= z_ext;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// stages 1..STAGES: unified shift-add iteration
//   e=+1: x-=y>>i, y+=x>>i, z-=atan(i)
//   rotation  picks e = sign(z)  (drive z->0)
//   vectoring picks e =-sign(y)  (drive y->0)
// ---------------------------------------------------------------------------
genvar gi;
generate
for (gi = 0; gi < STAGES; gi = gi + 1) begin : g_stage
    // Share one add/sub datapath per coordinate instead of calculating
    // both signs and multiplexing the two full-width results.
    wire reverse = m_pipe[gi] ? ~y_pipe[gi][IW+1] : z_pipe[gi][ZW-1];
    wire [IW+1:0] x_shift = x_pipe[gi] >>> gi;
    wire [IW+1:0] y_shift = y_pipe[gi] >>> gi;
    wire [IW+1:0] x_delta = y_shift ^ {(IW+2){~reverse}};
    wire [IW+1:0] y_delta = x_shift ^ {(IW+2){reverse}};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pipe[gi+1] <= 18'sd0;
            y_pipe[gi+1] <= 18'sd0;
            z_pipe[gi+1] <= 18'sd0;
            m_pipe[gi+1] <= 1'b0;
        end else if (clk_en) begin
            m_pipe[gi+1] <= m_pipe[gi];
            x_pipe[gi+1] <= x_pipe[gi] + x_delta + {{(IW+1){1'b0}}, ~reverse};
            y_pipe[gi+1] <= y_pipe[gi] + y_delta + {{(IW+1){1'b0}}, reverse};
            if (reverse) begin
                // e = -1
                z_pipe[gi+1] <= z_pipe[gi] + atan_lut(gi[3:0]);
            end else begin
                // e = +1
                z_pipe[gi+1] <= z_pipe[gi] - atan_lut(gi[3:0]);
            end
        end
    end
end
endgenerate

// ---------------------------------------------------------------------------
// valid pipeline (one flop per registered stage)
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        v_sh <= {(STAGES+2){1'b0}};
    end else if (clk_en) begin
        v_sh <= {v_sh[STAGES:0], in_valid};
    end
end

// ---------------------------------------------------------------------------
// output stage
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        x_out     <= 16'sd0;
        y_out     <= 16'sd0;
        z_out     <= 18'sd0;
        out_valid <= 1'b0;
    end else if (clk_en) begin
        x_out     <= sat16(x_pipe[STAGES]);
        y_out     <= sat16(y_pipe[STAGES]);
        z_out     <= z_pipe[STAGES];
        out_valid <= v_sh[STAGES];  // data latency is STAGES+1 beats
    end
end

endmodule
