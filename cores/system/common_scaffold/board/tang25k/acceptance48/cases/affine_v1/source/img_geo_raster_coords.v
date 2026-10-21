// Development draft. Configured output-raster coordinate source.
// Dimensions are pixel counts in [1,65535]. Coordinates change only on transfer.
module img_geo_raster_coords (
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width, cfg_height,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output reg m_valid,
    input wire m_ready,
    output reg [15:0] m_x, m_y,
    output wire m_sof, m_eol, m_eof
);
reg [15:0] width, height;
assign cfg_ready = rst_n && !m_valid && !rsp_valid;
assign m_sof = m_x==0 && m_y==0;
assign m_eol = m_x==width-1'b1;
assign m_eof = m_eol && m_y==height-1'b1;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        width<=0; height<=0; m_x<=0; m_y<=0; m_valid<=0;
        rsp_valid<=0; rsp_error<=0;
    end else if (clk_en) begin
        if (rsp_valid && rsp_ready) rsp_valid<=0;
        if (cfg_valid && cfg_ready) begin
            width<=cfg_width; height<=cfg_height; m_x<=0; m_y<=0;
            if (cfg_width==0 || cfg_height==0) begin
                rsp_valid<=1; rsp_error<=1;
            end else begin m_valid<=1; rsp_error<=0; end
        end
        if (m_valid && m_ready) begin
            if (m_eof) begin m_valid<=0; rsp_valid<=1; rsp_error<=0; end
            else if (m_eol) begin m_x<=0; m_y<=m_y+1'b1; end
            else m_x<=m_x+1'b1;
        end
    end
end
endmodule
