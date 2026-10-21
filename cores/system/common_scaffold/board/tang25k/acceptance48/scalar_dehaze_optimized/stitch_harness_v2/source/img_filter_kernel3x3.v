// implementation_draft_unverified. All kernels use three elastic stages.
// Arithmetic/reduction work is split at the register boundaries, II=1.
// s_taps[i*PIXEL_W +: PIXEL_W] is row-major tap i; tap 4 is the center.
// OP: 0=mean rounded /9, 1=Gaussian rounded /16, 2=median, 3=min, 4=max.
// SE_MASK applies only to min/max, and must contain at least one set bit.
module img_filter_kernel3x3 #(
    parameter PIXEL_W = 8,
    parameter OP = 0,
    parameter [8:0] SE_MASK = 9'h1ff
)(
    input wire clk, rst_n, clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    localparam SUM_W = PIXEL_W + 4;

    wire stream_s_ready;
    wire [PIXEL_W-1:0] stream_s_data;
    wire stream_s_valid, stream_s_sof, stream_s_eol;
    wire [11:0] mean_rom_index;

    // For OP2, two registered boundaries divide the nine comparator layers
    // into three groups of three. The existing stream output register is the
    // third boundary. Other kernels use the generic three-register pipe so
    // every top-level result/marker vector remains aligned.
    generate
        if (OP == 2) begin : median_three_stage
            wire [9*PIXEL_W-1:0] segment0_taps;
            wire [9*PIXEL_W-1:0] segment1_taps;
            wire [9*PIXEL_W-1:0] segment2_taps;
            reg [9*PIXEL_W-1:0] segment1_q;
            reg [9*PIXEL_W-1:0] segment2_q;
            reg segment1_valid, segment2_valid;
            reg segment1_sof, segment1_eol;
            reg segment2_sof, segment2_eol;
            wire segment1_ready;
            wire segment2_ready;

            img_filter_median_sort3_segment #(.PIXEL_W(PIXEL_W), .FIRST_STAGE(0)) sort_segment0 (
                .s_taps(s_taps), .m_taps(segment0_taps)
            );
            img_filter_median_sort3_segment #(.PIXEL_W(PIXEL_W), .FIRST_STAGE(3)) sort_segment1 (
                .s_taps(segment1_q), .m_taps(segment1_taps)
            );
            img_filter_median_sort3_segment #(.PIXEL_W(PIXEL_W), .FIRST_STAGE(6)) sort_segment2 (
                .s_taps(segment2_q), .m_taps(segment2_taps)
            );

            assign segment2_ready = rst_n && clk_en && (!segment2_valid || stream_s_ready);
            assign segment1_ready = rst_n && clk_en && (!segment1_valid || segment2_ready);
            assign s_ready = segment1_ready;
            assign stream_s_data = segment2_taps[4*PIXEL_W +: PIXEL_W];
            assign stream_s_valid = segment2_valid;
            assign stream_s_sof = segment2_sof;
            assign stream_s_eol = segment2_eol;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    segment1_q <= {(9*PIXEL_W){1'b0}};
                    segment2_q <= {(9*PIXEL_W){1'b0}};
                    segment1_valid <= 1'b0;
                    segment2_valid <= 1'b0;
                    segment1_sof <= 1'b0;
                    segment1_eol <= 1'b0;
                    segment2_sof <= 1'b0;
                    segment2_eol <= 1'b0;
                end else if (clk_en) begin
                    if (segment1_ready) begin
                        segment1_valid <= s_valid;
                        if (s_valid) begin
                            segment1_q <= segment0_taps;
                            segment1_sof <= s_sof;
                            segment1_eol <= s_eol;
                        end
                    end
                    if (segment2_ready) begin
                        segment2_valid <= segment1_valid;
                        if (segment1_valid) begin
                            segment2_q <= segment1_taps;
                            segment2_sof <= segment1_sof;
                            segment2_eol <= segment1_eol;
                        end
                    end
                end
            end
        end else begin : reduction_three_stage
            wire [SUM_W-1:0] p [0:8];
            wire [PIXEL_W-1:0] masked [0:8];
            wire [SUM_W-1:0] row0, row1, row2;
            wire [3*SUM_W-1:0] rows_q;
            wire [SUM_W-1:0] r0, r1, r2;
            wire [SUM_W-1:0] reduced0, reduced1;
            wire [2*SUM_W-1:0] reduced_q;
            wire [SUM_W-1:0] v0, v1;
            wire rows_valid, rows_sof, rows_eol, rows_ready;
            wire reduce_valid, reduce_sof, reduce_eol;
            genvar tap;
            for (tap = 0; tap < 9; tap = tap + 1) begin : taps
                assign p[tap] = {4'b0, s_taps[tap*PIXEL_W +: PIXEL_W]};
                // Preserve the baseline's reflected structuring element for
                // dilation, and direct structuring element for erosion.
                if (OP == 3)
                    assign masked[tap] = SE_MASK[tap] ? s_taps[tap*PIXEL_W +: PIXEL_W] : {PIXEL_W{1'b1}};
                else
                    assign masked[tap] = SE_MASK[8-tap] ? s_taps[tap*PIXEL_W +: PIXEL_W] : {PIXEL_W{1'b0}};
            end
            function [PIXEL_W-1:0] choose;
                input [PIXEL_W-1:0] a, b;
                begin choose = (OP == 3) ? ((a < b) ? a : b) : ((a > b) ? a : b); end
            endfunction
            if (OP == 0) begin : mean_rows
                assign row0 = p[0] + p[1] + p[2];
                assign row1 = p[3] + p[4] + p[5];
                assign row2 = p[6] + p[7] + p[8] + 4;
            end else if (OP == 1) begin : gaussian_rows
                assign row0 = p[0] + (p[1] << 1) + p[2];
                assign row1 = (p[3] + (p[4] << 1) + p[5]) << 1;
                assign row2 = p[6] + (p[7] << 1) + p[8] + 8;
            end else begin : morph_rows
                assign row0 = {{4{1'b0}}, choose(choose(masked[0], masked[1]), masked[2])};
                assign row1 = {{4{1'b0}}, choose(choose(masked[3], masked[4]), masked[5])};
                assign row2 = {{4{1'b0}}, choose(choose(masked[6], masked[7]), masked[8])};
            end
            img_filter_stream_register #(.DATA_W(3*SUM_W)) rows_register (
                .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                .s_data({row2,row1,row0}), .s_valid(s_valid), .s_ready(s_ready),
                .s_sof(s_sof), .s_eol(s_eol), .m_data(rows_q),
                .m_valid(rows_valid), .m_sof(rows_sof), .m_eol(rows_eol), .m_ready(rows_ready)
            );
            assign {r2,r1,r0} = rows_q;
            if (OP == 0 || OP == 1) begin : sum_rows
                assign reduced0 = (r0 + r1) + r2;
                assign reduced1 = 0;
            end else begin : compare_rows
                assign reduced0 = {{4{1'b0}},choose(r0[PIXEL_W-1:0],r1[PIXEL_W-1:0])};
                assign reduced1 = r2;
            end
            img_filter_stream_register #(.DATA_W(2*SUM_W)) reduction_register (
                .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
                .s_data({reduced1,reduced0}), .s_valid(rows_valid), .s_ready(rows_ready),
                .s_sof(rows_sof), .s_eol(rows_eol), .m_data(reduced_q),
                .m_valid(reduce_valid), .m_sof(reduce_sof), .m_eol(reduce_eol), .m_ready(stream_s_ready)
            );
            assign {v1,v0} = reduced_q;
            if (OP == 0 && PIXEL_W == 8) begin : mean_rom_select
                assign mean_rom_index = v0;
                assign stream_s_data = 0; // The synchronous ROM is stage three.
            end
            else if (OP == 0) assign stream_s_data = v0 / 9;
            else if (OP == 1) assign stream_s_data = v0 >> 4;
            else if (OP == 3 || OP == 4) assign stream_s_data = choose(v0[PIXEL_W-1:0],v1[PIXEL_W-1:0]);
            else assign stream_s_data = 0;
            assign stream_s_valid = reduce_valid;
            assign stream_s_sof = reduce_sof;
            assign stream_s_eol = reduce_eol;
        end
    endgenerate

    generate if (OP == 0 && PIXEL_W == 8) begin : mean_rom_output
        img_filter_mean9_rom output_register (
            .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
            .s_index(mean_rom_index), .s_valid(stream_s_valid),
            .s_ready(stream_s_ready), .s_sof(stream_s_sof), .s_eol(stream_s_eol),
            .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready),
            .m_sof(m_sof), .m_eol(m_eol)
        );
    end else begin : generic_output
    img_filter_stream_register #(
        .DATA_W(PIXEL_W), .PIPE_STAGES(1)
    ) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data(stream_s_data), .s_valid(stream_s_valid), .s_ready(stream_s_ready),
        .s_sof(stream_s_sof), .s_eol(stream_s_eol), .m_data(m_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
    end endgenerate

`ifndef SYNTHESIS
    initial begin
        if (PIXEL_W < 1 || OP < 0 || OP > 4)
            $fatal(1, "img_filter_kernel3x3: unsupported parameter");
        if ((OP == 3 || OP == 4) && SE_MASK == 0)
            $fatal(1, "img_filter_kernel3x3: empty structuring element");
    end
`endif
endmodule
