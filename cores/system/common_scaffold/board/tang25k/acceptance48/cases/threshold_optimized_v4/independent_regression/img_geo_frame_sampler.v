// Development draft. Random-read frame sampler; no internal frame or line array.
// One outstanding memory read; nearest (mode 0) or four-read bilinear (mode 1).
// Memory addresses and stride are in packed PIXEL WORDS, not bytes.
// Memory response cannot arrive in the request acceptance cycle; at least one
// registered response cycle is required. External memory must obey backpressure.
module img_geo_frame_sampler #(
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
localparam IDLE=0, REQUEST=1, RESPONSE=2, H_PRODUCTS=3, H_SUMS=4,
           V_PRODUCTS=5, ROUND_SUM=6, EXTRACT=7, OUTPUT_PIXEL=8,
           V_ROW_SUMS=9, V_RECOMBINE=10;
localparam H_W=PIXEL_W+9, V_W=PIXEL_W+18, SUM_W=PIXEL_W+19;
// Split each horizontal row and each eight-bit weight before multiplication.
// All partial products fit at most 13x4 bits for supported PIXEL_W<=16.
// The inverse weight's ninth bit means exactly 256 (only when frac_y=0),
// so that case is an exact shift bypass, not a ninth multiplier input.
localparam ROW_LO=H_W/2, ROW_HI=H_W-ROW_LO;
localparam [3:0] E_CONFIG=1, E_UNSUPPORTED=3, E_MEMORY=5, E_ADDRESS=6, E_COORD=7;
reg [3:0] state;
reg [1:0] sample_index;
reg bilinear;
reg [15:0] x0, x1, y0, y1;
reg [7:0] frac_x, frac_y;
reg [31:0] stride;
reg [ADDR_W-1:0] base_addr;
reg [PIXEL_W*LANES-1:0] p00, p10, p01, p11;
wire [8:0] weight_x={1'b0,frac_x},weight_y={1'b0,frac_y};
wire [8:0] inverse_x=9'd256-weight_x,inverse_y=9'd256-weight_y;
reg [H_W-1:0] h00[0:LANES-1],h10[0:LANES-1],h01[0:LANES-1],h11[0:LANES-1];
reg [H_W-1:0] row0[0:LANES-1],row1[0:LANES-1];
reg [ROW_LO+3:0] v0_ll[0:LANES-1],v0_lh[0:LANES-1];
reg [ROW_HI+3:0] v0_hl[0:LANES-1],v0_hh[0:LANES-1];
reg [ROW_LO+3:0] v1_ll[0:LANES-1],v1_lh[0:LANES-1];
reg [ROW_HI+3:0] v1_hl[0:LANES-1],v1_hh[0:LANES-1];
reg [ROW_LO+7:0] v0_low[0:LANES-1],v1_low[0:LANES-1];
reg [ROW_HI+7:0] v0_high[0:LANES-1],v1_high[0:LANES-1];
reg [V_W-1:0] vertical0[0:LANES-1],vertical1[0:LANES-1];
reg [SUM_W-1:0] rounded[0:LANES-1];
integer lane;
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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state<=IDLE; sample_index<=0; bilinear<=0;
        x0<=0; x1<=0; y0<=0; y1<=0; frac_x<=0; frac_y<=0;
        stride<=0; base_addr<=0; p00<=0; p10<=0; p01<=0; p11<=0;
        m_data<=0; m_error<=0; m_sof<=0; m_eol<=0; m_eof<=0;
        for(lane=0;lane<LANES;lane=lane+1)begin
            h00[lane]<=0;h10[lane]<=0;h01[lane]<=0;h11[lane]<=0;
            row0[lane]<=0;row1[lane]<=0;
            v0_ll[lane]<=0;v0_lh[lane]<=0;v0_hl[lane]<=0;v0_hh[lane]<=0;
            v1_ll[lane]<=0;v1_lh[lane]<=0;v1_hl[lane]<=0;v1_hh[lane]<=0;
            v0_low[lane]<=0;v0_high[lane]<=0;
            v1_low[lane]<=0;v1_high[lane]<=0;
            vertical0[lane]<=0;vertical1[lane]<=0;rounded[lane]<=0;
        end
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
                    if (sample_index==3) state<=H_PRODUCTS;
                    else begin sample_index<=sample_index+1'b1; state<=REQUEST; end
                end
            end
            H_PRODUCTS: begin
                for(lane=0;lane<LANES;lane=lane+1)begin
                    h00[lane]<=p00[lane*PIXEL_W +: PIXEL_W]*inverse_x;
                    h10[lane]<=p10[lane*PIXEL_W +: PIXEL_W]*weight_x;
                    h01[lane]<=p01[lane*PIXEL_W +: PIXEL_W]*inverse_x;
                    h11[lane]<=p11[lane*PIXEL_W +: PIXEL_W]*weight_x;
                end
                state<=H_SUMS;
            end
            H_SUMS: begin
                for(lane=0;lane<LANES;lane=lane+1)begin
                    row0[lane]<=h00[lane]+h10[lane];
                    row1[lane]<=h01[lane]+h11[lane];
                end
                state<=V_PRODUCTS;
            end
            V_PRODUCTS: begin
                for(lane=0;lane<LANES;lane=lane+1)begin
                    v0_ll[lane]<=row0[lane][ROW_LO-1:0]*inverse_y[3:0];
                    v0_lh[lane]<=row0[lane][ROW_LO-1:0]*inverse_y[7:4];
                    v0_hl[lane]<=row0[lane][H_W-1:ROW_LO]*inverse_y[3:0];
                    v0_hh[lane]<=row0[lane][H_W-1:ROW_LO]*inverse_y[7:4];
                    v1_ll[lane]<=row1[lane][ROW_LO-1:0]*weight_y[3:0];
                    v1_lh[lane]<=row1[lane][ROW_LO-1:0]*weight_y[7:4];
                    v1_hl[lane]<=row1[lane][H_W-1:ROW_LO]*weight_y[3:0];
                    v1_hh[lane]<=row1[lane][H_W-1:ROW_LO]*weight_y[7:4];
                end
                state<=V_ROW_SUMS;
            end
            V_ROW_SUMS: begin
                for(lane=0;lane<LANES;lane=lane+1)begin
                    v0_low[lane]<={4'b0,v0_ll[lane]}+{v0_lh[lane],4'b0};
                    v0_high[lane]<={4'b0,v0_hl[lane]}+{v0_hh[lane],4'b0};
                    v1_low[lane]<={4'b0,v1_ll[lane]}+{v1_lh[lane],4'b0};
                    v1_high[lane]<={4'b0,v1_hl[lane]}+{v1_hh[lane],4'b0};
                end
                state<=V_RECOMBINE;
            end
            V_RECOMBINE: begin
                for(lane=0;lane<LANES;lane=lane+1)begin
                    vertical0[lane]<=inverse_y[8] ? {1'b0,row0[lane],8'b0} :
                        {{(ROW_HI+1){1'b0}},v0_low[lane]}+
                        {1'b0,v0_high[lane],{ROW_LO{1'b0}}};
                    vertical1[lane]<=
                        {{(ROW_HI+1){1'b0}},v1_low[lane]}+
                        {1'b0,v1_high[lane],{ROW_LO{1'b0}}};
                end
                state<=ROUND_SUM;
            end
            ROUND_SUM: begin
                for(lane=0;lane<LANES;lane=lane+1)
                    rounded[lane]<={1'b0,vertical0[lane]}+{1'b0,vertical1[lane]}+32768;
                state<=EXTRACT;
            end
            EXTRACT: begin
                // Exactly one half-up rounding after both dimensions. No
                // row truncation; max total before rounding is MAX_PIXEL<<16.
                for(lane=0;lane<LANES;lane=lane+1)
                    m_data[lane*PIXEL_W +: PIXEL_W]<=rounded[lane][16 +: PIXEL_W];
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
