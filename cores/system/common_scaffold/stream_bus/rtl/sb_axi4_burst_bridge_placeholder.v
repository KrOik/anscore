// Legacy name retained for compatibility. This is now a real AXI4 RAM endpoint,
// implemented by sb_axi4_native_bridge and a synchronous byte-write memory.
// RAM content is unspecified after reset; resetting does not erase the RAM.
module sb_axi4_burst_bridge_placeholder #(
    parameter ADDR_WIDTH=32,parameter DATA_WIDTH=32,parameter ID_WIDTH=4,
    parameter MEM_WORDS=1024
)(
    input wire clk,rst_n,clk_en,
    input wire [ID_WIDTH-1:0] s_axi_awid,input wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [7:0] s_axi_awlen,input wire [2:0] s_axi_awsize,input wire [1:0] s_axi_awburst,
    input wire s_axi_awvalid,output wire s_axi_awready,
    input wire [DATA_WIDTH-1:0] s_axi_wdata,input wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input wire s_axi_wlast,s_axi_wvalid,output wire s_axi_wready,
    output wire [ID_WIDTH-1:0] s_axi_bid,output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,input wire s_axi_bready,
    input wire [ID_WIDTH-1:0] s_axi_arid,input wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [7:0] s_axi_arlen,input wire [2:0] s_axi_arsize,input wire [1:0] s_axi_arburst,
    input wire s_axi_arvalid,output wire s_axi_arready,
    output wire [ID_WIDTH-1:0] s_axi_rid,output wire [DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,output wire s_axi_rlast,
    output wire s_axi_rvalid,input wire s_axi_rready,output wire protocol_error
);
    localparam BYTES=DATA_WIDTH/8,LSB=$clog2(BYTES);
    reg [DATA_WIDTH-1:0] memory [0:MEM_WORDS-1];
    wire req_valid,req_ready,req_write,rsp_ready;
    wire [ADDR_WIDTH-1:0] req_addr;
    wire [DATA_WIDTH-1:0] req_wdata;
    wire [BYTES-1:0] req_wstrb;
    reg rsp_valid,rsp_error;
    reg [DATA_WIDTH-1:0] rsp_rdata;
    integer lane;
    assign req_ready=rst_n && !rsp_valid;
    sb_axi4_native_bridge #(.ADDR_WIDTH(ADDR_WIDTH),.DATA_WIDTH(DATA_WIDTH),.ID_WIDTH(ID_WIDTH)) bridge(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_axi_awid(s_axi_awid),.s_axi_awaddr(s_axi_awaddr),.s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize),.s_axi_awburst(s_axi_awburst),.s_axi_awvalid(s_axi_awvalid),.s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),.s_axi_wstrb(s_axi_wstrb),.s_axi_wlast(s_axi_wlast),.s_axi_wvalid(s_axi_wvalid),.s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid),.s_axi_bresp(s_axi_bresp),.s_axi_bvalid(s_axi_bvalid),.s_axi_bready(s_axi_bready),
        .s_axi_arid(s_axi_arid),.s_axi_araddr(s_axi_araddr),.s_axi_arlen(s_axi_arlen),
        .s_axi_arsize(s_axi_arsize),.s_axi_arburst(s_axi_arburst),.s_axi_arvalid(s_axi_arvalid),.s_axi_arready(s_axi_arready),
        .s_axi_rid(s_axi_rid),.s_axi_rdata(s_axi_rdata),.s_axi_rresp(s_axi_rresp),.s_axi_rlast(s_axi_rlast),
        .s_axi_rvalid(s_axi_rvalid),.s_axi_rready(s_axi_rready),.protocol_error(protocol_error),
        .mem_req_valid(req_valid),.mem_req_ready(req_ready),.mem_req_write(req_write),.mem_req_addr(req_addr),
        .mem_req_wdata(req_wdata),.mem_req_wstrb(req_wstrb),.mem_rsp_valid(rsp_valid),.mem_rsp_ready(rsp_ready),
        .mem_rsp_rdata(rsp_rdata),.mem_rsp_error(rsp_error));
    // Data memory is not reset. Registered reads and byte write enables permit
    // block-RAM inference; a separate response register obeys backpressure.
    always @(posedge clk)begin
        if(req_valid && req_ready && (req_addr>>LSB)<MEM_WORDS && req_write)
            for(lane=0;lane<BYTES;lane=lane+1)
                if(req_wstrb[lane])memory[req_addr>>LSB][lane*8+:8]<=req_wdata[lane*8+:8];
        if(req_valid && req_ready && (req_addr>>LSB)<MEM_WORDS && !req_write)
            rsp_rdata<=memory[req_addr>>LSB];
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin rsp_valid<=0;rsp_error<=0;end
        else begin
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(req_valid && req_ready)begin rsp_valid<=1;rsp_error<=((req_addr>>LSB)>=MEM_WORDS);end
        end
    end
    initial if(MEM_WORDS<1)$fatal(1,"sb_axi4_burst_bridge_placeholder: MEM_WORDS must be positive");
endmodule
