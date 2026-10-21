// Development draft. Random-read frame sampler; no internal frame or line array.
// One outstanding memory read; nearest (mode 0) or four-read bilinear (mode 1).
// Memory addresses and stride are in packed PIXEL WORDS, not bytes.
// Memory response cannot arrive in the request acceptance cycle; at least one
// registered response cycle is required. External memory must obey backpressure.
module img_geo_frame_sampler_baseline #(
    parameter PIXEL_W=8,
    parameter LANES=3,
    parameter ADDR_W=32,
    parameter [PIXEL_W*LANES-1:0] BORDER_DATA=0
)(
    input wire clk, rst_n, clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [23:0] s_x_q8, s_y_q8,
    input wire s_border,
    input wire [3:0] s_error,
    input wire s_sof, s_eol, s_eof,
    input wire [1:0] s_filter,
    input wire [15:0] s_src_width, s_src_height,
    input wire [31:0] s_stride,
    input wire [ADDR_W-1:0] s_base_addr,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire mem_req_read,
    output wire [ADDR_W-1:0] mem_req_addr,
    input wire mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire [PIXEL_W*LANES-1:0] mem_rsp_data,
    input wire mem_rsp_error,
    output wire m_valid,
    input wire m_ready,
    output reg [PIXEL_W*LANES-1:0] m_data,
    output reg [3:0] m_error,
    output reg m_sof, m_eol, m_eof
);
localparam IDLE=0, REQUEST=1, RESPONSE=2, INTERPOLATE=3, OUTPUT_PIXEL=4;
localparam [3:0] E_CONFIG=1, E_UNSUPPORTED=3, E_MEMORY=5, E_ADDRESS=6, E_COORD=7;
reg [2:0] state;
reg [1:0] sample_index;
reg bilinear;
reg [15:0] x0, x1, y0, y1;
reg [7:0] frac_x, frac_y;
reg [31:0] stride;
reg [ADDR_W-1:0] base_addr;
reg [PIXEL_W*LANES-1:0] p00, p10, p01, p11;
reg [63:0] address_wide, address_x, address_y, address_stride, address_base;
wire address_overflow = |(address_wide >> ADDR_W);
always @* begin
    address_x = sample_index[0] ? x1 : x0;
    address_y = sample_index[1] ? y1 : y0;
    address_stride = stride;
    address_base = base_addr;
    address_wide = address_base+address_y*address_stride+address_x;
end
assign s_ready = rst_n && state==IDLE;
assign mem_req_valid = rst_n && state==REQUEST && !address_overflow;
assign mem_req_read = 1'b1;
assign mem_req_addr = address_wide[ADDR_W-1:0];
assign mem_rsp_ready = rst_n && state==RESPONSE;
assign m_valid = state==OUTPUT_PIXEL;

function [PIXEL_W*LANES-1:0] blend4;
    input [PIXEL_W*LANES-1:0] a, b, c, d;
    input [7:0] fx, fy;
    integer lane;
    reg [63:0] aa, bb, cc, dd, wx, wy, ix, iy, total;
    begin
        wx=fx; wy=fy; ix=64'd256-wx; iy=64'd256-wy;
        blend4=0;
        for (lane=0; lane<LANES; lane=lane+1) begin
            aa=a[lane*PIXEL_W +: PIXEL_W];
            bb=b[lane*PIXEL_W +: PIXEL_W];
            cc=c[lane*PIXEL_W +: PIXEL_W];
            dd=d[lane*PIXEL_W +: PIXEL_W];
            total=(aa*ix*iy+bb*wx*iy+cc*ix*wy+dd*wx*wy+64'd32768)>>16;
            blend4[lane*PIXEL_W +: PIXEL_W]=total[PIXEL_W-1:0];
        end
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state<=IDLE; sample_index<=0; bilinear<=0;
        x0<=0; x1<=0; y0<=0; y1<=0; frac_x<=0; frac_y<=0;
        stride<=0; base_addr<=0; p00<=0; p10<=0; p01<=0; p11<=0;
        m_data<=0; m_error<=0; m_sof<=0; m_eol<=0; m_eof<=0;
    end else if (clk_en) begin
        case (state)
            IDLE: if (s_valid && s_ready) begin
                m_sof<=s_sof; m_eol<=s_eol; m_eof<=s_eof;
                m_data<=BORDER_DATA; m_error<=s_error;
                stride<=s_stride; base_addr<=s_base_addr;
                frac_x<=s_x_q8[7:0]; frac_y<=s_y_q8[7:0];
                x0<=s_x_q8[23:8]; y0<=s_y_q8[23:8];
                x1<=s_x_q8[23:8]<s_src_width-1'b1 ? s_x_q8[23:8]+1'b1 : s_x_q8[23:8];
                y1<=s_y_q8[23:8]<s_src_height-1'b1 ? s_y_q8[23:8]+1'b1 : s_y_q8[23:8];
                sample_index<=0; bilinear<=s_filter==1;
                if (s_error!=0) state<=OUTPUT_PIXEL;
                else if (s_src_width==0 || s_src_height==0 || s_stride<s_src_width) begin
                    m_error<=E_CONFIG; state<=OUTPUT_PIXEL;
                end else if (s_filter>1) begin
                    m_error<=E_UNSUPPORTED; state<=OUTPUT_PIXEL;
                end else if (s_border) state<=OUTPUT_PIXEL;
                else if (s_x_q8[23:8]>=s_src_width || s_y_q8[23:8]>=s_src_height) begin
                    m_error<=E_COORD; state<=OUTPUT_PIXEL;
                end else begin
                    if (s_filter==0) begin
                        // Round-to-nearest, half upward, with edge replication.
                        if (s_x_q8[7] && s_x_q8[23:8]<s_src_width-1'b1)
                            x0<=s_x_q8[23:8]+1'b1;
                        if (s_y_q8[7] && s_y_q8[23:8]<s_src_height-1'b1)
                            y0<=s_y_q8[23:8]+1'b1;
                    end
                    state<=REQUEST;
                end
            end
            REQUEST: begin
                if (address_overflow) begin
                    m_error<=E_ADDRESS; m_data<=BORDER_DATA; state<=OUTPUT_PIXEL;
                end else if (mem_req_valid && mem_req_ready) state<=RESPONSE;
            end
            RESPONSE: if (mem_rsp_valid && mem_rsp_ready) begin
                if (mem_rsp_error) begin
                    m_error<=E_MEMORY; m_data<=BORDER_DATA; state<=OUTPUT_PIXEL;
                end else if (!bilinear) begin
                    m_data<=mem_rsp_data; state<=OUTPUT_PIXEL;
                end else begin
                    case (sample_index)
                        0: p00<=mem_rsp_data;
                        1: p10<=mem_rsp_data;
                        2: p01<=mem_rsp_data;
                        3: p11<=mem_rsp_data;
                    endcase
                    if (sample_index==3) state<=INTERPOLATE;
                    else begin sample_index<=sample_index+1'b1; state<=REQUEST; end
                end
            end
            INTERPOLATE: begin
                m_data<=blend4(p00,p10,p01,p11,frac_x,frac_y);
                state<=OUTPUT_PIXEL;
            end
            OUTPUT_PIXEL: if (m_ready) state<=IDLE;
            default: begin state<=IDLE; m_error<=E_CONFIG; end
        endcase
    end
end
// Supported parameter contract: 1 <= PIXEL_W <= 16, LANES >= 1,
// 1 <= ADDR_W <= 32. No timeout: a memory response is required after each read.
endmodule
