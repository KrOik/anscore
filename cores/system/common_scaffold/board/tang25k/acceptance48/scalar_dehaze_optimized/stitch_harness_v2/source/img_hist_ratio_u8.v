// Unsigned floor(255 * numerator / denominator), using a serial divider.
// Development draft, unverified. numerator <= denominator; denominator > 0.
module img_hist_ratio_u8 #(
    parameter integer COUNT_WIDTH = 24
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [COUNT_WIDTH-1:0] s_numerator,
    input wire [COUNT_WIDTH-1:0] s_denominator,
    output reg m_valid,
    input wire m_ready,
    output reg [7:0] m_value,
    output reg m_error
);
    localparam integer DIV_WIDTH = COUNT_WIDTH + 8;
    reg running;
    reg [COUNT_WIDTH-1:0] denominator;
    reg [COUNT_WIDTH:0] remainder;
    reg [DIV_WIDTH-1:0] quotient_shift;
    integer bits_left;
    wire [COUNT_WIDTH:0] trial =
        {remainder[COUNT_WIDTH-1:0], quotient_shift[DIV_WIDTH-1]};
    wire subtract_ok = trial >= {1'b0, denominator};
    wire [COUNT_WIDTH:0] next_remainder = subtract_ok ?
        trial - {1'b0, denominator} : trial;
    wire [DIV_WIDTH-1:0] next_quotient =
        {quotient_shift[DIV_WIDTH-2:0], subtract_ok};

    assign s_ready = rst_n && clk_en && !running && !m_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0;
            denominator <= 0;
            remainder <= 0;
            quotient_shift <= 0;
            bits_left <= 0;
            m_valid <= 0;
            m_value <= 0;
            m_error <= 0;
        end else if (clk_en) begin
            if (m_valid && m_ready)
                m_valid <= 0;
            if (s_valid && s_ready) begin
                m_error <= 0;
                if (COUNT_WIDTH < 1 || COUNT_WIDTH > 32 ||
                    s_denominator == 0 || s_numerator > s_denominator) begin
                    m_valid <= 1;
                    m_value <= 0;
                    m_error <= 1;
                end else begin
                    // Constant 255 is a shift/subtract, not a general multiplier.
                    quotient_shift <= ({s_numerator, 8'd0} -
                        {{8{1'b0}}, s_numerator});
                    denominator <= s_denominator;
                    remainder <= 0;
                    bits_left <= DIV_WIDTH;
                    running <= 1;
                end
            end else if (running) begin
                quotient_shift <= next_quotient;
                remainder <= next_remainder;
                bits_left <= bits_left - 1;
                if (bits_left == 1) begin
                    running <= 0;
                    m_valid <= 1;
                    m_value <= next_quotient[7:0];
                end
            end
        end
    end
endmodule
