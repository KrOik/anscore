// Development draft, unverified. One background sample is supplied externally per pixel.
// Background is Q8.8; no internal frame RAM or statistical multi-Gaussian model.
module img_mf_background_ewma #(
    parameter TAG_WIDTH = 16, parameter FRAME_WIDTH = 16
) (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire s_valid, output wire s_ready, input wire [7:0] s_data,
    input wire s_sof, input wire s_eol,
    input wire [TAG_WIDTH-1:0] s_tag, input wire [FRAME_WIDTH-1:0] s_frameid,
    input wire aux_valid, output wire aux_ready, input wire [15:0] aux_data,
    input wire aux_initialized, input wire aux_sof, input wire aux_eol,
    input wire [TAG_WIDTH-1:0] aux_tag, input wire [FRAME_WIDTH-1:0] aux_frameid,
    input wire cfg_we, input wire cfg_commit, input wire [3:0] cfg_update_shift,
    input wire [7:0] cfg_threshold, input wire cfg_freeze_foreground,
    output wire cfg_ready, output reg cfg_pending, output reg cfg_error,
    output reg m_valid, input wire m_ready, output reg [7:0] m_data,
    output reg [7:0] m_difference, output reg m_foreground,
    output reg m_sof, output reg m_eol,
    output reg [TAG_WIDTH-1:0] m_tag, output reg [FRAME_WIDTH-1:0] m_frameid,
    output reg [7:0] m_error,
    output reg wb_valid, input wire wb_ready, output reg [15:0] wb_data,
    output reg wb_enable, output reg wb_sof, output reg wb_eol,
    output reg [TAG_WIDTH-1:0] wb_tag, output reg [FRAME_WIDTH-1:0] wb_frameid,
    output reg [7:0] wb_error, output wire [7:0] error_code
);
    wire p_valid, p_ready, p_sof, p_eol;
    wire [16:0] p_data, p_aux;
    wire [7:0] p_error, pair_sticky;
    wire [TAG_WIDTH-1:0] p_tag;
    wire [FRAME_WIDTH-1:0] p_frameid;
    reg [3:0] active_shift, shadow_shift;
    reg [7:0] active_threshold, shadow_threshold;
    reg active_freeze, shadow_freeze;
    wire new_cfg = cfg_pending && p_sof && p_error == 0;
    wire [3:0] shift_now = new_cfg ? shadow_shift : active_shift;
    wire [7:0] threshold_now = new_cfg ? shadow_threshold : active_threshold;
    wire freeze_now = new_cfg ? shadow_freeze : active_freeze;
    wire [7:0] current_pixel = p_data[7:0];
    wire [7:0] old_pixel = p_aux[15:8];
    wire initialized = p_aux[16];
    wire [7:0] difference = current_pixel >= old_pixel ? current_pixel-old_pixel : old_pixel-current_pixel;
    wire foreground_now = initialized && (difference > threshold_now);
    wire signed [17:0] delta = $signed({2'b00,current_pixel,8'd0}) - $signed({2'b00,p_aux[15:0]});
    wire signed [17:0] updated = $signed({2'b00,p_aux[15:0]}) + (delta >>> shift_now);
    wire [15:0] background_next = !initialized ? {current_pixel,8'd0} :
        ((freeze_now && foreground_now) ? p_aux[15:0] : updated[15:0]);
    // Both sink registers must be free; a completed branch is cleared separately.
    // A slow writeback sink therefore cannot make the image sink repeat a pixel.
    wire room = (!m_valid || m_ready) && (!wb_valid || wb_ready);
    assign p_ready = room;
    assign cfg_ready = rst_n && clk_en && !cfg_pending;
    assign error_code = pair_sticky | (cfg_error ? 8'h08 : 8'h00);
    img_mf_pair_join #(.DATA_WIDTH(17), .TAG_WIDTH(TAG_WIDTH), .FRAME_WIDTH(FRAME_WIDTH)) join_i (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_valid(s_valid), .s_ready(s_ready), .s_data({9'd0,s_data}), .s_sof(s_sof), .s_eol(s_eol), .s_tag(s_tag), .s_frameid(s_frameid),
        .aux_valid(aux_valid), .aux_ready(aux_ready), .aux_data({aux_initialized,aux_data}), .aux_sof(aux_sof), .aux_eol(aux_eol), .aux_tag(aux_tag), .aux_frameid(aux_frameid),
        .m_valid(p_valid), .m_ready(p_ready), .m_data(p_data), .m_aux_data(p_aux), .m_sof(p_sof), .m_eol(p_eol), .m_tag(p_tag), .m_frameid(p_frameid), .m_error(p_error), .error_code(pair_sticky)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_shift <= 4'd4; shadow_shift <= 4'd4;
            active_threshold <= 8'd16; shadow_threshold <= 8'd16;
            active_freeze <= 1'b1; shadow_freeze <= 1'b1;
            cfg_pending <= 0; cfg_error <= 0;
            m_valid <= 0; m_data <= 0; m_difference <= 0; m_foreground <= 0;
            m_sof <= 0; m_eol <= 0; m_tag <= 0; m_frameid <= 0; m_error <= 0;
            wb_valid <= 0; wb_data <= 0; wb_enable <= 0; wb_sof <= 0; wb_eol <= 0;
            wb_tag <= 0; wb_frameid <= 0; wb_error <= 0;
        end else if (clk_en) begin
            if (cfg_ready) begin
                if (cfg_we && cfg_update_shift <= 4'd8) begin
                    shadow_shift <= cfg_update_shift; shadow_threshold <= cfg_threshold;
                    shadow_freeze <= cfg_freeze_foreground;
                end
                if (cfg_we && cfg_update_shift > 4'd8) cfg_error <= 1'b1;
                if (cfg_commit) begin
                    if (!cfg_we || cfg_update_shift <= 4'd8) cfg_pending <= 1'b1;
                    else cfg_error <= 1'b1;
                end
            end
            if (m_valid && m_ready) m_valid <= 1'b0;
            if (wb_valid && wb_ready) wb_valid <= 1'b0;
            if (room && p_valid) begin
                m_valid <= 1'b1; wb_valid <= 1'b1;
                m_data <= (p_error == 0) ? current_pixel : 8'd0;
                m_difference <= (p_error == 0 && initialized) ? difference : 8'd0;
                m_foreground <= (p_error == 0) && foreground_now;
                m_sof <= p_sof; m_eol <= p_eol; m_tag <= p_tag; m_frameid <= p_frameid;
                m_error <= p_error;
                wb_data <= (p_error == 0) ? background_next : 16'd0;
                wb_enable <= (p_error == 0);
                wb_sof <= p_sof; wb_eol <= p_eol; wb_tag <= p_tag; wb_frameid <= p_frameid;
                wb_error <= p_error;
                if (new_cfg) begin
                    active_shift <= shadow_shift; active_threshold <= shadow_threshold;
                    active_freeze <= shadow_freeze; cfg_pending <= 1'b0;
                end
            end
        end
    end
endmodule
