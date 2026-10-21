// Locally derived three-layer segment of the nine-input odd-even network.
// FIRST_STAGE selects the network parity for this segment (0, 3, or 6).
module img_filter_median_sort3_segment #(
    parameter PIXEL_W = 8,
    parameter FIRST_STAGE = 0,
    parameter LAYERS = 3
)(
    input wire [9*PIXEL_W-1:0] s_taps,
    output wire [9*PIXEL_W-1:0] m_taps
);
    wire [PIXEL_W-1:0] stage [0:LAYERS][0:8];
    genvar lane_in;
    generate
        for (lane_in = 0; lane_in < 9; lane_in = lane_in + 1) begin : input_lane
            assign stage[0][lane_in] = s_taps[lane_in*PIXEL_W +: PIXEL_W];
            assign m_taps[lane_in*PIXEL_W +: PIXEL_W] = stage[LAYERS][lane_in];
        end
    endgenerate

    genvar layer, lane;
    generate
        for (layer = 0; layer < LAYERS; layer = layer + 1) begin : layer_gen
            for (lane = 0; lane < 9; lane = lane + 1) begin : lane_gen
                if ((lane < 8) && ((lane % 2) == ((FIRST_STAGE + layer) % 2))) begin : compare_exchange
                    assign stage[layer+1][lane] =
                        (stage[layer][lane] <= stage[layer][lane+1]) ? stage[layer][lane] : stage[layer][lane+1];
                    assign stage[layer+1][lane+1] =
                        (stage[layer][lane] <= stage[layer][lane+1]) ? stage[layer][lane+1] : stage[layer][lane];
                end
                if (!((lane < 8) && ((lane % 2) == ((FIRST_STAGE + layer) % 2))) &&
                    !((lane > 0) && (((lane-1) % 2) == ((FIRST_STAGE + layer) % 2)))) begin : pass_through
                    assign stage[layer+1][lane] = stage[layer][lane];
                end
            end
        end
    endgenerate
endmodule
