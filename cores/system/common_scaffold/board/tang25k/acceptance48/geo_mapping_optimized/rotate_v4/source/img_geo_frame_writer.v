// Development draft. Stream-to-frame write controller, one acknowledged pixel
// write at a time. Memory addresses/stride use packed pixel words. No RAM array.
module img_geo_frame_writer #(
    parameter DATA_W=24,
    parameter ADDR_W=32
)(
    input wire clk, rst_n, clk_en,
    input wire cfg_valid,
    output wire cfg_ready,
    input wire [15:0] cfg_width, cfg_height,
    input wire [31:0] cfg_stride,
    input wire [ADDR_W-1:0] cfg_base_addr,
    output wire busy,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [3:0] rsp_error,
    input wire s_valid,
    output wire s_ready,
    input wire [DATA_W-1:0] s_data,
    input wire s_sof,s_eol,
    output wire mem_req_valid,
    input wire mem_req_ready,
    output wire mem_req_write,
    output reg [ADDR_W-1:0] mem_req_addr,
    output reg [DATA_W-1:0] mem_req_data,
    input wire mem_rsp_valid,
    output wire mem_rsp_ready,
    input wire mem_rsp_error
);
localparam IDLE=0, TAKE_PIXEL=1, WRITE_REQUEST=2, WRITE_RESPONSE=3, ADVANCE=4;
reg [2:0] state;
reg [15:0] width,height,x,y;
reg [31:0] stride;
reg [ADDR_W-1:0] base_addr;
reg [3:0] first_error;
reg [63:0] address_wide,wide_x,wide_y,wide_stride,wide_base;
always @* begin
    wide_x=x; wide_y=y; wide_stride=stride; wide_base=base_addr;
    address_wide=wide_base+wide_y*wide_stride+wide_x;
end
wire address_overflow = |(address_wide >> ADDR_W);
assign cfg_ready=rst_n && state==IDLE && !rsp_valid;
assign busy=state!=IDLE;
assign s_ready=rst_n && state==TAKE_PIXEL;
assign mem_req_valid=rst_n && state==WRITE_REQUEST;
assign mem_req_write=1'b1;
assign mem_rsp_ready=rst_n && state==WRITE_RESPONSE;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state<=IDLE; width<=0; height<=0; x<=0; y<=0; stride<=0; base_addr<=0;
        first_error<=0; rsp_valid<=0; rsp_error<=0; mem_req_addr<=0; mem_req_data<=0;
    end else if (clk_en) begin
        if (rsp_valid && rsp_ready) rsp_valid<=0;
        case (state)
            IDLE: if (cfg_valid && cfg_ready) begin
                rsp_error<=0;
                if (cfg_width==0 || cfg_height==0 || cfg_stride<cfg_width) begin
                    rsp_valid<=1; rsp_error<=1;
                end else begin
                    width<=cfg_width; height<=cfg_height; stride<=cfg_stride;
                    base_addr<=cfg_base_addr; x<=0; y<=0; first_error<=0; state<=TAKE_PIXEL;
                end
            end
            TAKE_PIXEL: if (s_valid && s_ready) begin
                if (first_error==0 && (s_sof!=(x==0 && y==0) || s_eol!=(x==width-1'b1)))
                    first_error<=2;
                if (address_overflow) begin
                    if (first_error==0) first_error<=6;
                    state<=ADVANCE;
                end else begin
                    mem_req_addr<=address_wide[ADDR_W-1:0]; mem_req_data<=s_data;
                    state<=WRITE_REQUEST;
                end
            end
            WRITE_REQUEST: if (mem_req_valid && mem_req_ready) state<=WRITE_RESPONSE;
            WRITE_RESPONSE: if (mem_rsp_valid && mem_rsp_ready) begin
                if (mem_rsp_error && first_error==0) first_error<=5;
                state<=ADVANCE;
            end
            ADVANCE: begin
                if (x==width-1'b1 && y==height-1'b1) begin
                    state<=IDLE; rsp_valid<=1; rsp_error<=first_error;
                end else begin
                    if (x==width-1'b1) begin x<=0; y<=y+1'b1; end
                    else x<=x+1'b1;
                    state<=TAKE_PIXEL;
                end
            end
            default: state<=IDLE;
        endcase
    end
end
// No response timeout or rollback. A reported error can leave a partial frame.
// Parameter contract: DATA_W >= 1, 1 <= ADDR_W <= 32.
endmodule
