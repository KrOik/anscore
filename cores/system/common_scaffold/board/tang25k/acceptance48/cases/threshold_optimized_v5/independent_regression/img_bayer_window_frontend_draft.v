// RAW -> synchronous valid 3x3 window -> RGB888 frontend.
// Small-frame reference group checked; synthesis/timing/board unmeasured.
// Shared CE transfer: clk_en && valid && ready. Crops one pixel on each edge.
module img_bayer_window_frontend_draft #(
    parameter integer RAW_BITS = 8,
    parameter integer MAX_WIDTH = 1920
) (
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width, cfg_height,
    input wire [1:0] cfg_pattern,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output reg [15:0] out_width, out_height,
    // A nonpositive RAW_BITS still has a one-bit port so it can return error.
    input wire [((RAW_BITS > 0) ? RAW_BITS : 1)-1:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [23:0] m_data,
    output wire m_valid, m_sof, m_eol, m_eof,
    input wire m_ready
);
    localparam integer RAW_SUPPORTED = (RAW_BITS == 8) ||
                                      (RAW_BITS == 10) || (RAW_BITS == 12);
    localparam integer STORAGE_SUPPORTED = (MAX_WIDTH >= 3) && (MAX_WIDTH <= 65535);

    generate if (RAW_SUPPORTED && STORAGE_SUPPORTED) begin : g_frontend
        localparam [1:0] S_IDLE = 0, S_ACTIVE = 1, S_ERROR_DRAIN = 2, S_RESPONSE = 3;
        reg [1:0] state;
        reg local_reset;
        reg window_result_seen, last_rgb_seen;
        reg [3:0] window_result, terminal_error;
        reg eof_sideband;
        wire core_rst_n = rst_n && !local_reset;
        wire legal_dimensions = (cfg_width >= 3) && (cfg_height >= 3) &&
                                (cfg_width <= MAX_WIDTH);
        wire window_cfg_ready, bayer_cfg_ready, bayer_cfg_pending;
        wire cfg_fire = cfg_valid && cfg_ready;
        // An illegal size never writes/commits Bayer's shadow pattern.
        wire legal_cfg_fire = cfg_fire && legal_dimensions;
        wire window_rsp_valid, window_rsp_ready;
        wire [3:0] window_rsp_error;
        wire window_s_ready;
        wire [9*RAW_BITS-1:0] window_taps;
        wire [RAW_BITS-1:0] window_center;
        wire [15:0] window_x, window_y;
        wire window_valid, window_sof, window_eol, window_eof;
        wire bayer_s_ready, bayer_valid, bayer_sof, bayer_eol;
        wire [23:0] bayer_rgb;
        wire bayer_unsupported, bayer_error;
        wire [3:0] bayer_error_code;
        wire output_enabled = (state == S_ACTIVE) || (state == S_ERROR_DRAIN);
        wire bayer_m_ready = m_ready && output_enabled;
        wire window_fire = clk_en && (state == S_ACTIVE) && window_valid && bayer_s_ready;
        wire window_rsp_fire = window_rsp_valid && window_rsp_ready;
        wire rgb_fire = clk_en && m_valid && m_ready;
        wire last_rgb_fire = rgb_fire && m_eof;
        wire fatal_window = window_rsp_fire && (window_rsp_error != 0) &&
                            (window_rsp_error != 4'd2);
        wire fatal_bayer = bayer_unsupported || bayer_error;
        wire frame_complete = (window_result_seen || window_rsp_fire) &&
                              (last_rgb_seen || last_rgb_fire);
        assign cfg_ready = rst_n && clk_en && (state == S_IDLE) && !rsp_valid &&
                           window_cfg_ready && bayer_cfg_ready && !bayer_cfg_pending;
        assign s_ready = (state == S_ACTIVE) && window_s_ready;
        assign window_rsp_ready = rst_n && clk_en && (state == S_ACTIVE) &&
                                  !window_result_seen;
        assign m_data = bayer_rgb;
        assign m_valid = bayer_valid && output_enabled;
        assign m_sof = bayer_sof;
        assign m_eol = bayer_eol;
        assign m_eof = eof_sideband;

        img_window3x3_valid_draft #(.PIXEL_W(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) u_window (
            .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),
            .cfg_valid(legal_cfg_fire),.cfg_ready(window_cfg_ready),
            .cfg_width(cfg_width),.cfg_height(cfg_height),
            .rsp_valid(window_rsp_valid),.rsp_ready(window_rsp_ready),.rsp_error(window_rsp_error),
            .s_data(s_data),.s_valid(s_valid && (state == S_ACTIVE)),
            .s_sof(s_sof),.s_eol(s_eol),.s_ready(window_s_ready),
            .m_taps(window_taps),.m_center(window_center),.m_x(window_x),.m_y(window_y),
            .m_valid(window_valid),.m_sof(window_sof),.m_eol(window_eol),.m_eof(window_eof),
            .m_ready(bayer_s_ready && (state == S_ACTIVE))
        );
        img_isp_bayer_interpolate #(.RAW_BITS(RAW_BITS),.EXTERNAL_WINDOW(1)) u_bayer (
            .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),
            .s_data(window_center),.s_window(window_taps),
            .s_x_odd(window_x[0]),.s_y_odd(window_y[0]),
            .s_valid(window_valid && (state == S_ACTIVE)),.s_ready(bayer_s_ready),
            .s_sof(window_sof),.s_eol(window_eol),
            .m_data(bayer_rgb),.m_valid(bayer_valid),.m_ready(bayer_m_ready),
            .m_sof(bayer_sof),.m_eol(bayer_eol),
            .cfg_we(legal_cfg_fire),.cfg_commit(legal_cfg_fire),.cfg_pattern(cfg_pattern),
            .cfg_ready(bayer_cfg_ready),.cfg_pending(bayer_cfg_pending),
            .unsupported(bayer_unsupported),.error(bayer_error),.error_code(bayer_error_code)
        );

        // EOF uses the exact acceptance/retirement rules of
        // Bayer's one-entry output register. A stalled RGB retains its EOF.
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) eof_sideband <= 0;
            else if (clk_en) begin
                if (rgb_fire) eof_sideband <= 0;
                if (window_fire) eof_sideband <= window_eof;
                if (local_reset) eof_sideband <= 0;
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state <= S_IDLE; local_reset <= 0;
                window_result_seen <= 0; last_rgb_seen <= 0;
                window_result <= 0; terminal_error <= 0;
                rsp_valid <= 0; rsp_error <= 0;
                out_width <= 0; out_height <= 0;
            end else if (clk_en) begin
                case (state)
                    S_IDLE: if (cfg_fire) begin
                        window_result_seen <= 0; last_rgb_seen <= 0;
                        window_result <= 0; terminal_error <= 0;
                        if (!legal_dimensions) begin
                            out_width <= 0; out_height <= 0;
                            rsp_error <= 4'd1; rsp_valid <= 1; state <= S_RESPONSE;
                        end else begin
                            out_width <= cfg_width - 16'd2;
                            out_height <= cfg_height - 16'd2;
                            state <= S_ACTIVE;
                        end
                    end
                    S_ACTIVE: begin
                        if (window_rsp_fire) begin
                            window_result_seen <= 1; window_result <= window_rsp_error;
                        end
                        if (last_rgb_fire) last_rgb_seen <= 1;
                        if (fatal_bayer) begin
                            terminal_error <= bayer_unsupported ? 4'd5 : 4'd6;
                            state <= S_ERROR_DRAIN;
                        end else if (fatal_window) begin
                            terminal_error <= window_rsp_error;
                            state <= S_ERROR_DRAIN;
                        end else if (frame_complete) begin
                            rsp_error <= window_rsp_fire ? window_rsp_error : window_result;
                            rsp_valid <= 1; state <= S_RESPONSE;
                        end
                    end
                    S_ERROR_DRAIN: begin
                        // Stop accepting RAW/window pixels. Retain any RGB
                        // already presented until it is consumed, then abort
                        // the partial internal frame and report the cause.
                        if (!bayer_valid || bayer_m_ready) begin
                            local_reset <= 1;
                            rsp_error <= terminal_error; rsp_valid <= 1;
                            state <= S_RESPONSE;
                        end
                    end
                    S_RESPONSE: if (rsp_valid && rsp_ready) begin
                        rsp_valid <= 0; state <= S_IDLE; local_reset <= 0;
                    end
                    default: begin
                        local_reset <= 1; rsp_error <= 4'd3;
                        rsp_valid <= 1; state <= S_RESPONSE;
                    end
                endcase
            end
        end
    end else begin : g_unsupported_parameters
        // Unsupported parameters receive a bounded error
        // response after cfg handshake; the source stream is never consumed.
        assign cfg_ready = rst_n && clk_en && !rsp_valid;
        assign s_ready = 1'b0;
        assign m_data = 24'd0; assign m_valid = 1'b0;
        assign m_sof = 1'b0; assign m_eol = 1'b0; assign m_eof = 1'b0;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                rsp_valid <= 0; rsp_error <= 0; out_width <= 0; out_height <= 0;
            end else if (clk_en) begin
                if (rsp_valid && rsp_ready) rsp_valid <= 0;
                if (cfg_valid && cfg_ready) begin
                    rsp_valid <= 1;
                    rsp_error <= RAW_SUPPORTED ? 4'd7 : 4'd4;
                end
            end
        end
    end endgenerate
endmodule
