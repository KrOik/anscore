// One-outstanding bridge from shared-CE native memory to ordinary ready/valid.
// The s_* transfer requires clk_en; m_* runs on every physical clock edge.
// Capture request/response payloads to prevent loss when the DMA CE pauses.
// Addresses/lanes are transported unchanged. This is NOT a clock-domain crossing.
module cip_native_ce_adapter #(parameter ADDR_WIDTH=32,DATA_WIDTH=32)(
    input wire clk,rst_n,clk_en,
    input wire s_req_valid,output wire s_req_ready,input wire s_req_write,
    input wire [ADDR_WIDTH-1:0] s_req_addr,
    input wire [DATA_WIDTH-1:0] s_req_wdata,input wire [DATA_WIDTH/8-1:0] s_req_wstrb,
    output wire s_rsp_valid,input wire s_rsp_ready,
    output wire [DATA_WIDTH-1:0] s_rsp_rdata,output wire s_rsp_error,
    output wire m_req_valid,input wire m_req_ready,output reg m_req_write,
    output reg [ADDR_WIDTH-1:0] m_req_addr,
    output reg [DATA_WIDTH-1:0] m_req_wdata,output reg [DATA_WIDTH/8-1:0] m_req_wstrb,
    input wire m_rsp_valid,output wire m_rsp_ready,
    input wire [DATA_WIDTH-1:0] m_rsp_rdata,input wire m_rsp_error
);
    localparam IDLE=0,SEND=1,WAIT_REPLY=2,REPLY=3;
    reg [1:0] state;
    reg [DATA_WIDTH-1:0] data_reg;
    reg error_reg;
    assign s_req_ready=rst_n && clk_en && state==IDLE;
    assign s_rsp_valid=rst_n && state==REPLY;
    assign s_rsp_rdata=data_reg;assign s_rsp_error=error_reg;
    assign m_req_valid=rst_n && state==SEND;
    assign m_rsp_ready=rst_n && state==WAIT_REPLY;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=IDLE;m_req_write<=0;m_req_addr<=0;m_req_wdata<=0;m_req_wstrb<=0;data_reg<=0;error_reg<=0;
        end else case(state)
          IDLE:if(clk_en && s_req_valid)begin
              m_req_write<=s_req_write;m_req_addr<=s_req_addr;
              m_req_wdata<=s_req_wdata;m_req_wstrb<=s_req_wstrb;state<=SEND;
          end
          SEND:if(m_req_ready)state<=WAIT_REPLY;
          WAIT_REPLY:if(m_rsp_valid)begin data_reg<=m_rsp_rdata;error_reg<=m_rsp_error;state<=REPLY;end
          REPLY:if(clk_en && s_rsp_ready)state<=IDLE;
          default:state<=IDLE;
        endcase
    end
endmodule
