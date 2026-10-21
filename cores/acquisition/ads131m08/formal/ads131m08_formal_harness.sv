// Lightweight ADS131M08 formal boundary harness.
//
// The full scheduler is instantiated for CS and AXI-Stream boundary checks;
// separate FIFO and AXI bridge instances keep the proof obligations small and
// make the storage and response contracts independently reusable.
`timescale 1ns/1ps

module ads131m08_formal_harness(input wire clk);
    localparam integer NDEV = 2;
    localparam integer FDEPTH = 2;

    (* anyseq *) reg rst_n;
    (* anyseq *) reg [15:0] fifo_wr_data;
    (* anyseq *) reg fifo_wr_en, fifo_rd_en, fifo_clear;
    (* anyseq *) reg [11:0] ax_awaddr, ax_araddr;
    (* anyseq *) reg [31:0] ax_wdata, ax_rd_data;
    (* anyseq *) reg [3:0] ax_wstrb;
    (* anyseq *) reg ax_awvalid, ax_wvalid, ax_bready, ax_arvalid, ax_rready;
    (* anyseq *) reg ip_adc_dout;
    (* anyseq *) reg [NDEV-1:0] ip_adc_drdy_n;
    (* anyseq *) reg ip_m_axis_tready;

    reg reset_seen;
    initial begin
        assume(!rst_n);
        past_valid = 1'b0;
        reset_seen = 1'b0;
    end

    // --------------------------------------------------------------- FIFO
    wire [15:0] fifo_rd_data;
    wire fifo_full, fifo_empty, fifo_overflow;
    wire [15:0] fifo_level;
    wire [31:0] fifo_drop_count;

    ads131m08_sample_fifo #(.WIDTH(16), .DEPTH(FDEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(fifo_wr_en), .wr_data(fifo_wr_data),
        .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
        .full(fifo_full), .empty(fifo_empty), .level(fifo_level),
        .drop_count(fifo_drop_count), .overflow(fifo_overflow),
        .clear(fifo_clear)
    );

    // ------------------------------------------------------------ AXI bridge
    wire [11:0] ax_wr_addr, ax_rd_addr;
    wire [31:0] ax_wr_data;
    wire [3:0] ax_wr_strb;
    wire ax_wr_en, ax_rd_en;
    wire ax_awready, ax_wready, ax_bvalid, ax_arready, ax_rvalid;
    wire [1:0] ax_bresp, ax_rresp;
    wire [31:0] ax_rdata;

    ads131m08_axi_lite #(.ADDR_W(12)) u_axi (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(ax_awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(ax_awvalid), .s_axi_awready(ax_awready),
        .s_axi_wdata(ax_wdata), .s_axi_wstrb(ax_wstrb),
        .s_axi_wvalid(ax_wvalid), .s_axi_wready(ax_wready),
        .s_axi_bresp(ax_bresp), .s_axi_bvalid(ax_bvalid),
        .s_axi_bready(ax_bready),
        .s_axi_araddr(ax_araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(ax_arvalid), .s_axi_arready(ax_arready),
        .s_axi_rdata(ax_rdata), .s_axi_rresp(ax_rresp),
        .s_axi_rvalid(ax_rvalid), .s_axi_rready(ax_rready),
        .wr_addr(ax_wr_addr), .wr_data(ax_wr_data), .wr_strb(ax_wr_strb),
        .wr_en(ax_wr_en), .rd_addr(ax_rd_addr), .rd_en(ax_rd_en),
        .rd_data(ax_rd_data)
    );

    // --------------------------------------------------------- full IP edges
    wire ip_adc_sclk, ip_adc_din;
    wire [NDEV-1:0] ip_adc_cs_n, ip_adc_sync_n;
    wire [31:0] ip_s_axi_rdata;
    wire [1:0] ip_s_axi_bresp, ip_s_axi_rresp;
    wire ip_s_axi_awready, ip_s_axi_wready, ip_s_axi_bvalid;
    wire ip_s_axi_arready, ip_s_axi_rvalid;
    wire [255:0] ip_m_axis_tdata;
    wire [15:0] ip_m_axis_tuser;
    wire ip_m_axis_tvalid, ip_m_axis_tlast, ip_irq;

    ads131m08_multi_ip #(
        .ADC_COUNT(NDEV), .CLK_HZ(1_000_000), .SCK_DIV(0),
        .SYNC_LOW_US(1), .SETTLE_US(1), .DRDY_TO_US(4),
        .UNLOCK_DLY_US(1), .WAKEUP_DLY_US(1), .FIFO_DEPTH(FDEPTH)
    ) u_ip (
        .clk(clk), .rst_n(rst_n),
        .adc_sclk(ip_adc_sclk), .adc_din(ip_adc_din), .adc_dout(ip_adc_dout),
        .adc_cs_n(ip_adc_cs_n), .adc_sync_n(ip_adc_sync_n),
        .adc_drdy_n(ip_adc_drdy_n),
        .s_axi_awaddr(ax_awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(ax_awvalid), .s_axi_awready(ip_s_axi_awready),
        .s_axi_wdata(ax_wdata), .s_axi_wstrb(ax_wstrb),
        .s_axi_wvalid(ax_wvalid), .s_axi_wready(ip_s_axi_wready),
        .s_axi_bresp(ip_s_axi_bresp), .s_axi_bvalid(ip_s_axi_bvalid),
        .s_axi_bready(ax_bready),
        .s_axi_araddr(ax_araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(ax_arvalid), .s_axi_arready(ip_s_axi_arready),
        .s_axi_rdata(ip_s_axi_rdata), .s_axi_rresp(ip_s_axi_rresp),
        .s_axi_rvalid(ip_s_axi_rvalid), .s_axi_rready(ax_rready),
        .m_axis_tdata(ip_m_axis_tdata), .m_axis_tuser(ip_m_axis_tuser),
        .m_axis_tvalid(ip_m_axis_tvalid), .m_axis_tlast(ip_m_axis_tlast),
        .m_axis_tready(ip_m_axis_tready), .irq(ip_irq)
    );

    integer cs_low_count;
    integer i;
    reg past_valid;
    always @(*) begin
        cs_low_count = 0;
        for (i = 0; i < NDEV; i = i + 1)
            if (!ip_adc_cs_n[i]) cs_low_count = cs_low_count + 1;
    end

    always @(posedge clk) begin
        if (!rst_n) past_valid <= 1'b0;
        else past_valid <= 1'b1;
        if (!rst_n) reset_seen <= 1'b1;
        else assume(reset_seen);

        // FIFO safety and sticky loss accounting.
        if (rst_n) begin
            assert(fifo_level <= FDEPTH);
            assert(fifo_full == (fifo_level == FDEPTH));
            assert(fifo_empty == (fifo_level == 0));
        end
        if (past_valid) begin
            if ($past(rst_n && !fifo_clear && fifo_overflow) && rst_n && !fifo_clear)
                assert(fifo_overflow);
            if ($past(rst_n && !fifo_clear) && rst_n && !fifo_clear)
                assert(fifo_drop_count >= $past(fifo_drop_count));
            if ($past(rst_n && !fifo_clear && fifo_full && fifo_wr_en) && rst_n && !fifo_clear)
                assert(fifo_drop_count == ($past(fifo_drop_count) + 1));
            if ($past(rst_n && !fifo_clear && fifo_full && fifo_wr_en) && rst_n)
                assert(fifo_level <= $past(fifo_level));
        end

        // AXI response channels must remain asserted and stable while stalled.
        if (past_valid) begin
            if ($past(rst_n && ax_bvalid && !ax_bready) && rst_n) begin
                assert(ax_bvalid);
                assert(ax_bresp == $past(ax_bresp));
            end
            if ($past(rst_n && ax_rvalid && !ax_rready) && rst_n) begin
                assert(ax_rvalid);
                assert(ax_rdata == $past(ax_rdata));
                assert(ax_rresp == $past(ax_rresp));
            end
            assert(!(ax_wr_en && $past(ax_wr_en)));
        end

        // One active-low CS at most, one complete frame per stream beat.
        assert(cs_low_count <= 1);
        if (ip_m_axis_tvalid) assert(ip_m_axis_tlast);
        if (past_valid && rst_n && $past(rst_n && ip_m_axis_tvalid && !ip_m_axis_tready)) begin
            assert(ip_m_axis_tvalid);
            assert(ip_m_axis_tdata == $past(ip_m_axis_tdata));
            assert(ip_m_axis_tuser == $past(ip_m_axis_tuser));
        end
    end
endmodule
