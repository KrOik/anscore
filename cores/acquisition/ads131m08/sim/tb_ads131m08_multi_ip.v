// Multi-device scheduler testbench.
//
// N behavioural ADS131M08 models share one SPI bus with individual CS and DRDY
// lines, exactly as the IP expects.  N is chosen at compile time:
//
//     iverilog ... -DTB_NDEV=16 ...
//
// What this proves:
//   * the shared bus is never contended: at most one CS is low and at most one
//     model drives MISO at any instant;
//   * every device is unlocked, woken and configured, and its CLOCK read-back
//     matches what was written;
//   * samples are routed to the right device index (the models encode their own
//     index and channel number in the upper code bits);
//   * switching between devices never re-runs the configuration sweep.
`timescale 1ns/1ps

`ifndef TB_NDEV
 `define TB_NDEV 4
`endif

module tb_ads131m08_multi_ip;

    localparam integer NDEV = `TB_NDEV;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    wire                 adc_sclk, adc_din;
    wire [NDEV-1:0]      adc_cs_n, adc_sync_n, adc_drdy_n;
    wire [NDEV-1:0]      dev_dout, dev_oe;

    // Wired-or of the tri-stated MISO drivers.
    wire adc_dout = |(dev_dout & dev_oe);

    // Per-device mirrors, packed so plain Verilog can index them.
    wire [16*NDEV-1:0] m_clock, m_gain1, m_gain2, m_mode, m_id;
    wire [32*NDEV-1:0] m_data_frames, m_wreg_frames, m_rreg_frames;

    integer errors = 0;

    genvar g;
    generate
        for (g = 0; g < NDEV; g = g + 1) begin : g_dev
            ads131m08_device_model #(
                .DEV_INDEX   (g),
                .DRDY_PERIOD (400 + 37*g)
            ) u_dev (
                .clk     (clk),
                .rst_n   (rst_n),
                .sclk    (adc_sclk),
                .din     (adc_din),
                .cs_n    (adc_cs_n[g]),
                .sync_n  (adc_sync_n[g]),
                .dout    (dev_dout[g]),
                .dout_oe (dev_oe[g]),
                .drdy_n  (adc_drdy_n[g]),
                .reg_clock (m_clock[16*g +: 16]),
                .reg_gain1 (m_gain1[16*g +: 16]),
                .reg_gain2 (m_gain2[16*g +: 16]),
                .reg_mode  (m_mode[16*g +: 16]),
                .reg_id    (m_id[16*g +: 16]),
                .n_data_frames (m_data_frames[32*g +: 32]),
                .n_wreg_frames (m_wreg_frames[32*g +: 32]),
                .n_rreg_frames (m_rreg_frames[32*g +: 32])
            );
        end
    endgenerate

    // ------------------------------------------------------------- the IP
    reg  enable = 1'b0;
    reg  sched_mode = 1'b0;
    reg  start_init = 1'b0;

    wire [NDEV-1:0] init_done, id_ok, cfg_ok, drdy_seen, dev_timeout, sample_valid;
    wire [16*NDEV-1:0] dev_id;
    wire [3:0]  sample_dev;
    wire [15:0] status_word;
    wire [191:0] ch_data;
    wire [31:0] frame_count;
    wire        spi_busy, all_init_done;

    ads131m08_scheduler #(
        .ADC_COUNT    (NDEV),
        .CLK_HZ       (100_000_000),
        .SCK_DIV      (1),
        .SYNC_LOW_US  (20),
        .SETTLE_US    (20),
        .DRDY_TO_US   (2_000),
        .UNLOCK_DLY_US(50),
        .WAKEUP_DLY_US(50),
        .OSR_SEL      (2),
        .PWR_SEL      (2)
    ) u_sched (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_init   (start_init),
        .enable       (enable),
        .sched_mode   (sched_mode),
        .gain1        (16'h0000),
        .gain2        (16'h0000),
        .mode_val     (16'h0100),
        .expect_id    (16'h0801),
        .osr_sel      (3'd2),
        .pwr_sel      (2'd2),
        .dev_enable   ({NDEV{1'b1}}),
        .dev_resync   ({NDEV{1'b0}}),
        .adc_sclk     (adc_sclk),
        .adc_din      (adc_din),
        .adc_dout     (adc_dout),
        .adc_cs_n     (adc_cs_n),
        .adc_sync_n   (adc_sync_n),
        .adc_drdy_n   (adc_drdy_n),
        .init_done    (init_done),
        .id_ok        (id_ok),
        .cfg_ok       (cfg_ok),
        .drdy_seen    (drdy_seen),
        .dev_timeout  (dev_timeout),
        .sample_valid (sample_valid),
        .dev_id       (dev_id),
        .sample_dev   (sample_dev),
        .status_word  (status_word),
        .ch_data      (ch_data),
        .frame_count  (frame_count),
        .spi_busy     (spi_busy),
        .all_init_done(all_init_done)
    );

    // ------------------------------------------------- bus contention monitor
    wire [NDEV-1:0] cs_active = ~adc_cs_n;
    wire more_than_one_cs = |(cs_active & (cs_active - 1'b1));
    wire more_than_one_oe = |(dev_oe    & (dev_oe    - 1'b1));

    always @(posedge clk) begin
        if (rst_n) begin
            if (more_than_one_cs) begin
                errors = errors + 1;
                $display("  FAIL bus: more than one CS low at once (cs_n=%b) @%0t",
                         adc_cs_n, $time);
            end
            if (more_than_one_oe) begin
                errors = errors + 1;
                $display("  FAIL bus: more than one device driving MISO at once (oe=%b) @%0t",
                         dev_oe, $time);
            end
        end
    end

    // ----------------------------------------------------- sample routing check
    integer sch;
    reg [23:0] cw;
    integer   per_dev_frames [0:15];

    always @(posedge clk) begin
        if (sample_valid != {NDEV{1'b0}}) begin
            per_dev_frames[sample_dev] = per_dev_frames[sample_dev] + 1;
            for (sch = 0; sch < 8; sch = sch + 1) begin
                cw = ch_data[24*sch +: 24];
                if (cw[23:17] !== {sample_dev, sch[2:0]}) begin
                    errors = errors + 1;
                    $display("  FAIL route: dev %0d ch %0d code %06x (want tag %02x)",
                             sample_dev, sch, cw,
                             {sample_dev, sch[2:0]});
                end
            end
        end
    end

    task check(input cond, input [255:0] what);
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("  FAIL: %0s", what);
            end
        end
    endtask

    integer d;
    integer n_init_wregs;

    initial begin
        for (d = 0; d < 16; d = d + 1) begin
            per_dev_frames[d] = 0;
        end

        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
        enable = 1'b1;

        // --- wait for the configuration sweep plus a few sample rounds
        wait (all_init_done === 1'b1);
        $display("  sweep done at %0t, frames=%0d", $time, frame_count);

        // The sweep must have configured every device exactly once.
        n_init_wregs = 0;
        for (d = 0; d < NDEV; d = d + 1)
            n_init_wregs = n_init_wregs + m_wreg_frames[32*d +: 32];
        check(n_init_wregs === 4*NDEV, "exactly four WREG frames per device");

        repeat (200) @(posedge clk);

        check(all_init_done === 1'b1, "all_init_done asserted");
        check(init_done === {NDEV{1'b1}}, "every device initialised");
        check(id_ok === {NDEV{1'b1}},     "every device reported the expected ID");
        check(cfg_ok === {NDEV{1'b1}},    "every CLOCK read-back matched");

        for (d = 0; d < NDEV; d = d + 1) begin
            check(m_clock[16*d +: 16] === 16'hFF0A, "CLOCK written");
            check(m_gain1[16*d +: 16] === 16'h0000, "GAIN1 written");
            check(m_gain2[16*d +: 16] === 16'h0000, "GAIN2 written");
            check(m_mode [16*d +: 16] === 16'h0100, "MODE written");
        end

        // --- round robin must reach every device
        wait (frame_count >= 3*NDEV);
        repeat (50) @(posedge clk);

        for (d = 0; d < NDEV; d = d + 1) begin
            check(per_dev_frames[d] > 0, "round robin served every device");
            check(m_wreg_frames[32*d +: 32] === 32'd4,
                  "device switching did not re-run the configuration sweep");
        end

        // --- DRDY-priority scheduling must also serve every device
        sched_mode = 1'b1;
        for (d = 0; d < NDEV; d = d + 1) per_dev_frames[d] = 0;
        wait (frame_count >= 3*NDEV + 4*NDEV);
        repeat (50) @(posedge clk);
        $display("  mode1: frames=%0d per_dev=%0d %0d %0d %0d drdy=%b",
                 frame_count, per_dev_frames[0], per_dev_frames[1],
                 per_dev_frames[2], per_dev_frames[3], adc_drdy_n);
        for (d = 0; d < NDEV; d = d + 1)
            check(per_dev_frames[d] > 0, "DRDY-priority served every device");

        // --- a resync must not leave two devices selected
        start_init = 1'b1;
        @(posedge clk);
        start_init = 1'b0;
        repeat (200) @(posedge clk);
        check(!more_than_one_cs, "no CS overlap during a resync");

        if (errors == 0)
            $display("PASS tb_ads131m08_multi_ip: N=%0d, %0d frames, bus exclusive, all devices configured",
                     NDEV, frame_count);
        else begin
            $display("FAIL tb_ads131m08_multi_ip: %0d errors", errors);
            $fatal(1, "tb_ads131m08_multi_ip failed");
        end
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL tb_ads131m08_multi_ip: timeout, frames=%0d init_done=%b id_ok=%b cfg_ok=%b",
                 frame_count, init_done, id_ok, cfg_ok);
        $fatal(1, "timeout");
    end

endmodule
