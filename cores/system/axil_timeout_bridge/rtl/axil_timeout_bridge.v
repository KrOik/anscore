// SPDX-License-Identifier: Apache-2.0
// Bounded single-outstanding AXI-Lite service with sticky timeout quarantine.
`default_nettype none
module axil_timeout_bridge #(
    parameter ADDR_W = 16,
    parameter DATA_W = 32,
    parameter TIMEOUT_CYCLES = 16
) (
    input wire clk, input wire rst_n,
    input wire [ADDR_W-1:0] s_awaddr, input wire [2:0] s_awprot,
    input wire s_awvalid, output wire s_awready,
    input wire [DATA_W-1:0] s_wdata, input wire [DATA_W/8-1:0] s_wstrb,
    input wire s_wvalid, output wire s_wready,
    output reg [1:0] s_bresp, output reg s_bvalid, input wire s_bready,
    input wire [ADDR_W-1:0] s_araddr, input wire [2:0] s_arprot,
    input wire s_arvalid, output wire s_arready,
    output reg [DATA_W-1:0] s_rdata, output reg [1:0] s_rresp,
    output reg s_rvalid, input wire s_rready,
    output reg [ADDR_W-1:0] m_awaddr, output reg [2:0] m_awprot,
    output wire m_awvalid, input wire m_awready,
    output reg [DATA_W-1:0] m_wdata, output reg [DATA_W/8-1:0] m_wstrb,
    output wire m_wvalid, input wire m_wready,
    input wire [1:0] m_bresp, input wire m_bvalid, output wire m_bready,
    output reg [ADDR_W-1:0] m_araddr, output reg [2:0] m_arprot,
    output wire m_arvalid, input wire m_arready,
    input wire [DATA_W-1:0] m_rdata, input wire [1:0] m_rresp,
    input wire m_rvalid, output wire m_rready,
    output reg write_fault, output reg read_fault
);
    localparam TIMER_W = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
    generate if (ADDR_W < 1 || ADDR_W > 64 || DATA_W < 8 || DATA_W > 64 ||
                 DATA_W % 8 != 0 || TIMEOUT_CYCLES < 1 || TIMEOUT_CYCLES > 65536)
        begin : invalid_parameters
            axil_timeout_bridge_invalid_parameters__see_README invalid();
        end
    endgenerate

    reg aw_have, w_have;
    reg [ADDR_W-1:0] aw_buf;
    reg [2:0] awprot_buf;
    reg [DATA_W-1:0] w_buf;
    reg [DATA_W/8-1:0] wstrb_buf;
    reg wr_busy, rd_busy, wr_down, rd_down;
    reg aw_pending, w_pending, ar_pending;
    reg [TIMER_W-1:0] wr_age, rd_age;

    assign s_awready = rst_n && !aw_have && !wr_busy && !s_bvalid;
    assign s_wready = rst_n && !w_have && !wr_busy && !s_bvalid;
    assign s_arready = rst_n && !rd_busy && !s_rvalid;
    // Original requests retain VALID and payload through timeout.  Separate
    // upstream buffers allow local errors while the old request still drains.
    assign m_awvalid = rst_n && wr_down && aw_pending;
    assign m_wvalid = rst_n && wr_down && w_pending;
    assign m_bready = rst_n && wr_down && !aw_pending && !w_pending;
    assign m_arvalid = rst_n && rd_down && ar_pending;
    assign m_rready = rst_n && rd_down && !ar_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_have <= 0; w_have <= 0; aw_buf <= 0; awprot_buf <= 0;
            w_buf <= 0; wstrb_buf <= 0;
            wr_busy <= 0; rd_busy <= 0; wr_down <= 0; rd_down <= 0;
            aw_pending <= 0; w_pending <= 0; ar_pending <= 0;
            wr_age <= 0; rd_age <= 0; write_fault <= 0; read_fault <= 0;
            s_bresp <= 0; s_bvalid <= 0; s_rdata <= 0; s_rresp <= 0; s_rvalid <= 0;
            m_awaddr <= 0; m_awprot <= 0; m_wdata <= 0; m_wstrb <= 0;
            m_araddr <= 0; m_arprot <= 0;
        end else begin
            if (s_bvalid && s_bready) s_bvalid <= 0;
            if (s_rvalid && s_rready) s_rvalid <= 0;
            if (s_awvalid && s_awready) begin
                aw_have <= 1; aw_buf <= s_awaddr; awprot_buf <= s_awprot;
            end
            if (s_wvalid && s_wready) begin
                w_have <= 1; w_buf <= s_wdata; wstrb_buf <= s_wstrb;
            end
            if (aw_have && w_have && !wr_busy && !s_bvalid) begin
                aw_have <= 0; w_have <= 0;
                if (write_fault) begin
                    s_bvalid <= 1; s_bresp <= 2'b10;
                end else begin
                    m_awaddr <= aw_buf; m_awprot <= awprot_buf;
                    m_wdata <= w_buf; m_wstrb <= wstrb_buf;
                    aw_pending <= 1; w_pending <= 1; wr_down <= 1;
                    wr_busy <= 1; wr_age <= 0;
                end
            end
            if (s_arvalid && s_arready) begin
                if (read_fault) begin
                    s_rvalid <= 1; s_rresp <= 2'b10; s_rdata <= 0;
                end else begin
                    m_araddr <= s_araddr; m_arprot <= s_arprot;
                    ar_pending <= 1; rd_down <= 1; rd_busy <= 1; rd_age <= 0;
                end
            end
            if (m_awvalid && m_awready) aw_pending <= 0;
            if (m_wvalid && m_wready) w_pending <= 0;
            if (m_arvalid && m_arready) ar_pending <= 0;

            if (m_bvalid && m_bready) begin
                wr_down <= 0;
                if (wr_busy) begin
                    wr_busy <= 0; s_bvalid <= 1; s_bresp <= m_bresp;
                end
            end else if (wr_busy) begin
                if (wr_age == TIMEOUT_CYCLES-1) begin
                    wr_busy <= 0; write_fault <= 1;
                    s_bvalid <= 1; s_bresp <= 2'b10;
                end else wr_age <= wr_age + 1'b1;
            end
            if (m_rvalid && m_rready) begin
                rd_down <= 0;
                if (rd_busy) begin
                    rd_busy <= 0; s_rvalid <= 1;
                    s_rresp <= m_rresp; s_rdata <= m_rdata;
                end
            end else if (rd_busy) begin
                if (rd_age == TIMEOUT_CYCLES-1) begin
                    rd_busy <= 0; read_fault <= 1;
                    s_rvalid <= 1; s_rresp <= 2'b10; s_rdata <= 0;
                end else rd_age <= rd_age + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
