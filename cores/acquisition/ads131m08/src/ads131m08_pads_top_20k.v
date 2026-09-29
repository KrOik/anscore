// Tang Primer 20K single-device bring-up wrapper.
//
// The standalone IP remains vector-parameterised, but a scalar pad boundary is
// used here so GW2A constraint names are stable after synthesis. This wrapper is
// intentionally separate from the 25K multi-device template.
`timescale 1ns/1ps

module ads131m08_pads_top_20k #(
    parameter integer CLK_HZ  = 27_000_000,
    parameter integer SCK_DIV = 1
) (
    input  wire clk,
    input  wire rst_n,
    output wire adc_cs_n,
    output wire adc_sync_n,
    input  wire adc_drdy_n,
    output wire adc_sclk,
    output wire adc_din,
    input  wire adc_dout,
    output wire led
);
    wire [255:0] m_axis_tdata;
    wire [15:0]  m_axis_tuser;
    wire         m_axis_tvalid;
    wire         irq_unused;
    wire [31:0]  rd_data_unused;

    ads131m08_multi_ip #(
        .ADC_COUNT (1),
        .CLK_HZ    (CLK_HZ),
        .SCK_DIV   (SCK_DIV),
        .FIFO_DEPTH(64),
        .EXPECT_ID_DEFAULT(16'h0801)
    ) u_ip (
        .clk(clk), .rst_n(rst_n),
        .adc_sclk(adc_sclk), .adc_din(adc_din), .adc_dout(adc_dout),
        .adc_cs_n({adc_cs_n}), .adc_sync_n({adc_sync_n}),
        .adc_drdy_n({adc_drdy_n}),
        .s_axi_awaddr(12'd0), .s_axi_awprot(3'b000), .s_axi_awvalid(1'b0),
        .s_axi_awready(), .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0),
        .s_axi_wvalid(1'b0), .s_axi_wready(), .s_axi_bresp(),
        .s_axi_bvalid(), .s_axi_bready(1'b1), .s_axi_araddr(12'd0),
        .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(rd_data_unused), .s_axi_rresp(), .s_axi_rvalid(),
        .s_axi_rready(1'b1), .m_axis_tdata(m_axis_tdata),
        .m_axis_tuser(m_axis_tuser), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(), .m_axis_tready(1'b0), .irq(irq_unused)
    );

    // The LED is a real observable signal: it indicates a pending sample.
    assign led = m_axis_tvalid;
endmodule
