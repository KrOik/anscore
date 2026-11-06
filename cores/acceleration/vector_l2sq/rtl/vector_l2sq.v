// Sum squared differences over a nonempty paired-component vector.
module vector_l2sq #(
    parameter DATA_W=8, ACC_W=24, TAG_W=16, SIGNED_INPUT=1
) (
    input wire clk, rst,
    input wire s_valid,
    output wire s_ready,
    input wire [DATA_W-1:0] s_x, s_y,
    input wire [TAG_W-1:0] s_tag,
    input wire s_last,
    output wire m_valid,
    input wire m_ready,
    output reg [ACC_W-1:0] m_distance,
    output reg [TAG_W-1:0] m_tag,
    output reg m_overflow
);
    // Legal parameters: DATA_W,TAG_W >= 1, ACC_W >= 2*DATA_W.
    reg diff_valid, diff_last, product_valid, product_last, out_valid;
    reg signed [DATA_W:0] difference;
    reg [2*DATA_W-1:0] product;
    reg [TAG_W-1:0] diff_tag, product_tag;
    reg [ACC_W-1:0] accumulator;
    reg overflow;
    wire advance = !out_valid || m_ready;
    assign s_ready = !rst && advance;
    assign m_valid = !rst && out_valid;
    wire signed [DATA_W:0] x_ext = {(SIGNED_INPUT ? s_x[DATA_W-1] : 1'b0),s_x};
    wire signed [DATA_W:0] y_ext = {(SIGNED_INPUT ? s_y[DATA_W-1] : 1'b0),s_y};
    wire signed [2*DATA_W+1:0] square_full = difference * difference;
    wire [ACC_W:0] sum_ext = {1'b0,accumulator}
                          + {{(ACC_W+1-2*DATA_W){1'b0}},product};
    always @(posedge clk) begin
        if (rst) begin
            diff_valid <= 0;
            product_valid <= 0;
            out_valid <= 0;
            accumulator <= 0;
            overflow <= 0;
        end else if (advance) begin
            diff_valid <= s_valid;
            if (s_valid) begin
                difference <= x_ext-y_ext;
                diff_last <= s_last;
                diff_tag <= s_tag;
            end
            product_valid <= diff_valid;
            if (diff_valid) begin
                // |x-y| <= 2^DATA_W-1 in either input mode, hence the
                // square fits unsigned 2*DATA_W despite signed operands.
                product <= square_full[2*DATA_W-1:0];
                product_last <= diff_last;
                product_tag <= diff_tag;
            end
            out_valid <= 0;
            if (product_valid) begin
                if (product_last) begin
                    m_distance <= sum_ext[ACC_W-1:0];
                    m_overflow <= overflow || sum_ext[ACC_W];
                    m_tag <= product_tag;
                    out_valid <= 1;
                    accumulator <= 0;
                    overflow <= 0;
                end else begin
                    accumulator <= sum_ext[ACC_W-1:0];
                    overflow <= overflow || sum_ext[ACC_W];
                end
            end
        end
    end
endmodule
