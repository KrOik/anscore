// Implementation draft, unverified. Statistics sink: largest spatial dark
// value wins, with RGB-sum tie break. This is ONE candidate, not DCP's top
// percentile selection. The host may use it to solve next-frame airlight.
// A result is published at the next accepted SOF or a flush handshake.
module img_dh_airlight_candidate #(
    parameter integer COUNT_WIDTH = 32
) (
    input wire clk, rst_n, clk_en,
    input wire [23:0] s_rgb,
    input wire [7:0] s_dark,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    input wire flush_valid,
    output wire flush_ready,
    output reg [23:0] candidate_rgb,
    output reg [7:0] candidate_dark,
    output reg [COUNT_WIDTH-1:0] candidate_count,
    output reg candidate_valid,
    input wire candidate_ready,
    output reg error
);
    reg in_frame;
    reg [23:0] best_rgb;
    reg [7:0] best_dark;
    reg [9:0] best_sum;
    reg [COUNT_WIDTH-1:0] pixel_count;
    wire [9:0] rgb_sum = {2'b0,s_rgb[23:16]} +
                         {2'b0,s_rgb[15:8]} + {2'b0,s_rgb[7:0]};
    wire result_room = !candidate_valid || candidate_ready;
    // Flush must be requested with the image source idle; it never steals a pixel.
    assign flush_ready = clk_en && !s_valid && in_frame && result_room;
    assign s_ready = clk_en && (!s_valid || s_sof || in_frame) &&
                     (!s_sof || !in_frame || result_room);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_frame <= 0; best_rgb <= 0; best_dark <= 0; best_sum <= 0;
            pixel_count <= 0; candidate_rgb <= 0; candidate_dark <= 0;
            candidate_count <= 0; candidate_valid <= 0; error <= 0;
        end else if (clk_en) begin
            if (candidate_valid && candidate_ready) candidate_valid <= 0;
            if (s_valid && !s_sof && !in_frame) error <= 1;
            if (flush_valid && flush_ready) begin
                candidate_rgb <= best_rgb; candidate_dark <= best_dark;
                candidate_count <= pixel_count; candidate_valid <= 1;
                in_frame <= 0; pixel_count <= 0;
            end
            if (s_valid && s_ready) begin
                if (s_sof) begin
                    if (in_frame) begin
                        candidate_rgb <= best_rgb; candidate_dark <= best_dark;
                        candidate_count <= pixel_count; candidate_valid <= 1;
                    end
                    in_frame <= 1; best_rgb <= s_rgb; best_dark <= s_dark;
                    best_sum <= rgb_sum; pixel_count <= 1;
                end else begin
                    if (&pixel_count) error <= 1;
                    else pixel_count <= pixel_count + 1'b1;
                    if ((s_dark > best_dark) ||
                        ((s_dark == best_dark) && (rgb_sum > best_sum))) begin
                        best_rgb <= s_rgb; best_dark <= s_dark; best_sum <= rgb_sum;
                    end
                end
            end
        end
    end
    // s_eol is transported by the image path; candidate selection is framewise.
endmodule
