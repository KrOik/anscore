// ============================================================================
// fir16.v -- 16-tap symmetric FIR, 8-bit unsigned samples, zero DSP.
//
//   y[n] = sat_u8( sum_{k=0}^{7} C_k * (x[n-k] + x[n-15+k]) >> OUT_SHIFT )
//
// Symmetry: coefficients C_k apply to folded sample pairs (16 taps, 8 unique
// coefficients). Coefficient multiplies are built as shift-add trees by
// cmul(): the coefficient is a parameter so the bit loop constant-folds into
// pure shifts/adds -- no multiplier is ever inferred.
//
// Outputs: y_out/out_valid one clk_en beat after in_valid (sample shifted in
// and result registered on the same beat => y_out reflects samples up to the
// previously accepted one).
// ============================================================================
module fir16 #(
    parameter [7:0] C0 = 8'd1,
    parameter [7:0] C1 = 8'd2,
    parameter [7:0] C2 = 8'd4,
    parameter [7:0] C3 = 8'd8,
    parameter [7:0] C4 = 8'd16,
    parameter [7:0] C5 = 8'd32,
    parameter [7:0] C6 = 8'd32,
    parameter [7:0] C7 = 8'd16,
    parameter integer OUT_SHIFT = 8
) (
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       in_valid,
    input  wire [7:0] sample_in,
    output reg  [7:0] y_out,
    output reg        out_valid
);

// shift-add constant multiply: c constant at elaboration -> pure shifts
function [19:0] cmul;
    input [8:0] p;      // folded pair sum, 0..510
    input [7:0] c;      // coefficient
    integer b;
    begin
        cmul = 20'd0;
        for (b = 0; b < 8; b = b + 1) begin
            if (c[b]) cmul = cmul + ({11'd0, p} << b);
        end
    end
endfunction

reg [7:0] s [0:15];
integer k;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (k = 0; k < 16; k = k + 1) s[k] <= 8'd0;
    end else if (clk_en && in_valid) begin
        s[0] <= sample_in;
        for (k = 1; k < 16; k = k + 1) s[k] <= s[k-1];
    end
end

// folded symmetric pair sums (9-bit each)
wire [8:0] p0 = {1'b0, s[0]} + {1'b0, s[15]};
wire [8:0] p1 = {1'b0, s[1]} + {1'b0, s[14]};
wire [8:0] p2 = {1'b0, s[2]} + {1'b0, s[13]};
wire [8:0] p3 = {1'b0, s[3]} + {1'b0, s[12]};
wire [8:0] p4 = {1'b0, s[4]} + {1'b0, s[11]};
wire [8:0] p5 = {1'b0, s[5]} + {1'b0, s[10]};
wire [8:0] p6 = {1'b0, s[6]} + {1'b0, s[9]};
wire [8:0] p7 = {1'b0, s[7]} + {1'b0, s[8]};

wire [19:0] acc = cmul(p0, C0) + cmul(p1, C1) + cmul(p2, C2) + cmul(p3, C3)
                + cmul(p4, C4) + cmul(p5, C5) + cmul(p6, C6) + cmul(p7, C7);
wire [19:0] y_wide = acc >> OUT_SHIFT;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        y_out     <= 8'd0;
        out_valid <= 1'b0;
    end else if (clk_en) begin
        out_valid <= in_valid;
        if (in_valid) begin
            y_out <= (y_wide > 20'd255) ? 8'd255 : y_wide[7:0];
        end
    end
end

endmodule
