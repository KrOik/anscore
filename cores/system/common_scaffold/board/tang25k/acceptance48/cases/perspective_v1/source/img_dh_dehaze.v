// Legacy external-window, scalar-dark adapter. New raw-frame integrations MUST
// use img_dh_dehaze_frame, which supplies full synchronous buffering, automatic
// airlight, normalized per-channel DCP and actual guided refinement. This legacy
// module preserves its old ports and EXTERNAL_WINDOW=0 rejection semantics.
// Parameters are committed atomically at an accepted input SOF, and carried as
// pixel metadata through the elastic pipeline, including across frame changes.
module img_dh_dehaze #(
    parameter integer EXTERNAL_WINDOW = 0,
    parameter integer TAPS = 9
) (
    input wire clk, rst_n, clk_en,
    input wire [23:0] s_data,
    input wire [TAPS*8-1:0] s_dark_window,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [23:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready,
    input wire cfg_we, cfg_commit,
    input wire [23:0] cfg_airlight_rgb,
    input wire [7:0] cfg_airlight_gray,
    input wire [15:0] cfg_omega, cfg_t0,
    input wire cfg_refine_enable,
    output wire cfg_ready,
    output reg cfg_pending, cfg_rejected,
    output wire unsupported, error
);
    reg [23:0] shadow_rgb, active_rgb;
    reg [7:0] shadow_gray, active_gray;
    reg [15:0] shadow_omega, active_omega, shadow_t0, active_t0;
    reg shadow_refine;
    reg cfg_error, framing_error, have_frame;
    wire [23:0] commit_rgb = cfg_we ? cfg_airlight_rgb : shadow_rgb;
    wire [7:0] commit_gray = cfg_we ? cfg_airlight_gray : shadow_gray;
    wire [15:0] commit_omega = cfg_we ? cfg_omega : shadow_omega;
    wire [15:0] commit_t0 = cfg_we ? cfg_t0 : shadow_t0;
    wire commit_refine = cfg_we ? cfg_refine_enable : shadow_refine;
    wire bad_config = (commit_gray == 0) || (commit_omega > 16'd32768) ||
                      (commit_t0 == 0) || (commit_t0 > 16'd32768) || commit_refine;
    wire apply_config = cfg_pending && s_sof;
    wire [63:0] pixel_meta = apply_config ?
        {shadow_gray,shadow_rgb,shadow_omega,shadow_t0} :
        {active_gray,active_rgb,active_omega,active_t0};
    wire legal_frame = have_frame || s_sof;
    wire window_ready;
    wire arithmetic_error;
    assign cfg_ready = clk_en && !cfg_pending;
    assign s_ready = (EXTERNAL_WINDOW != 0) && window_ready &&
                     (legal_frame || !s_valid);
    assign unsupported = (EXTERNAL_WINDOW == 0) || cfg_error;
    assign error = framing_error || cfg_error || arithmetic_error;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_rgb <= 24'hffffff; active_rgb <= 24'hffffff;
            shadow_gray <= 8'hff; active_gray <= 8'hff;
            shadow_omega <= 16'd29491; active_omega <= 16'd29491;
            shadow_t0 <= 16'd3277; active_t0 <= 16'd3277;
            shadow_refine <= 0; cfg_pending <= 0; cfg_rejected <= 0;
            cfg_error <= 0; framing_error <= 0; have_frame <= 0;
        end else if (clk_en) begin
            cfg_rejected <= 0;
            if (s_valid && ((EXTERNAL_WINDOW == 0) || !legal_frame))
                framing_error <= 1;
            if (cfg_we && cfg_ready) begin
                shadow_rgb <= cfg_airlight_rgb;
                shadow_gray <= cfg_airlight_gray;
                shadow_omega <= cfg_omega; shadow_t0 <= cfg_t0;
                shadow_refine <= cfg_refine_enable;
            end
            if (cfg_commit && cfg_ready) begin
                if (bad_config || (EXTERNAL_WINDOW == 0)) begin
                    cfg_rejected <= 1; cfg_error <= 1;
                end else cfg_pending <= 1;
            end
            if (s_valid && s_ready) begin
                have_frame <= 1;
                if (apply_config) begin
                    active_rgb <= shadow_rgb; active_gray <= shadow_gray;
                    active_omega <= shadow_omega; active_t0 <= shadow_t0;
                    cfg_pending <= 0;
                end
            end
        end
    end

    generate if (EXTERNAL_WINDOW != 0) begin : g_external_window
        wire [7:0] dark;
        wire [23:0] dark_rgb;
        wire [63:0] dark_meta;
        wire dark_valid, dark_ready, dark_sof, dark_eol;
        wire [15:0] t, t_floor;
        wire [23:0] t_rgb, t_airlight;
        wire t_valid, t_ready, t_sof, t_eol;
        wire transmission_error, restore_error;
        wire transmission_unsupported, restore_unsupported;
        img_dh_window_min #(.TAPS(TAPS),.META_WIDTH(64)) u_window_min (
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
            .s_window(s_dark_window),.s_rgb(s_data),.s_meta(pixel_meta),
            .s_valid(s_valid && legal_frame),.s_sof(s_sof),.s_eol(s_eol),
            .s_ready(window_ready),.m_dark(dark),.m_rgb(dark_rgb),
            .m_meta(dark_meta),.m_valid(dark_valid),.m_sof(dark_sof),
            .m_eol(dark_eol),.m_ready(dark_ready)
        );
        img_dh_transmission u_transmission (
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
            .s_dark(dark),.s_airlight_gray(dark_meta[63:56]),
            .s_rgb(dark_rgb),.s_airlight_rgb(dark_meta[55:32]),
            .s_omega(dark_meta[31:16]),.s_t0(dark_meta[15:0]),
            .s_valid(dark_valid),.s_sof(dark_sof),.s_eol(dark_eol),
            .s_ready(dark_ready),.m_t(t),.m_t0(t_floor),.m_rgb(t_rgb),
            .m_airlight_rgb(t_airlight),.m_valid(t_valid),.m_sof(t_sof),
            .m_eol(t_eol),.m_ready(t_ready),.unsupported(transmission_unsupported),
            .error(transmission_error)
        );
        img_dh_restore u_restore (
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
            .s_rgb(t_rgb),.s_airlight_rgb(t_airlight),.s_t(t),.s_t0(t_floor),
            .s_valid(t_valid),.s_sof(t_sof),.s_eol(t_eol),.s_ready(t_ready),
            .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),
            .m_ready(m_ready),.unsupported(restore_unsupported),.error(restore_error)
        );
        assign arithmetic_error = transmission_error || restore_error;
    end else begin : g_raw_stream_placeholder
        assign window_ready = 1'b0;
        assign m_data = 0; assign m_valid = 0;
        assign m_sof = 0; assign m_eol = 0;
        assign arithmetic_error = 1'b0;
    end endgenerate
endmodule
