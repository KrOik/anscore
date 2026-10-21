// Synchronous byte-write RAM with one response slot. Shared clk_en protocol:
// every endpoint samples valid && ready only when clk_en is high.
// Read-first: response data on writes is the previous word and may be unknown.
// Memory contents are deliberately not reset. See ../README.md.
module cip_sync_sp_ram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 8,
    parameter DEPTH = (1 << ADDR_WIDTH)
)(
    input wire clk, input wire rst_n, input wire clk_en,
    input wire req_valid, output wire req_ready,
    input wire req_write,
    input wire [ADDR_WIDTH-1:0] req_addr,
    input wire [DATA_WIDTH-1:0] req_wdata,
    input wire [DATA_WIDTH/8-1:0] req_wstrb,
    output reg rsp_valid, input wire rsp_ready,
    output reg [DATA_WIDTH-1:0] rsp_rdata,
    output reg rsp_error
);
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    wire fire = req_valid && req_ready;
    wire in_range = req_addr < DEPTH;
    integer lane;
    assign req_ready = rst_n && (!rsp_valid || rsp_ready);

    // No asynchronous reset on the RAM or its synchronous data output.
    always @(posedge clk) begin
        if (rst_n && clk_en && fire) begin
            if (in_range) begin
                rsp_rdata <= mem[req_addr];
                for (lane = 0; lane < DATA_WIDTH/8; lane = lane + 1)
                    if (req_write && req_wstrb[lane])
                        mem[req_addr][lane*8 +: 8] <= req_wdata[lane*8 +: 8];
            end else rsp_rdata <= {DATA_WIDTH{1'b0}};
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rsp_valid <= 1'b0; rsp_error <= 1'b0; end
        else if (clk_en && req_ready) begin
            rsp_valid <= req_valid;
            if (req_valid) rsp_error <= !in_range;
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0 || ADDR_WIDTH < 1 ||
            ADDR_WIDTH > 30 || DEPTH < 1 || DEPTH > (1 << ADDR_WIDTH))
            $fatal(1, "cip_sync_sp_ram invalid parameters");
    end
`endif
endmodule
