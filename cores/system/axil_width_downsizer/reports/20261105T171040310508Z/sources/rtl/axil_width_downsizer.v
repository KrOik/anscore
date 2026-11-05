// SPDX-License-Identifier: Apache-2.0
// Original ANSCORE implementation: one aligned wide access to narrow AXI-Lite.
`default_nettype none
module axil_width_downsizer #(
    parameter ADDR_W=16,
    parameter S_DATA_W=32,
    parameter M_DATA_W=8
) (
    input wire clk, input wire rst,
    input wire [ADDR_W-1:0] s_awaddr, input wire [2:0] s_awprot,
    input wire s_awvalid, output wire s_awready,
    input wire [S_DATA_W-1:0] s_wdata, input wire [S_DATA_W/8-1:0] s_wstrb,
    input wire s_wvalid, output wire s_wready,
    output reg [1:0] s_bresp, output reg s_bvalid, input wire s_bready,
    input wire [ADDR_W-1:0] s_araddr, input wire [2:0] s_arprot,
    input wire s_arvalid, output wire s_arready,
    output reg [S_DATA_W-1:0] s_rdata, output reg [1:0] s_rresp,
    output reg s_rvalid, input wire s_rready,
    output wire [ADDR_W-1:0] m_awaddr, output wire [2:0] m_awprot,
    output wire m_awvalid, input wire m_awready,
    output wire [M_DATA_W-1:0] m_wdata, output wire [M_DATA_W/8-1:0] m_wstrb,
    output wire m_wvalid, input wire m_wready,
    input wire [1:0] m_bresp, input wire m_bvalid, output wire m_bready,
    output wire [ADDR_W-1:0] m_araddr, output wire [2:0] m_arprot,
    output wire m_arvalid, input wire m_arready,
    input wire [M_DATA_W-1:0] m_rdata, input wire [1:0] m_rresp,
    input wire m_rvalid, output wire m_rready
);
    localparam S_BYTES=S_DATA_W/8, M_BYTES=M_DATA_W/8;
    localparam PARTS=S_DATA_W/M_DATA_W;
    localparam IW=(PARTS<=2)?1:$clog2(PARTS);
    localparam ALIGN_W=$clog2(S_BYTES);
    generate if ((S_DATA_W!=16 && S_DATA_W!=32 && S_DATA_W!=64) ||
                 (M_DATA_W!=8 && M_DATA_W!=16 && M_DATA_W!=32) ||
                 M_DATA_W>=S_DATA_W || ADDR_W<ALIGN_W || ADDR_W>64)
        begin : invalid_parameters
            axil_width_downsizer_invalid_parameters__see_README invalid();
        end
    endgenerate
    localparam [1:0] W_IDLE=0,W_SCAN=1,W_SEND=2;
    localparam [1:0] R_IDLE=0,R_SEND=1;
    reg [1:0] wr_state,rd_state;
    reg aw_have,w_have,aw_done,w_done,ar_done;
    reg [ADDR_W-1:0] aw_buf,ar_buf;
    reg [2:0] awprot_buf,arprot_buf;
    reg [S_DATA_W-1:0] data_buf,read_buf;
    reg [S_BYTES-1:0] strb_buf;
    reg [IW-1:0] wi,ri;
    reg [1:0] write_resp,read_resp;
    reg [S_DATA_W-1:0] assembled_read;
    always @* begin
        assembled_read=read_buf;
        assembled_read[ri*M_DATA_W+:M_DATA_W]=m_rdata;
    end

    // The numeric order is intentional: DECERR > SLVERR > EXOKAY > OKAY.
    function [1:0] merge_response;
        input [1:0] old_response,new_response;
        begin merge_response=(new_response>old_response)?new_response:old_response; end
    endfunction
    wire [1:0] next_bresp=merge_response(write_resp,m_bresp);
    wire [1:0] next_rresp=merge_response(read_resp,m_rresp);
    assign s_awready=!rst && wr_state==W_IDLE && !aw_have && !s_bvalid;
    assign s_wready=!rst && wr_state==W_IDLE && !w_have && !s_bvalid;
    assign s_arready=!rst && rd_state==R_IDLE && !s_rvalid;
    assign m_awaddr=aw_buf + wi*M_BYTES;
    assign m_awprot=awprot_buf;
    assign m_wdata=data_buf[wi*M_DATA_W+:M_DATA_W];
    assign m_wstrb=strb_buf[wi*M_BYTES+:M_BYTES];
    assign m_awvalid=!rst && wr_state==W_SEND && !aw_done;
    assign m_wvalid=!rst && wr_state==W_SEND && !w_done;
    assign m_bready=!rst && wr_state==W_SEND && aw_done && w_done;
    assign m_araddr=ar_buf + ri*M_BYTES;
    assign m_arprot=arprot_buf;
    assign m_arvalid=!rst && rd_state==R_SEND && !ar_done;
    assign m_rready=!rst && rd_state==R_SEND && ar_done;

    always @(posedge clk) begin
        if(rst) begin
            wr_state<=W_IDLE;rd_state<=R_IDLE;aw_have<=0;w_have<=0;
            aw_done<=0;w_done<=0;ar_done<=0;
            aw_buf<=0;ar_buf<=0;awprot_buf<=0;arprot_buf<=0;
            data_buf<=0;strb_buf<=0;read_buf<=0;
            wi<=0;ri<=0;write_resp<=0;read_resp<=0;
            s_bresp<=0;s_bvalid<=0;s_rdata<=0;s_rresp<=0;s_rvalid<=0;
        end else begin
            if(s_bvalid&&s_bready) s_bvalid<=0;
            if(s_rvalid&&s_rready) s_rvalid<=0;
            if(s_awvalid&&s_awready) begin
                aw_buf<=s_awaddr;awprot_buf<=s_awprot;aw_have<=1;
            end
            if(s_wvalid&&s_wready) begin
                data_buf<=s_wdata;strb_buf<=s_wstrb;w_have<=1;
            end
            case(wr_state)
                W_IDLE: if(aw_have&&w_have&&!s_bvalid) begin
                    aw_have<=0;w_have<=0;wi<=0;write_resp<=0;
                    if(aw_buf[ALIGN_W-1:0]!=0) begin s_bvalid<=1;s_bresp<=2'b11;end
                    else wr_state<=W_SCAN;
                end
                W_SCAN: begin
                    if(|m_wstrb) begin aw_done<=0;w_done<=0;wr_state<=W_SEND;end
                    else if(wi==PARTS-1) begin
                        s_bvalid<=1;s_bresp<=write_resp;wr_state<=W_IDLE;
                    end else wi<=wi+1'b1;
                end
                W_SEND: begin
                    if(m_awvalid&&m_awready) aw_done<=1;
                    if(m_wvalid&&m_wready) w_done<=1;
                    if(m_bvalid&&m_bready) begin
                        write_resp<=next_bresp;
                        if(wi==PARTS-1) begin
                            s_bvalid<=1;s_bresp<=next_bresp;wr_state<=W_IDLE;
                        end else begin wi<=wi+1'b1;wr_state<=W_SCAN;end
                    end
                end
                default: wr_state<=W_IDLE;
            endcase
            if(s_arvalid&&s_arready) begin
                ar_buf<=s_araddr;arprot_buf<=s_arprot;
                ri<=0;read_buf<=0;read_resp<=0;ar_done<=0;
                if(s_araddr[ALIGN_W-1:0]!=0) begin s_rvalid<=1;s_rdata<=0;s_rresp<=2'b11;end
                else rd_state<=R_SEND;
            end
            if(rd_state==R_SEND) begin
                if(m_arvalid&&m_arready) ar_done<=1;
                if(m_rvalid&&m_rready) begin
                    read_buf<=assembled_read;
                    read_resp<=next_rresp;
                    if(ri==PARTS-1) begin
                        s_rdata<=assembled_read;
                        s_rresp<=next_rresp;s_rvalid<=1;rd_state<=R_IDLE;
                    end else begin ri<=ri+1'b1;ar_done<=0;end
                end
            end
        end
    end
endmodule
`default_nettype wire
