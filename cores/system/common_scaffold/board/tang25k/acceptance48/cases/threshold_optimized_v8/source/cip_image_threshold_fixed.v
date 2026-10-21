// Hand-maintained fixed-threshold frame adapter. See FUNCTIONAL_IMAGE_ABI.md.
// Other modes explicitly unsupported; DATA_W is a single unsigned gray sample.
module cip_image_threshold_fixed #(parameter DATA_W=24, parameter TAG_W=8)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [15:0] cfg_src_width, cfg_src_height,
    input wire [15:0] cfg_dst_width, cfg_dst_height,
    input wire [3:0] cfg_mode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire [31:0] cfg_frame_base, cfg_frame_stride,
    input wire [31:0] cfg_aux_base,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [15:0] coeff_addr,
    input wire [31:0] coeff_data,
    input wire [DATA_W-1:0] aux_data,
    input wire aux_valid, aux_sof, aux_eol,
    output wire aux_ready,
    output wire mem_req_valid, mem_req_write,
    output wire [31:0] mem_req_addr, mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_req_ready, mem_rsp_valid,
    input wire [31:0] mem_rsp_rdata,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    input wire s_sof, s_eol,
    output reg m_sof, m_eol,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output reg [DATA_W-1:0] m_data,
    output reg m_valid,
    input wire m_ready
);
assign mem_req_valid=0;
assign mem_req_write=0;
assign mem_req_addr=0;
assign mem_req_wdata=0;
assign mem_req_wstrb=0;
assign mem_rsp_ready=0;
assign coeff_ready=0;
assign aux_ready=0;
reg active,closed,bad_marker;
reg [15:0] width,x,y;
reg [31:0] remaining;
reg [DATA_W-1:0] threshold;
reg invert,last_buffer;
reg [TAG_W-1:0] frame_tag;
wire slot_ready=!m_valid || m_ready;
assign cmd_ready=rst_n && !active && !rsp_valid;
assign s_ready=rst_n && active && !closed && slot_ready;
wire marker_bad=(s_sof != (x==0 && y==0)) || (s_eol != (x==width-1));
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        active<=0;closed<=0;bad_marker<=0;width<=0;x<=0;y<=0;remaining<=0;
        threshold<=0;invert<=0;last_buffer<=0;frame_tag<=0;
        rsp_valid<=0;rsp_tag<=0;rsp_error<=0;m_valid<=0;m_data<=0;m_sof<=0;m_eol<=0;
    end else if(clk_en) begin
        if(rsp_valid && rsp_ready) rsp_valid<=0;
        if(cmd_valid && cmd_ready) begin
            rsp_tag<=cmd_tag;
            if(cfg_mode!=0) begin rsp_valid<=1;rsp_error<=1;end
            else if(DATA_W<1 || DATA_W>32 || cfg_src_width==0 || cfg_src_height==0 ||
                cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height ||
                (cfg_param0 >> DATA_W)!=0 || cfg_param1>1 ||
                cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0) begin
                rsp_valid<=1;rsp_error<=2;
            end else begin
                active<=1;closed<=0;bad_marker<=0;width<=cfg_src_width;
                x<=0;y<=0;remaining<={16'b0,cfg_src_width}*{16'b0,cfg_src_height};
                threshold<=cfg_param0;invert<=cfg_param1[0];frame_tag<=cmd_tag;
            end
        end
        if(m_valid && m_ready) begin
            m_valid<=0;
            if(last_buffer) begin
                active<=0;rsp_valid<=1;rsp_tag<=frame_tag;
                rsp_error<=bad_marker?2'd2:2'd0;
            end
        end
        if(s_valid && s_ready) begin
            m_valid<=1;m_data<={DATA_W{(s_data>=threshold)^invert}};
            // Regenerate markers from dimensions, report input marker errors at completion.
            m_sof<=(x==0 && y==0);m_eol<=(x==width-1);
            last_buffer<=remaining==1;remaining<=remaining-1;
            if(remaining==1) closed<=1;
            if(marker_bad) bad_marker<=1;
            if(x==width-1) begin x<=0;y<=y+1;end else x<=x+1;
        end
    end
end
endmodule
