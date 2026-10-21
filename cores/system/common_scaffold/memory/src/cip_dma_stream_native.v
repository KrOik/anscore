// Native single-outstanding DMA. DIRECTION=0: stream->memory, 1: memory->stream.
// Addresses and lengths are bytes. Every handshake requires clk_en.
// abort drains an already visible memory request/output beat before completing.
module cip_dma_stream_native #(
    parameter DATA_WIDTH=32, ADDR_WIDTH=32, LEN_WIDTH=32, TAG_WIDTH=16,
    parameter DIRECTION=0
)(
    input wire clk, rst_n, clk_en, abort,
    input wire cmd_valid, output wire cmd_ready,
    input wire [ADDR_WIDTH-1:0] cmd_addr,
    input wire [LEN_WIDTH-1:0] cmd_byte_len,
    input wire [TAG_WIDTH-1:0] cmd_tag,
    output wire rsp_valid, input wire rsp_ready,
    output wire rsp_error, output reg [7:0] rsp_status,
    output reg [TAG_WIDTH-1:0] rsp_tag,
    output reg [LEN_WIDTH-1:0] rsp_bytes,
    output wire busy, done, irq,
    input wire s_valid, output wire s_ready,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire [DATA_WIDTH/8-1:0] s_keep, input wire s_last,
    output wire m_valid, input wire m_ready,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire [DATA_WIDTH/8-1:0] m_keep, output wire m_last,
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
    localparam IDLE=0, INPUT_BEAT=1, REQUEST=2, MEMORY_REPLY=3, OUTPUT_BEAT=4, REPLY=5;
    localparam [7:0] OK=0, BAD_COMMAND=2, BAD_STREAM=3, MEMORY_ERROR=4, ABORTED=5;
    reg [2:0] state;
    reg [ADDR_WIDTH-1:0] address;
    reg [LEN_WIDTH-1:0] remaining;
    reg [DATA_WIDTH-1:0] data_hold;
    reg abort_pending;
    wire stopping=abort_pending || abort;
    wire [LEN_WIDTH-1:0] beat_bytes=(remaining >= BYTE_LANES) ? BYTE_LANES : remaining;
    wire final_beat=(remaining <= BYTE_LANES);
    wire [BYTE_LANES-1:0] keep_now;
    genvar g;
    generate for(g=0;g<BYTE_LANES;g=g+1) begin: lanes
        assign keep_now[g]=(g < remaining);
        assign m_data[g*8+:8]=keep_now[g] ? data_hold[g*8+:8] : 8'b0;
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
    assign cmd_ready=rst_n && state==IDLE;
    assign rsp_valid=rst_n && state==REPLY;
    assign rsp_error=(rsp_status!=OK);
    assign busy=rst_n && state!=IDLE;
    assign done=rsp_valid && rsp_ready && clk_en;
    assign irq=done;
    assign s_ready=rst_n && state==INPUT_BEAT && !stopping && DIRECTION==0;
    assign m_valid=rst_n && state==OUTPUT_BEAT && DIRECTION==1;
    assign m_keep=keep_now;
    assign m_last=final_beat;
    assign mem_req_valid=rst_n && state==REQUEST;
    assign mem_req_write=(DIRECTION==0);
    assign mem_req_addr=address;
    assign mem_req_wdata=data_hold;
    assign mem_req_wstrb=DIRECTION==0 ? keep_now : {BYTE_LANES{1'b0}};
    assign mem_rsp_ready=rst_n && state==MEMORY_REPLY;

    initial begin
        if(DATA_WIDTH<8 || DATA_WIDTH%8!=0 || ADDR_WIDTH<1 || LEN_WIDTH<1 || TAG_WIDTH<1 ||
           (DIRECTION!=0 && DIRECTION!=1)) $fatal(1,"invalid native DMA parameters");
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; address<=0; remaining<=0; data_hold<=0;
            abort_pending<=0; rsp_status<=OK; rsp_tag<=0; rsp_bytes<=0;
        end else if(clk_en) begin
            if(abort && state!=IDLE && state!=REPLY) abort_pending<=1;
            case(state)
                IDLE: if(cmd_valid) begin
                    address<=cmd_addr; remaining<=cmd_byte_len; rsp_tag<=cmd_tag;
                    rsp_bytes<=0; rsp_status<=OK; abort_pending<=0;
                    if(abort) begin rsp_status<=ABORTED; state<=REPLY; end
                    else if(cmd_byte_len==0) state<=REPLY;
                    else if((cmd_addr%BYTE_LANES)!=0 || range_bad(cmd_addr,cmd_byte_len)) begin
                        rsp_status<=BAD_COMMAND; state<=REPLY;
                    end else state<=DIRECTION==0 ? INPUT_BEAT:REQUEST;
                end
                INPUT_BEAT: begin
                    if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else if(s_valid) begin
                        if(s_keep!=keep_now || s_last!=final_beat) begin
                            rsp_status<=BAD_STREAM; state<=REPLY;
                        end else begin data_hold<=s_data; state<=REQUEST; end
                    end
                end
                // Once asserted, request valid/payload stays fixed until accepted,
                // including during abort and enabled-clock pauses.
                REQUEST: if(mem_req_ready) state<=MEMORY_REPLY;
                MEMORY_REPLY: if(mem_rsp_valid) begin
                    if(mem_rsp_error) begin rsp_status<=MEMORY_ERROR; state<=REPLY; end
                    else if(DIRECTION==0) begin
                        rsp_bytes<=rsp_bytes+beat_bytes;
                        remaining<=remaining-beat_bytes; address<=address+BYTE_LANES;
                        if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                        else state<=final_beat ? REPLY:INPUT_BEAT;
                    end else if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else begin data_hold<=mem_rsp_rdata; state<=OUTPUT_BEAT; end
                end
                // An already visible output beat is delivered even if aborted.
                OUTPUT_BEAT: if(m_ready) begin
                    rsp_bytes<=rsp_bytes+beat_bytes;
                    remaining<=remaining-beat_bytes; address<=address+BYTE_LANES;
                    if(stopping) begin rsp_status<=ABORTED; state<=REPLY; end
                    else state<=final_beat ? REPLY:REQUEST;
                end
                REPLY: if(rsp_ready) state<=IDLE;
                default: begin rsp_status<=BAD_COMMAND; state<=REPLY; end
            endcase
        end
    end
endmodule
