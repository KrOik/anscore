// Decoded-descriptor native mem-to-mem DMA, one bus transaction outstanding.
// The descriptor endpoint supplies fields, not raw packed memory words.
module cip_dma_descriptor_chain #(
    parameter DATA_WIDTH=32, ADDR_WIDTH=32, LEN_WIDTH=32, TAG_WIDTH=16,
    parameter MAX_DESCRIPTORS=256
)(
    input wire clk, rst_n, clk_en, abort,
    input wire cmd_valid, output wire cmd_ready,
    input wire [ADDR_WIDTH-1:0] cmd_head_addr,
    input wire [TAG_WIDTH-1:0] cmd_tag,
    output wire rsp_valid, input wire rsp_ready,
    output wire rsp_error, output reg [7:0] rsp_status,
    output reg [TAG_WIDTH-1:0] rsp_tag,
    output reg [ADDR_WIDTH-1:0] rsp_head_addr,
    output reg [LEN_WIDTH-1:0] rsp_bytes,
    output reg [TAG_WIDTH-1:0] rsp_descriptor_tag,
    output reg [31:0] rsp_descriptors,
    output wire rsp_terminal, busy, done, irq,
    output wire desc_req_valid, input wire desc_req_ready,
    output wire [ADDR_WIDTH-1:0] desc_req_addr,
    input wire desc_rsp_valid, output wire desc_rsp_ready,
    input wire [ADDR_WIDTH-1:0] desc_rsp_src, desc_rsp_dst,
    input wire [LEN_WIDTH-1:0] desc_rsp_byte_len,
    input wire [ADDR_WIDTH-1:0] desc_rsp_next, input wire desc_rsp_last,
    input wire [TAG_WIDTH-1:0] desc_rsp_tag, input wire desc_rsp_error,
    output wire mem_req_valid, input wire mem_req_ready,
    output wire mem_req_write,
    output wire [ADDR_WIDTH-1:0] mem_req_addr,
    output wire [DATA_WIDTH-1:0] mem_req_wdata,
    output wire [DATA_WIDTH/8-1:0] mem_req_wstrb,
    input wire mem_rsp_valid, output wire mem_rsp_ready,
    input wire [DATA_WIDTH-1:0] mem_rsp_rdata, input wire mem_rsp_error
);
    localparam BYTE_LANES=DATA_WIDTH/8;
    localparam RANGE_W=(ADDR_WIDTH>LEN_WIDTH ? ADDR_WIDTH:LEN_WIDTH);
    localparam IDLE=0, DESC_REQ=1, DESC_RSP=2, READ_REQ=3, READ_RSP=4,
               WRITE_REQ=5, WRITE_RSP=6, NEXT_DESC=7, REPLY=8;
    localparam [7:0] OK=0, BAD_COMMAND=2, MEMORY_ERROR=4, ABORTED=5,
                     DESCRIPTOR_ERROR=7, CHAIN_LIMIT=8, OVERLAP_ERROR=9;
    reg [3:0] state;
    reg [ADDR_WIDTH-1:0] descriptor_addr, source_addr, destination_addr, next_addr;
    reg [LEN_WIDTH-1:0] remaining;
    reg [DATA_WIDTH-1:0] data_hold;
    reg [31:0] fetched;
    reg last_descriptor, abort_pending;
    wire stopping=abort || abort_pending;
    wire [LEN_WIDTH-1:0] beat_bytes=(remaining>=BYTE_LANES) ? BYTE_LANES:remaining;
    wire final_beat=(remaining<=BYTE_LANES);
    wire [LEN_WIDTH:0] prospective_bytes={1'b0,rsp_bytes}+{1'b0,desc_rsp_byte_len};
    genvar g;
    generate for(g=0;g<BYTE_LANES;g=g+1) begin: lanes
        assign mem_req_wstrb[g]=(state==WRITE_REQ) && g<remaining;
    end endgenerate
    function range_bad;
        input [ADDR_WIDTH-1:0] a;
        input [LEN_WIDTH-1:0] n;
        reg [RANGE_W:0] ae, ne, limit;
        begin
            ae=a; ne=n; limit=1; limit=limit<<ADDR_WIDTH;
            range_bad=(ae+ne)>limit;
        end
    endfunction
    function overlap_bad;
        input [ADDR_WIDTH-1:0] a,b;
        input [LEN_WIDTH-1:0] n;
        reg [RANGE_W:0] ae,be,ne;
        begin
            ae=a; be=b; ne=n;
            overlap_bad=(a!=b) && (ae<be+ne) && (be<ae+ne);
        end
    endfunction
    assign cmd_ready=rst_n && state==IDLE;
    assign rsp_valid=rst_n && state==REPLY;
    assign rsp_error=(rsp_status!=OK);
    assign rsp_terminal=1'b1;
    assign busy=rst_n && state!=IDLE;
    assign done=rsp_valid && rsp_ready && clk_en;
    assign irq=done;
    assign desc_req_valid=rst_n && state==DESC_REQ;
    assign desc_req_addr=descriptor_addr;
    assign desc_rsp_ready=rst_n && state==DESC_RSP;
    assign mem_req_valid=rst_n && (state==READ_REQ || state==WRITE_REQ);
    assign mem_req_write=(state==WRITE_REQ);
    assign mem_req_addr=(state==WRITE_REQ) ? destination_addr:source_addr;
    assign mem_req_wdata=data_hold;
    assign mem_rsp_ready=rst_n && (state==READ_RSP || state==WRITE_RSP);
    initial begin
        if(DATA_WIDTH<8 || DATA_WIDTH%8!=0 || ADDR_WIDTH<1 || LEN_WIDTH<1 ||
           TAG_WIDTH<1 || MAX_DESCRIPTORS<1) $fatal(1,"invalid descriptor DMA parameters");
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; descriptor_addr<=0; source_addr<=0; destination_addr<=0;
            next_addr<=0; remaining<=0; data_hold<=0; fetched<=0;
            last_descriptor<=0; abort_pending<=0;
            rsp_status<=OK; rsp_tag<=0; rsp_head_addr<=0; rsp_bytes<=0;
            rsp_descriptor_tag<=0; rsp_descriptors<=0;
        end else if(clk_en) begin
            if(abort && state!=IDLE && state!=REPLY) abort_pending<=1;
            case(state)
                IDLE: if(cmd_valid) begin
                    rsp_tag<=cmd_tag; rsp_head_addr<=cmd_head_addr;
                    descriptor_addr<=cmd_head_addr; rsp_bytes<=0;
                    rsp_status<=OK; rsp_descriptor_tag<=0; rsp_descriptors<=0;
                    fetched<=0; abort_pending<=0;
                    if(abort) begin rsp_status<=ABORTED; state<=REPLY; end
                    else state<=DESC_REQ;
                end
                DESC_REQ: if(desc_req_ready) state<=DESC_RSP;
                DESC_RSP: if(desc_rsp_valid) begin
                    rsp_descriptor_tag<=desc_rsp_tag; fetched<=fetched+1;
                    if(desc_rsp_error) begin rsp_status<=DESCRIPTOR_ERROR; state<=REPLY; end
                    else if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else if(prospective_bytes[LEN_WIDTH] ||
                         (desc_rsp_byte_len!=0 &&
                         ((desc_rsp_src%BYTE_LANES)!=0 || (desc_rsp_dst%BYTE_LANES)!=0 ||
                          range_bad(desc_rsp_src,desc_rsp_byte_len) ||
                          range_bad(desc_rsp_dst,desc_rsp_byte_len)))) begin
                        rsp_status<=BAD_COMMAND; state<=REPLY;
                    end else if(desc_rsp_byte_len!=0 &&
                                overlap_bad(desc_rsp_src,desc_rsp_dst,desc_rsp_byte_len)) begin
                        rsp_status<=OVERLAP_ERROR; state<=REPLY;
                    end else begin
                        source_addr<=desc_rsp_src; destination_addr<=desc_rsp_dst;
                        remaining<=desc_rsp_byte_len; next_addr<=desc_rsp_next;
                        last_descriptor<=desc_rsp_last;
                        state<=desc_rsp_byte_len==0 ? NEXT_DESC:READ_REQ;
                    end
                end
                READ_REQ: if(mem_req_ready) state<=READ_RSP;
                READ_RSP: if(mem_rsp_valid) begin
                    if(mem_rsp_error) begin rsp_status<=MEMORY_ERROR; state<=REPLY; end
                    else if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else begin data_hold<=mem_rsp_rdata; state<=WRITE_REQ; end
                end
                WRITE_REQ: if(mem_req_ready) state<=WRITE_RSP;
                WRITE_RSP: if(mem_rsp_valid) begin
                    if(mem_rsp_error) begin rsp_status<=MEMORY_ERROR; state<=REPLY; end
                    else begin
                        rsp_bytes<=rsp_bytes+beat_bytes;
                        source_addr<=source_addr+BYTE_LANES;
                        destination_addr<=destination_addr+BYTE_LANES;
                        remaining<=remaining-beat_bytes;
                        if(stopping) begin
                            rsp_status<=ABORTED; state<=REPLY;
                            if(final_beat) rsp_descriptors<=rsp_descriptors+1;
                        end else state<=final_beat ? NEXT_DESC:READ_REQ;
                    end
                end
                NEXT_DESC: begin
                    rsp_descriptors<=rsp_descriptors+1;
                    if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else if(last_descriptor) state<=REPLY;
                    else if(fetched>=MAX_DESCRIPTORS) begin rsp_status<=CHAIN_LIMIT; state<=REPLY; end
                    else begin descriptor_addr<=next_addr; state<=DESC_REQ; end
                end
                REPLY: if(rsp_ready) state<=IDLE;
                default: begin rsp_status<=BAD_COMMAND; state<=REPLY; end
            endcase
        end
    end
endmodule
