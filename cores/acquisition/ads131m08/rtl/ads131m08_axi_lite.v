// Minimal AXI4-Lite slave bridge.
//
// Deliberately small: 32-bit data, no bursts, no exclusive access, no
// out-of-order responses.  It exposes a plain synchronous register bus so the
// IP logic does not have to know anything about AXI.
//
//   write: wr_addr / wr_data / wr_strb hold for exactly one cycle with wr_en
//   read : rd_addr is registered, rd_data is combinational, rd_en pulses on
//          the cycle the address is presented (for read side effects such as
//          popping a FIFO)
`timescale 1ns/1ps

module ads131m08_axi_lite #(
    parameter integer ADDR_W = 12
) (
    input  wire                clk,
    input  wire                rst_n,

    // ------------------------------------------------------------ AXI4-Lite
    input  wire [ADDR_W-1:0]   s_axi_awaddr,
    input  wire [2:0]          s_axi_awprot,
    input  wire                s_axi_awvalid,
    output wire                s_axi_awready,
    input  wire [31:0]         s_axi_wdata,
    input  wire [3:0]          s_axi_wstrb,
    input  wire                s_axi_wvalid,
    output wire                s_axi_wready,
    output wire [1:0]          s_axi_bresp,
    output wire                s_axi_bvalid,
    input  wire                s_axi_bready,
    input  wire [ADDR_W-1:0]   s_axi_araddr,
    input  wire [2:0]          s_axi_arprot,
    input  wire                s_axi_arvalid,
    output wire                s_axi_arready,
    output wire [31:0]         s_axi_rdata,
    output wire [1:0]          s_axi_rresp,
    output wire                s_axi_rvalid,
    input  wire                s_axi_rready,

    // -------------------------------------------------------- register bus
    output reg  [ADDR_W-1:0]   wr_addr,
    output reg  [31:0]         wr_data,
    output reg  [3:0]          wr_strb,
    output reg                 wr_en,
    output reg  [ADDR_W-1:0]   rd_addr,
    output reg                 rd_en,
    input  wire [31:0]         rd_data
);
    reg              aw_have;
    reg              w_have;
    reg [ADDR_W-1:0] awaddr_r;
    reg [31:0]       wdata_r;
    reg [3:0]        wstrb_r;
    reg              bvalid_r;

    reg              ar_have;
    reg              rd_pend;
    reg [ADDR_W-1:0] araddr_r;
    reg              rvalid_r;
    reg [31:0]       rdata_r;

    // AXI4-Lite always responds OKAY; there are no error-generating accesses.
    assign s_axi_awready = !aw_have && !bvalid_r;
    assign s_axi_wready  = !w_have  && !bvalid_r;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = bvalid_r;

    assign s_axi_arready = !ar_have && !rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = rvalid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_have  <= 1'b0;
            w_have   <= 1'b0;
            bvalid_r <= 1'b0;
            ar_have  <= 1'b0;
            rd_pend  <= 1'b0;
            rvalid_r <= 1'b0;
            wr_en    <= 1'b0;
            rd_en    <= 1'b0;
            wr_addr  <= {ADDR_W{1'b0}};
            wr_data  <= 32'd0;
            wr_strb  <= 4'd0;
            rd_addr  <= {ADDR_W{1'b0}};
        end else begin
            wr_en <= 1'b0;
            rd_en <= 1'b0;

            // ---------------------------------------------------- write path
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_r <= s_axi_awaddr;
                aw_have  <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata_r <= s_axi_wdata;
                wstrb_r <= s_axi_wstrb;
                w_have  <= 1'b1;
            end
            if (aw_have && w_have && !bvalid_r) begin
                wr_addr  <= awaddr_r;
                wr_data  <= wdata_r;
                wr_strb  <= wstrb_r;
                wr_en    <= 1'b1;
                aw_have  <= 1'b0;
                w_have   <= 1'b0;
                bvalid_r <= 1'b1;
            end
            if (bvalid_r && s_axi_bready) bvalid_r <= 1'b0;

            // ----------------------------------------------------- read path
            // rd_data is combinational in rd_addr, so it must be sampled one
            // cycle *after* rd_addr is presented; capturing both on the same
            // edge would return the previous address's data.
            if (s_axi_arvalid && s_axi_arready) begin
                araddr_r <= s_axi_araddr;
                ar_have  <= 1'b1;
            end
            if (ar_have && !rvalid_r && !rd_pend) begin
                rd_addr  <= araddr_r;
                rd_en    <= 1'b1;
                rd_pend  <= 1'b1;
                ar_have  <= 1'b0;
            end
            if (rd_pend) begin
                rdata_r  <= rd_data;
                rvalid_r <= 1'b1;
                rd_pend  <= 1'b0;
            end
            if (rvalid_r && s_axi_rready) rvalid_r <= 1'b0;
        end
    end

endmodule
