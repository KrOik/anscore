// Autonomous signed W-bit divide, W>=1. Quotient truncates toward zero.
module signed_divider #(parameter W=32)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [W-1:0] s_numerator,s_denominator,
    output wire m_valid,input wire m_ready,
    output wire [W-1:0] m_quotient,m_remainder,
    output wire m_divzero,m_overflow
);
    localparam [W-1:0] MINIMUM={1'b1,{(W-1){1'b0}}};
    reg quotient_negative,remainder_negative,overflow;
    reg [W-1:0] original_numerator;
    wire [W-1:0] magnitude_a=s_numerator[W-1] ? -s_numerator : s_numerator;
    wire [W-1:0] magnitude_b=s_denominator[W-1] ? -s_denominator : s_denominator;
    wire [W-1:0] quotient,remainder;
    // Unsigned magnitudes represent abs(MINIMUM) without widening.
    integer_divider #(.W(W)) magnitude_divider(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),
        .s_numerator(magnitude_a),.s_denominator(magnitude_b),
        .m_valid(m_valid),.m_ready(m_ready),.m_quotient(quotient),
        .m_remainder(remainder),.m_divzero(m_divzero));
    always @(posedge clk) begin
        if(s_valid && s_ready) begin
            quotient_negative<=s_numerator[W-1]^s_denominator[W-1];
            remainder_negative<=s_numerator[W-1];
            original_numerator<=s_numerator;
            overflow<=(s_numerator==MINIMUM && (&s_denominator));
        end
    end
    // Zero divisor: quotient=-1 and remainder=original numerator, for either sign.
    // MINIMUM/-1 wraps quotient to MINIMUM, remainder=0, overflow=1.
    assign m_quotient=m_divzero ? {W{1'b1}} : (quotient_negative ? -quotient : quotient);
    assign m_remainder=m_divzero ? original_numerator : (remainder_negative ? -remainder : remainder);
    assign m_overflow=overflow;
endmodule
