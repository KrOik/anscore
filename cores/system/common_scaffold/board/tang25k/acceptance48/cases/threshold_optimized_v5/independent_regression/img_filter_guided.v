// Complete grayscale guided filtering, backed by the two-box-pass guided engine.
// Source/guide are accepted atomically. PIXEL_W=8 is supported; other widths
// return a finite command error. Epsilon Q8 is rounded UP to squared guide units
// (minimum 1); source and guide therefore keep the original 8-bit pixel scale.
module img_filter_guided #(parameter PIXEL_W=8,parameter MAX_WIDTH=64,
    parameter MAX_HEIGHT=64,parameter MAX_RADIUS=3)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width, cfg_height,
    input wire [7:0] cfg_radius,
    input wire [2*PIXEL_W+7:0] cfg_epsilon_q8,
    output wire rsp_valid, input wire rsp_ready,
    output wire [7:0] rsp_tag, rsp_error,
    input wire [PIXEL_W-1:0] s_data, s_guide_data,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    input wire s_guide_valid, s_guide_sof, s_guide_eol, output wire s_guide_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    wire core_cmd_ready,core_ready,core_rsp_valid;
    wire [7:0] core_tag;
    wire [3:0] core_error;
    wire [15:0] core_q;
    wire [31:0] epsilon_wide=cfg_epsilon_q8;
    wire [31:0] epsilon_integer=(epsilon_wide>>8)+(|epsilon_wide[7:0]);
    wire invalid_config=(PIXEL_W!=8 || cfg_radius>MAX_RADIUS ||
        cfg_radius>15 || epsilon_wide==0 || epsilon_integer>65535);
    reg reject_valid,pair_error;
    reg [7:0] rejected_tag;
    assign cmd_ready=rst_n && clk_en && !reject_valid && core_cmd_ready;
    assign s_ready=core_ready && s_guide_valid;
    assign s_guide_ready=core_ready && s_valid;
    assign rsp_valid=reject_valid || core_rsp_valid;
    assign rsp_tag=reject_valid?rejected_tag:core_tag;
    assign rsp_error=reject_valid?8'h01:({4'b0,core_error} | (pair_error?8'h20:8'h00));
    wire [16:0] rounded_q={1'b0,core_q}+17'd64;
    assign m_data=(rounded_q>=17'd32768)?255:(rounded_q>>7);
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin reject_valid<=0;rejected_tag<=0;pair_error<=0;end
        else if(clk_en)begin
            if(reject_valid && rsp_ready)reject_valid<=0;
            if(cmd_valid && cmd_ready)begin
                pair_error<=0;
                if(invalid_config)begin reject_valid<=1;rejected_tag<=cmd_tag;end
            end
            if(s_valid && s_ready && (s_sof!=s_guide_sof || s_eol!=s_guide_eol))pair_error<=1;
        end
    end
    img_dh_guided_frame #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),
        .MAX_RADIUS(MAX_RADIUS),.TAG_WIDTH(8)) guided_engine (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(cmd_valid && !invalid_config && !reject_valid),.cmd_ready(core_cmd_ready),
        .cmd_width(cfg_width),.cmd_height(cfg_height),.cmd_radius(cfg_radius[3:0]),
        .cmd_epsilon(epsilon_integer),.cmd_tag(cmd_tag),
        .s_guide(s_guide_data),.s_p({1'b0,s_data,7'b0}),
        .s_valid(s_valid && s_guide_valid),.s_ready(core_ready),.s_sof(s_sof),.s_eol(s_eol),
        .m_q(core_q),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_eof(),.m_tag(),
        .rsp_valid(core_rsp_valid),.rsp_ready(rsp_ready && !reject_valid),
        .rsp_error(core_error),.rsp_tag(core_tag),.busy()
    );
endmodule
