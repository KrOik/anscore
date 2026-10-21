// Ordinary ready/valid native single-port byte-addressed synchronous RAM.
// One response per request, byte write strobes, aligned full-word reads.
// RAM/read register are not reset; initialization is the caller's responsibility.
module cip_native_byte_ram #(parameter ADDR_WIDTH=32,DATA_WIDTH=32,WORDS=1024)(
    input wire clk,rst_n,
    input wire req_valid,output wire req_ready,input wire req_write,
    input wire [ADDR_WIDTH-1:0] req_addr,input wire [DATA_WIDTH-1:0] req_wdata,
    input wire [DATA_WIDTH/8-1:0] req_wstrb,
    output reg rsp_valid,input wire rsp_ready,
    output reg [DATA_WIDTH-1:0] rsp_rdata,output reg rsp_error
);
    localparam BYTES=DATA_WIDTH/8,LSB=$clog2(BYTES);
    (* ram_style="block" *) reg [DATA_WIDTH-1:0] memory[0:WORDS-1];
    wire bad=(req_addr & (BYTES-1))!=0 || (req_addr>>LSB)>=WORDS;
    integer lane;
    assign req_ready=rst_n && !rsp_valid;
    always @(posedge clk)if(req_valid && req_ready && !bad)begin
        if(req_write)begin
            for(lane=0;lane<BYTES;lane=lane+1)
                if(req_wstrb[lane])memory[req_addr>>LSB][lane*8+:8]<=req_wdata[lane*8+:8];
        end else rsp_rdata<=memory[req_addr>>LSB];
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin rsp_valid<=0;rsp_error<=0;end
        else begin
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(req_valid && req_ready)begin rsp_valid<=1;rsp_error<=bad;end
        end
    end
    initial if(DATA_WIDTH<8 || DATA_WIDTH%8 || (BYTES&(BYTES-1)) || WORDS<1 || ADDR_WIDTH<1)
        $fatal(1,"cip_native_byte_ram invalid parameters");
endmodule
