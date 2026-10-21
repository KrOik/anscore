// Pad-level synthesis and place-and-route vehicle for the ADS131M08 IP.
//
// ads131m08_multi_ip itself is meant to be instantiated inside a design, so its
// 256-bit AXI4-Stream port and full AXI4-Lite port would be nonsense as
// top-level pins.  This wrapper exposes only the pins a board actually needs --
// clock, reset, a status LED and the ADC pads -- so the design can be pushed
// through nextpnr and gowin_pack, and so the SPI pins get real package
// locations in a .cst file.
`timescale 1ns/1ps

module ads131m08_pads_top #(
    parameter integer ADC_COUNT = 16,
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer SCK_DIV   = 1
) (
    input  wire         clk,
    input  wire         rst_n,

    output wire [ADC_COUNT-1:0] adc_cs_n,
    output wire [ADC_COUNT-1:0] adc_sync_n,
    input  wire [ADC_COUNT-1:0] adc_drdy_n,
    output wire         adc_sclk,
    output wire         adc_din,
    input  wire         adc_dout,

    output wire         led
);
    // AXI4-Lite is held in a permanently idle state: no writes, no reads.
    wire [31:0] rd_data_unused;
    wire        irq, m_tvalid, dummy_ready;
    wire [255:0] m_tdata;
    wire [15:0]  m_tuser;

    ads131m08_multi_ip #(
        .ADC_COUNT    (ADC_COUNT),
        .CLK_HZ       (CLK_HZ),
        .SCK_DIV      (SCK_DIV),
        .FIFO_DEPTH   (64),
        .EXPECT_ID_DEFAULT (16'h0801)
    ) u_ip (
        .clk (clk), .rst_n (rst_n),
        .adc_sclk (adc_sclk), .adc_din (adc_din), .adc_dout (adc_dout),
        .adc_cs_n (adc_cs_n), .adc_sync_n (adc_sync_n), .adc_drdy_n (adc_drdy_n),

        .s_axi_awaddr (12'd0), .s_axi_awprot (3'b000), .s_axi_awvalid (1'b0),
        .s_axi_awready (), .s_axi_wdata (32'd0), .s_axi_wstrb (4'd0),
        .s_axi_wvalid (1'b0), .s_axi_wready (), .s_axi_bresp (), .s_axi_bvalid (),
        .s_axi_bready (1'b1),
        .s_axi_araddr (12'd0), .s_axi_arprot (3'b000), .s_axi_arvalid (1'b0),
        .s_axi_arready (), .s_axi_rdata (rd_data_unused), .s_axi_rresp (),
        .s_axi_rvalid (), .s_axi_rready (1'b1),

        .m_axis_tdata (m_tdata), .m_axis_tuser (m_tuser),
        .m_axis_tvalid (m_tvalid), .m_axis_tlast (), .m_axis_tready (dummy_ready),
        .irq (irq)
    );

    // The AXI pins are intentionally idle in this pad-only vehicle. The LED is
    // therefore a narrow observable contract: it lights for a queued sample or
    // a pending enabled interrupt. It is not an initialization-health claim.
    assign dummy_ready = 1'b0;
    assign led         = m_tvalid | irq;

endmodule
