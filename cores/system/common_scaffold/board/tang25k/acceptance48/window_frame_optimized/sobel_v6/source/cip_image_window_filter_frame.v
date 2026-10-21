// Pixel stream -> two synchronous line buffers -> one 3x3 kernel -> cropped stream.
// OP0 mean, OP1 Gaussian, OP2 median, OP3 Sobel, OP4 Prewitt, OP5 Laplacian.
module cip_image_window_filter_frame #(
    parameter PIXEL_W=8,MAX_WIDTH=1920,TAG_W=16,OP=0,EDGE_SHIFT=0
)(
    input wire clk,rst_n,clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width,cfg_height,
    input wire [TAG_W-1:0] cfg_tag,
    input wire [PIXEL_W-1:0] s_data,
    input wire s_valid,s_sof,s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire signed [PIXEL_W+3:0] m_aux0,m_aux1,
    output wire [PIXEL_W+3:0] m_magnitude,
    output wire m_valid,m_sof,m_eol,m_eof,
    output wire [TAG_W-1:0] m_tag,
    input wire m_ready,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    output reg [TAG_W-1:0] rsp_tag,
    output reg [31:0] rsp_pixels,
    output reg [15:0] out_width,out_height
);
localparam IDLE=0,CONFIGURE=1,ACTIVE=2,RESPONSE=3;
reg [1:0] state;
reg [15:0] width,height;
reg [TAG_W-1:0] frame_tag;
reg window_seen,last_seen,local_reset;
reg [3:0] window_error;
reg [31:0] emitted,expected;
// Asynchronous assertion, clocked release and local-reset capture avoid a
// combinational reset cascade through downstream valid registers.
reg core_rst_n;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)core_rst_n<=0;
    else core_rst_n<=!local_reset;
end
wire window_cfg_ready,window_rsp_valid,window_s_ready,window_valid,window_sof,window_eol,kernel_ready;
wire [3:0] window_rsp_error;
wire [9*PIXEL_W-1:0] taps;
wire kernel_valid,kernel_sof,kernel_eol;
wire output_fire=m_valid && m_ready;
wire last_fire=output_fire && m_eof;
wire window_response=state==ACTIVE && window_rsp_valid && !window_seen;
wire legal=cfg_width>=3 && cfg_height>=3 && cfg_width<=MAX_WIDTH && MAX_WIDTH>=3 && MAX_WIDTH<=65535;
assign cfg_ready=rst_n && state==IDLE && !rsp_valid && !local_reset;
assign s_ready=state==ACTIVE && window_s_ready;
assign m_valid=rst_n && state==ACTIVE && kernel_valid;
assign m_sof=m_valid && kernel_sof;
assign m_eol=m_valid && kernel_eol;
assign m_eof=m_valid && emitted==expected-1;
assign m_tag=frame_tag;
img_window3x3_valid_draft #(.PIXEL_W(PIXEL_W),.MAX_WIDTH(MAX_WIDTH)) window_core(
    .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),
    .cfg_valid(state==CONFIGURE),.cfg_ready(window_cfg_ready),.cfg_width(width),.cfg_height(height),
    .rsp_valid(window_rsp_valid),.rsp_ready(state==ACTIVE && !window_seen),.rsp_error(window_rsp_error),
    .s_data(s_data),.s_valid(state==ACTIVE && s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(window_s_ready),
    .m_taps(taps),.m_center(),.m_x(),.m_y(),.m_valid(window_valid),.m_sof(window_sof),.m_eol(window_eol),.m_eof(),
    .m_ready(state==ACTIVE && kernel_ready));
generate if(OP<=2)begin:spatial
    img_filter_kernel3x3 #(.PIXEL_W(PIXEL_W),.OP(OP)) kernel(
        .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),.s_taps(taps),
        .s_valid(state==ACTIVE && window_valid),.s_sof(window_sof),.s_eol(window_eol),.s_ready(kernel_ready),
        .m_data(m_data),.m_valid(kernel_valid),.m_sof(kernel_sof),.m_eol(kernel_eol),.m_ready(state==ACTIVE && m_ready));
    assign m_aux0=0;assign m_aux1=0;assign m_magnitude=0;
end else if(OP<5)begin:gradient
    img_edge_gradient3x3 #(.PIXEL_W(PIXEL_W),.KERNEL(OP-3),.MAG_SHIFT(EDGE_SHIFT)) kernel(
        .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),.s_taps(taps),
        .s_valid(state==ACTIVE && window_valid),.s_sof(window_sof),.s_eol(window_eol),.s_ready(kernel_ready),
        .m_data(m_data),.m_gx(m_aux0),.m_gy(m_aux1),.m_magnitude(m_magnitude),
        .m_valid(kernel_valid),.m_sof(kernel_sof),.m_eol(kernel_eol),.m_ready(state==ACTIVE && m_ready));
end else begin:laplacian
    img_edge_laplacian3x3 #(.PIXEL_W(PIXEL_W),.MAG_SHIFT(EDGE_SHIFT)) kernel(
        .clk(clk),.rst_n(core_rst_n),.clk_en(clk_en),.s_taps(taps),
        .s_valid(state==ACTIVE && window_valid),.s_sof(window_sof),.s_eol(window_eol),.s_ready(kernel_ready),
        .m_data(m_data),.m_response(m_aux0),.m_valid(kernel_valid),.m_sof(kernel_sof),.m_eol(kernel_eol),
        .m_ready(state==ACTIVE && m_ready));
    assign m_aux1=0;
    assign m_magnitude=m_aux0[PIXEL_W+3]?-m_aux0:m_aux0;
end endgenerate
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        state<=IDLE;width<=0;height<=0;frame_tag<=0;
        window_seen<=0;last_seen<=0;local_reset<=0;window_error<=0;emitted<=0;expected<=0;
        rsp_valid<=0;rsp_error<=0;rsp_tag<=0;rsp_pixels<=0;out_width<=0;out_height<=0;
    end else if(clk_en) begin
        local_reset<=0;
        case(state)
        IDLE:if(cfg_valid && cfg_ready) begin
            frame_tag<=cfg_tag;rsp_tag<=cfg_tag;
            width<=cfg_width;height<=cfg_height;window_seen<=0;last_seen<=0;window_error<=0;emitted<=0;
            rsp_pixels<=0;
            if(!legal) begin rsp_valid<=1;rsp_error<=1;out_width<=0;out_height<=0;state<=RESPONSE;end
            else begin
                out_width<=cfg_width-2;out_height<=cfg_height-2;
                expected<=(32'd1*(cfg_width-2))*(cfg_height-2);state<=CONFIGURE;
            end
        end
        CONFIGURE:if(window_cfg_ready) state<=ACTIVE;
        ACTIVE:begin
            if(output_fire) emitted<=emitted+1;
            if(last_fire) last_seen<=1;
            if(window_response) begin window_seen<=1;window_error<=window_rsp_error;end
            if(window_response && window_rsp_error!=0 && window_rsp_error!=2) begin
                local_reset<=1;rsp_valid<=1;rsp_error<=window_rsp_error;
                rsp_pixels<=emitted+(output_fire?1:0);state<=RESPONSE;
            end else if((window_seen || window_response) && (last_seen || last_fire)) begin
                rsp_valid<=1;rsp_error<=window_response?window_rsp_error:window_error;
                rsp_pixels<=emitted+(output_fire?1:0);state<=RESPONSE;
            end
        end
        RESPONSE:if(rsp_ready) begin rsp_valid<=0;state<=IDLE;end
        default:state<=IDLE;
        endcase
    end
end
`ifndef SYNTHESIS
initial if(PIXEL_W<1 || PIXEL_W>32 || OP<0 || OP>5 || EDGE_SHIFT<0)
    $fatal(1,"window filter supports PIXEL_W1..32 and OP0..5");
`endif
endmodule
