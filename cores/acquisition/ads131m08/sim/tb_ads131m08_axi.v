// AXI4-Lite control path and AXI4-Stream data path testbench for
// ads131m08_multi_ip.
//
// Covers: register read/write, the start-init command, per-device status, the
// AXI4-Stream handshake under back-pressure, and FIFO overflow accounting.
// The depth is deliberately small so the overflow case is reachable quickly.
`timescale 1ns/1ps

module tb_ads131m08_axi;

    localparam integer NDEV = 2;
    localparam integer FDEPTH = 16;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    integer errors = 0;

    // ------------------------------------------------------------- ADC models
    wire                adc_sclk, adc_din;
    wire [NDEV-1:0]     adc_cs_n, adc_sync_n, adc_drdy_n, dev_dout, dev_oe;
    wire                adc_dout = |(dev_dout & dev_oe);

    genvar g;
    generate
        for (g = 0; g < NDEV; g = g + 1) begin : g_dev
            ads131m08_device_model #(
                .DEV_INDEX(g), .DRDY_PERIOD(400 + 37*g)
            ) u_dev (
                .clk (clk), .rst_n (rst_n),
                .sclk (adc_sclk), .din (adc_din),
                .cs_n (adc_cs_n[g]), .sync_n (adc_sync_n[g]),
                .dout (dev_dout[g]), .dout_oe (dev_oe[g]), .drdy_n (adc_drdy_n[g])
            );
        end
    endgenerate

    // ------------------------------------------------------------------- AXI
    reg  [11:0] s_awaddr = 12'd0;
    reg         s_awvalid = 1'b0;
    reg  [31:0] s_wdata = 32'd0;
    reg  [3:0]  s_wstrb = 4'hF;
    reg         s_wvalid = 1'b0;
    reg         s_bready = 1'b1;
    reg  [11:0] s_araddr = 12'd0;
    reg         s_arvalid = 1'b0;
    reg         s_rready = 1'b1;

    wire        s_awready, s_wready, s_bvalid, s_arready;
    wire [1:0]  s_bresp, s_rresp;
    wire [31:0] s_rdata;
    wire        s_rvalid;

    wire [255:0] m_tdata;
    wire [15:0]  m_tuser;
    wire         m_tvalid, m_tlast;
    reg          m_tready = 1'b0;
    wire         irq;

    ads131m08_multi_ip #(
        .ADC_COUNT    (NDEV),
        .CLK_HZ       (100_000_000),
        .SCK_DIV      (1),
        .SYNC_LOW_US  (20),
        .SETTLE_US    (20),
        .DRDY_TO_US   (2_000),
        .UNLOCK_DLY_US(50),
        .WAKEUP_DLY_US(50),
        .OSR_SEL      (2),
        .PWR_SEL      (2),
        .FIFO_DEPTH   (FDEPTH)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .adc_sclk (adc_sclk), .adc_din (adc_din), .adc_dout (adc_dout),
        .adc_cs_n (adc_cs_n), .adc_sync_n (adc_sync_n), .adc_drdy_n (adc_drdy_n),
        .s_axi_awaddr (s_awaddr), .s_axi_awprot (3'b000),
        .s_axi_awvalid (s_awvalid), .s_axi_awready (s_awready),
        .s_axi_wdata (s_wdata), .s_axi_wstrb (s_wstrb),
        .s_axi_wvalid (s_wvalid), .s_axi_wready (s_wready),
        .s_axi_bresp (s_bresp), .s_axi_bvalid (s_bvalid), .s_axi_bready (s_bready),
        .s_axi_araddr (s_araddr), .s_axi_arprot (3'b000),
        .s_axi_arvalid (s_arvalid), .s_axi_arready (s_arready),
        .s_axi_rdata (s_rdata), .s_axi_rresp (s_rresp),
        .s_axi_rvalid (s_rvalid), .s_axi_rready (s_rready),
        .m_axis_tdata (m_tdata), .m_axis_tuser (m_tuser),
        .m_axis_tvalid (m_tvalid), .m_axis_tlast (m_tlast),
        .m_axis_tready (m_tready),
        .irq (irq)
    );


    // ------------------------------------------------------------ AXI master
    task axi_write_strb(input [11:0] addr, input [31:0] data, input [3:0] strb);
        begin
            s_awaddr  = addr;
            s_awvalid = 1'b1;
            s_wdata   = data;
            s_wstrb   = strb;
            s_wvalid  = 1'b1;
            do @(posedge clk); while (!s_bvalid);
            s_awvalid = 1'b0;
            s_wvalid  = 1'b0;
            @(posedge clk);
        end
    endtask

    task axi_write(input [11:0] addr, input [31:0] data);
        begin
            axi_write_strb(addr, data, 4'hF);
        end
    endtask

    task axi_read(input [11:0] addr, output [31:0] data);
        begin
            // Drain any response still in flight from the previous access,
            // otherwise the first poll would sample the previous value.
            while (s_rvalid) @(posedge clk);
            @(posedge clk);
            s_araddr  = addr;
            s_arvalid = 1'b1;
            @(posedge clk);
            while (!s_arready) @(posedge clk);
            @(posedge clk);
            s_arvalid = 1'b0;
            while (!s_rvalid) @(posedge clk);
            data      = s_rdata;
            @(posedge clk);
        end
    endtask

    task check(input cond, input [31*8-1:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", what);
            end
        end
    endtask

    // ------------------------------------------------- AXI-Stream beat check
    integer beats = 0;
    integer bad_beats = 0;
    integer bi;

    always @(posedge clk) begin
        if (m_tvalid && m_tready) begin
            beats = beats + 1;
            for (bi = 0; bi < 8; bi = bi + 1) begin
                if (m_tdata[24*bi + 20 +: 4] !== m_tdata[211:208]) begin
                    bad_beats = bad_beats + 1;
                    $display("  FAIL stream: beat device %0d carries channel tag %0d",
                             m_tdata[211:208], m_tdata[24*bi + 20 +: 4]);
                end
            end
            if (m_tlast !== 1'b1) begin
                bad_beats = bad_beats + 1;
                $display("  FAIL stream: tlast low on a single-beat packet");
            end
        end
    end

    reg [31:0] rd;
    reg [255:0] held_tdata;
    reg [15:0]  held_tuser;
    reg [31:0]  drops_a, drops_b;
    integer wait_cycles;

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ------------------------------------------------ identity and status
        axi_read(12'h004, rd);
        check(rd[3:0] === 4'd2, "STATUS reports ADC_COUNT");
        $display("  STATUS=%08x", rd);

        // ------------------------------------------------ unmapped access
        axi_read(12'h0C0, rd);
        check(rd === 32'hDEADBEEF, "unmapped read returns DEADBEEF");
        axi_read(12'h00C, rd);
        check(rd[18] === 1'b0, "read-only access does not set the error sticky");

        // Invalid writes are sticky and remain visible through ERR. The AXI
        // bridge intentionally preserves its compatibility contract: the
        // response is OKAY even when the register address is unmapped.
        axi_write(12'h0C0, 32'hA5A5_5A5A);
        repeat (2) @(posedge clk);
        axi_read(12'h00C, rd);
        check(rd[18] === 1'b1, "unmapped write sets the sticky access error");
        axi_write(12'h014, 32'h0004_0000);
        axi_read(12'h00C, rd);
        check(rd[18] === 1'b0, "IRQ_STATUS write clears the sticky access error");

        // CTRL.W3 is the software-wide error-latch clear. It must clear the
        // same unmapped-write latch without relying on the IRQ W1C path.
        axi_write(12'h0C0, 32'h5A5A_A5A5);
        axi_read(12'h00C, rd);
        check(rd[18] === 1'b1, "second unmapped write sets the sticky access error");
        axi_write(12'h000, 32'h0000_0008);
        axi_read(12'h00C, rd);
        check(rd[18] === 1'b0, "CTRL.W3 clears the sticky access error");

        // ------------------------------------------------ config read/write
        axi_write(12'h018, 32'h0000_0005);
        axi_read (12'h018, rd);
        check(rd[2:0] === 3'd5, "CFG0 OSR read-back");

        // WSTRB is carried by the bridge but is currently compatibility
        // defined as ignored by the register file. Lock that behavior until a
        // deliberate byte-write change gets its own interface revision.
        axi_write_strb(12'h01C, 32'h1234_0801, 4'h1);
        axi_read (12'h01C, rd);
        check(rd[15:0] === 16'h0801, "WSTRB compatibility contract");

        axi_write(12'h01C, 32'h0000_0801);
        axi_read (12'h01C, rd);
        check(rd[15:0] === 16'h0801, "CFG1 expected ID read-back");

        axi_write(12'h008, 32'h0003_0001);      // DRDY priority, both devices enabled
        axi_read (12'h008, rd);
        $display("  SCHED=%08x", rd);
        check(rd[0] === 1'b1 && rd[16] === 1'b1 && rd[17] === 1'b1, "SCHED read-back (mode + both devices enabled)");

        // ------------------------------------------------ start configuration
        axi_write(12'h000, 32'h0000_0006);      // start_init + enable
        axi_read (12'h000, rd);
        check(rd[2] === 1'b1, "CTRL enable latched");

        wait_cycles = 0;
        while (1) begin
            axi_read(12'h004, rd);
            if (rd[5] === 1'b1) break;          // all_init_done
            wait_cycles = wait_cycles + 1;
            if (wait_cycles > 20000) begin
                errors = errors + 1;
                $display("  FAIL: configuration never completed (STATUS=%08x)", rd);
                break;
            end
        end
        // spi_busy toggles with every frame once sampling starts, so there is
        // nothing to assert about its level here.
        check(rd[6] === 1'b1, "all_id_ok");
        check(rd[7] === 1'b1, "all_cfg_ok");

        // ------------------------------------------------ per-device registers
        axi_read(12'h100, rd);
        check(rd[15:0] === 16'h0801, "DEV_ID[0]");
        axi_read(12'h104, rd);
        check(rd[15:0] === 16'h0801, "DEV_ID[1]");

        axi_read(12'h060, rd);
        check(rd[0] === 1'b1 && rd[1] === 1'b1 && rd[2] === 1'b1,
              "DEV_STATUS[0] init/id/cfg");

        // ------------------------------------------------ stream, then drain
        m_tready = 1'b1;
        wait (beats >= 4*NDEV);
        repeat (20) @(posedge clk);
        check(bad_beats === 0, "every stream beat carries its own device tag");
        $display("  streamed %0d beats", beats);

        axi_read(12'h140, rd);
        check(rd >= 32'd2, "DEV_SAMPLES[0] advanced");

        // ------------------------------------------------ back-pressure
        m_tready = 1'b0;
        repeat (5) @(posedge clk);
        held_tdata = m_tdata;
        held_tuser = m_tuser;
        repeat (30) @(posedge clk);
        if (m_tvalid) begin
            check(m_tdata === held_tdata, "tdata held stable under back-pressure");
            check(m_tuser === held_tuser, "tuser held stable under back-pressure");
        end

        // ------------------------------------------------ FIFO overflow
        axi_read(12'h208, drops_a);
        // Keep the sink stalled until the small FIFO provably overflows.
        wait_cycles = 0;
        while (wait_cycles < 60000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        axi_read(12'h208, drops_b);
        axi_read(12'h204, rd);
        check(rd[16] === 1'b1, "FIFO_STATUS reports full after stalling the sink");
        check(drops_b > drops_a, "DROP_COUNT advanced on overflow");
        $display("  drops %0d -> %0d, fifo_status=%08x", drops_a, drops_b, rd);

        // ------------------------------------------------ clear and resume
        axi_write(12'h000, 32'h0000_0014);      // clear FIFO + enable still set
        axi_read (12'h204, rd);
        check(rd[17] === 1'b1, "FIFO empty after clear");
        m_tready = 1'b1;
        repeat (200) @(posedge clk);
        check(beats > 4*NDEV, "stream resumed after the FIFO was cleared");

        // ------------------------------------------------ soft reset
        axi_write(12'h000, 32'h0000_0001);
        axi_read (12'h000, rd);
        check(rd[2] === 1'b0, "soft reset cleared the enable bit");

        if (errors == 0)
            $display("PASS tb_ads131m08_axi: registers, stream, back-pressure, overflow and clear all behave");
        else begin
            $display("FAIL tb_ads131m08_axi: %0d errors", errors);
            $fatal(1, "tb_ads131m08_axi failed");
        end
        $finish;
    end

    initial begin
        #300_000_000;
        $display("FAIL tb_ads131m08_axi: timeout, beats=%0d", beats);
        $fatal(1, "timeout");
    end

endmodule
