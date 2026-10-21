// Development draft, unverified. Reads bins 0..255, writes a complete 8-bit
// grayscale HE LUT. Commit the receiving LUT bank ONLY after done_error == 0.
// Default: floor(255 * (CDF - CDF_min) / (N - CDF_min)). A constant
// frame preserves its occupied level. NORMALIZE_CDF_MIN=0 selects the direct
// floor(255 * CDF / N) mapping commonly used after CLAHE redistribution.
module img_hist_he_lut_builder #(
    parameter integer COUNT_WIDTH = 24,
    parameter integer TAG_WIDTH = 16,
    parameter integer NORMALIZE_CDF_MIN = 1
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire start_valid,
    output wire start_ready,
    input wire [COUNT_WIDTH-1:0] start_count,
    input wire [TAG_WIDTH-1:0] start_tag,
    output wire hist_req_valid,
    input wire hist_req_ready,
    output wire [7:0] hist_req_bin,
    input wire hist_rsp_valid,
    output wire hist_rsp_ready,
    input wire [7:0] hist_rsp_bin,
    input wire [COUNT_WIDTH-1:0] hist_rsp_count,
    input wire [TAG_WIDTH-1:0] hist_rsp_tag,
    input wire hist_rsp_error,
    output wire lut_wr_valid,
    input wire lut_wr_ready,
    output wire [7:0] lut_wr_addr,
    output reg [7:0] lut_wr_data,
    output wire lut_wr_last,
    output wire [TAG_WIDTH-1:0] lut_wr_tag,
    output reg done_valid,
    input wire done_ready,
    output reg done_error,
    output reg [7:0] done_error_code,
    output reg [COUNT_WIDTH-1:0] done_count,
    output reg [TAG_WIDTH-1:0] done_tag
);
    localparam [2:0] IDLE = 0, REQUEST = 1, RESPONSE = 2,
                     DIV_REQUEST = 3, DIV_RESPONSE = 4, WRITE_LUT = 5;
    reg [2:0] state;
    reg [7:0] bin_index;
    reg [TAG_WIDTH-1:0] frame_tag;
    reg [COUNT_WIDTH-1:0] total_count, cdf, cdf_min;
    reg first_found;
    reg [COUNT_WIDTH-1:0] div_numerator, div_denominator;
    wire [COUNT_WIDTH:0] next_cdf = {1'b0, cdf} +
                                               {1'b0, hist_rsp_count};
    wire [COUNT_WIDTH-1:0] next_min = first_found ? cdf_min :
        (hist_rsp_count != 0 ? hist_rsp_count : {COUNT_WIDTH{1'b0}});
    wire [COUNT_WIDTH-1:0] effective_min = NORMALIZE_CDF_MIN ? next_min :
        {COUNT_WIDTH{1'b0}};
    wire [COUNT_WIDTH-1:0] numerator = next_cdf[COUNT_WIDTH-1:0] - effective_min;
    wire [COUNT_WIDTH-1:0] denominator = total_count - effective_min;
    wire ratio_in_ready, ratio_out_valid, ratio_error;
    wire [7:0] ratio_value;

    assign start_ready = rst_n && clk_en && state == IDLE && !done_valid;
    assign hist_req_valid = state == REQUEST;
    assign hist_req_bin = bin_index;
    assign hist_rsp_ready = rst_n && clk_en && state == RESPONSE;
    assign lut_wr_valid = state == WRITE_LUT;
    assign lut_wr_addr = bin_index;
    assign lut_wr_last = bin_index == 255;
    assign lut_wr_tag = frame_tag;

    img_hist_ratio_u8 #(.COUNT_WIDTH(COUNT_WIDTH)) divider (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(state == DIV_REQUEST), .s_ready(ratio_in_ready),
        .s_numerator(div_numerator), .s_denominator(div_denominator),
        .m_valid(ratio_out_valid), .m_ready(state == DIV_RESPONSE),
        .m_value(ratio_value), .m_error(ratio_error)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            bin_index <= 0;
            frame_tag <= 0;
            total_count <= 0;
            cdf <= 0;
            cdf_min <= 0;
            first_found <= 0;
            div_numerator <= 0;
            div_denominator <= 0;
            lut_wr_data <= 0;
            done_valid <= 0;
            done_error <= 0;
            done_error_code <= 0;
            done_count <= 0;
            done_tag <= 0;
        end else if (clk_en) begin
            if (done_valid && done_ready)
                done_valid <= 0;
            case (state)
                IDLE: begin
                    if (start_valid && start_ready) begin
                        frame_tag <= start_tag;
                        total_count <= start_count;
                        bin_index <= 0;
                        cdf <= 0;
                        cdf_min <= 0;
                        first_found <= 0;
                        done_error <= 0;
                        done_error_code <= 0;
                        if (start_count == 0 || COUNT_WIDTH < 1 ||
                            COUNT_WIDTH > 32 ||
                            (NORMALIZE_CDF_MIN != 0 && NORMALIZE_CDF_MIN != 1)) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h01;
                            done_count <= 0;
                            done_tag <= start_tag;
                        end else begin
                            state <= REQUEST;
                        end
                    end
                end
                REQUEST: begin
                    if (hist_req_valid && hist_req_ready)
                        state <= RESPONSE;
                end
                RESPONSE: begin
                    if (hist_rsp_valid && hist_rsp_ready) begin
                        if (hist_rsp_error || hist_rsp_bin != bin_index ||
                            hist_rsp_tag != frame_tag) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h02;
                            done_count <= cdf;
                            done_tag <= frame_tag;
                            state <= IDLE;
                        end else if (next_cdf > {1'b0, total_count} ||
                            (bin_index == 255 && next_cdf !=
                                                    {1'b0, total_count})) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h04;
                            done_count <= cdf;
                            done_tag <= frame_tag;
                            state <= IDLE;
                        end else begin
                            cdf <= next_cdf[COUNT_WIDTH-1:0];
                            if (!first_found && hist_rsp_count != 0) begin
                                first_found <= 1;
                                cdf_min <= hist_rsp_count;
                            end
                            if (denominator == 0) begin
                                lut_wr_data <= bin_index;
                                state <= WRITE_LUT;
                            end else if (numerator == 0) begin
                                lut_wr_data <= 0;
                                state <= WRITE_LUT;
                            end else begin
                                div_numerator <= numerator;
                                div_denominator <= denominator;
                                state <= DIV_REQUEST;
                            end
                        end
                    end
                end
                DIV_REQUEST: begin
                    if (ratio_in_ready)
                        state <= DIV_RESPONSE;
                end
                DIV_RESPONSE: begin
                    if (ratio_out_valid) begin
                        if (ratio_error) begin
                            done_valid <= 1;
                            done_error <= 1;
                            done_error_code <= 8'h08;
                            done_count <= cdf;
                            done_tag <= frame_tag;
                            state <= IDLE;
                        end else begin
                            lut_wr_data <= ratio_value;
                            state <= WRITE_LUT;
                        end
                    end
                end
                WRITE_LUT: begin
                    if (lut_wr_valid && lut_wr_ready) begin
                        if (bin_index == 255) begin
                            done_valid <= 1;
                            done_error <= 0;
                            done_error_code <= 0;
                            done_count <= cdf;
                            done_tag <= frame_tag;
                            state <= IDLE;
                        end else begin
                            bin_index <= bin_index + 1'b1;
                            state <= REQUEST;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
