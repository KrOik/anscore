// Same-clock true dual-port synchronous RAM, with independent response slots.
// Simultaneous same-word accesses involving a write: A wins, B returns error 2.
// Same-word dual reads are legal. Write responses return zero, not old data.
// Read requests never coincide with a write to that word on either port.
module cip_sync_tdp_ram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 8,
    parameter DEPTH = (1 << ADDR_WIDTH)
)(
    input wire clk, input wire rst_n, input wire clk_en,
    input wire a_req_valid, output wire a_req_ready, input wire a_req_write,
    input wire [ADDR_WIDTH-1:0] a_req_addr,
    input wire [DATA_WIDTH-1:0] a_req_wdata,
    input wire [DATA_WIDTH/8-1:0] a_req_wstrb,
    output reg a_rsp_valid, input wire a_rsp_ready,
    output reg [DATA_WIDTH-1:0] a_rsp_rdata, output reg [1:0] a_rsp_error,
    input wire b_req_valid, output wire b_req_ready, input wire b_req_write,
    input wire [ADDR_WIDTH-1:0] b_req_addr,
    input wire [DATA_WIDTH-1:0] b_req_wdata,
    input wire [DATA_WIDTH/8-1:0] b_req_wstrb,
    output reg b_rsp_valid, input wire b_rsp_ready,
    output reg [DATA_WIDTH-1:0] b_rsp_rdata, output reg [1:0] b_rsp_error
);
    // Safe don't-care mapping: collision arbitration and !req_write read enables
    // exclude all visible read/write collisions, including within one port.
    (* ram_style = "block", no_rw_check *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    wire a_fire = a_req_valid && a_req_ready;
    wire b_fire = b_req_valid && b_req_ready;
    wire a_range = a_req_addr < DEPTH;
    wire b_range = b_req_addr < DEPTH;
    wire conflict = a_fire && b_fire && a_range && b_range &&
                    a_req_addr == b_req_addr && (a_req_write || b_req_write);
    integer la, lb;
    assign a_req_ready = rst_n && (!a_rsp_valid || a_rsp_ready);
    assign b_req_ready = rst_n && (!b_rsp_valid || b_rsp_ready);
    always @(posedge clk) begin
        if (rst_n && clk_en && a_fire) begin
            if (a_range) begin
                if (!a_req_write) a_rsp_rdata <= mem[a_req_addr];
                else a_rsp_rdata <= {DATA_WIDTH{1'b0}};
                for (la = 0; la < DATA_WIDTH/8; la = la + 1)
                    if (a_req_write && a_req_wstrb[la])
                        mem[a_req_addr][la*8 +: 8] <= a_req_wdata[la*8 +: 8];
            end else a_rsp_rdata <= {DATA_WIDTH{1'b0}};
        end
    end
    always @(posedge clk) begin
        if (rst_n && clk_en && b_fire) begin
            if (b_range && !conflict) begin
                if (!b_req_write) b_rsp_rdata <= mem[b_req_addr];
                else b_rsp_rdata <= {DATA_WIDTH{1'b0}};
                for (lb = 0; lb < DATA_WIDTH/8; lb = lb + 1)
                    if (b_req_write && b_req_wstrb[lb])
                        mem[b_req_addr][lb*8 +: 8] <= b_req_wdata[lb*8 +: 8];
            end else b_rsp_rdata <= {DATA_WIDTH{1'b0}};
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_rsp_valid <= 1'b0; b_rsp_valid <= 1'b0;
            a_rsp_error <= 2'd0; b_rsp_error <= 2'd0;
        end else if (clk_en) begin
            if (a_req_ready) begin
                a_rsp_valid <= a_req_valid;
                if (a_req_valid) a_rsp_error <= a_range ? 2'd0 : 2'd1;
            end
            if (b_req_ready) begin
                b_rsp_valid <= b_req_valid;
                if (b_req_valid)
                    b_rsp_error <= !b_range ? 2'd1 : (conflict ? 2'd2 : 2'd0);
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0 || ADDR_WIDTH < 1 ||
            ADDR_WIDTH > 30 || DEPTH < 1 || DEPTH > (1 << ADDR_WIDTH))
            $fatal(1, "cip_sync_tdp_ram invalid parameters");
    end
`endif
endmodule
