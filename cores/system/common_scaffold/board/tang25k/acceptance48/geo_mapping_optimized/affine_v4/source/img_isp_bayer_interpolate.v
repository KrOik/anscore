// External-window bilinear Bayer kernel. RAW input with row storage is
// img_bayer_window_frontend_draft; that frontend crops a one-pixel border.
// This kernel requires a valid 3x3 window. EXTERNAL_WINDOW=0 is a legacy
// unsupported setting: it raises error and never consumes pixels.
module img_isp_bayer_interpolate #(
    parameter integer RAW_BITS = 8,
    parameter integer EXTERNAL_WINDOW = 1
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [RAW_BITS-1:0] s_data,
    input wire [9*RAW_BITS-1:0] s_window,
    input wire s_x_odd, input wire s_y_odd,
    input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire cfg_commit,
    input wire [1:0] cfg_pattern,
    output wire cfg_ready, output reg cfg_pending,
    output wire unsupported, output reg error,
    output wire [3:0] error_code
);
    localparam integer RAW_SHIFT = (RAW_BITS >= 8) ? RAW_BITS - 8 : 0;
    localparam integer WIDTH_SUPPORTED = (RAW_BITS == 8) || (RAW_BITS == 10) || (RAW_BITS == 12);
    reg [1:0] active_pattern, shadow_pattern;
    wire apply = cfg_pending && s_sof;
    wire [1:0] pattern = apply ? shadow_pattern : active_pattern;
    // Pattern 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR; row/column parity at the center.
    wire [1:0] site = {s_y_odd, s_x_odd} ^ pattern;
    wire [RAW_BITS-1:0] p00 = s_window[0*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p01 = s_window[1*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p02 = s_window[2*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p10 = s_window[3*RAW_BITS +: RAW_BITS];
    // s_data is the authoritative center; s_window slot 4 is not consumed.
    wire [RAW_BITS-1:0] p12 = s_window[5*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p20 = s_window[6*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p21 = s_window[7*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS-1:0] p22 = s_window[8*RAW_BITS +: RAW_BITS];
    wire [RAW_BITS+1:0] cross_sum = {2'b00,p01} + {2'b00,p10} + {2'b00,p12} + {2'b00,p21} + 2;
    wire [RAW_BITS+1:0] diagonal_sum = {2'b00,p00} + {2'b00,p02} + {2'b00,p20} + {2'b00,p22} + 2;
    wire [RAW_BITS:0] horizontal_sum = {1'b0,p10} + {1'b0,p12} + 1'b1;
    wire [RAW_BITS:0] vertical_sum = {1'b0,p01} + {1'b0,p21} + 1'b1;
    wire [RAW_BITS-1:0] cross_average = cross_sum >> 2;
    wire [RAW_BITS-1:0] diagonal_average = diagonal_sum >> 2;
    wire [RAW_BITS-1:0] horizontal_average = horizontal_sum >> 1;
    wire [RAW_BITS-1:0] vertical_average = vertical_sum >> 1;
    reg [RAW_BITS-1:0] red, green, blue;
    wire [7:0] red8 = red >> RAW_SHIFT;
    wire [7:0] green8 = green >> RAW_SHIFT;
    wire [7:0] blue8 = blue >> RAW_SHIFT;
    assign unsupported = !WIDTH_SUPPORTED || (EXTERNAL_WINDOW != 1);
    assign error_code = !WIDTH_SUPPORTED ? 4'd2 : ((EXTERNAL_WINDOW != 1) ? 4'd1 : 4'd0);
    assign s_ready = clk_en && !unsupported && (!m_valid || m_ready);
    assign cfg_ready = clk_en && !cfg_pending;

    always @* begin
        case (site)
            0: begin red = s_data; green = cross_average; blue = diagonal_average; end
            1: begin red = horizontal_average; green = s_data; blue = vertical_average; end
            2: begin red = vertical_average; green = s_data; blue = horizontal_average; end
            3: begin red = diagonal_average; green = cross_average; blue = s_data; end
            default: begin red = 0; green = 0; blue = 0; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0;
            active_pattern <= 0; shadow_pattern <= 0;
            cfg_pending <= 0; error <= 0;
        end else if (clk_en) begin
            if (unsupported && s_valid) error <= 1;
            if (cfg_we && cfg_ready) shadow_pattern <= cfg_pattern;
            if (cfg_commit && cfg_ready) cfg_pending <= 1;
            if (m_valid && m_ready) m_valid <= 0;
            if (s_valid && s_ready) begin
                m_data <= {red8, green8, blue8};
                m_valid <= 1; m_sof <= s_sof; m_eol <= s_eol;
                if (apply) begin
                    active_pattern <= shadow_pattern;
                    cfg_pending <= 0;
                end
            end
        end
    end
endmodule
