`timescale 1ns/1ps
module tb_common_peripherals;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, clk_en = 1;
    reg [8:0] cmd_valid = 0, rsp_ready = 0;
    wire [8:0] cmd_ready, rsp_valid;
    reg cmd_write = 0;
    reg [7:0] cmd_addr = 0;
    reg [31:0] cmd_wdata = 0;
    wire [31:0] rsp_rdata [0:8];
    wire [1:0] rsp_error [0:8];
    reg [7:0] gpio_in = 0, irq_in = 0;
    wire [7:0] gpio_out, gpio_oe;
    wire pwm_out, timer_irq, irq_any;
    wire uart_tx, spi_sclk, spi_mosi;
    wire [2:0] spi_cs_n;
    wire i2c_scl_drive_low, i2c_sda_drive_low;
    wire qspi_cs_n, qspi_sclk;
    wire [3:0] qspi_dq_out, qspi_dq_oe;
    wire sd_cs_n, sd_sclk, sd_mosi;
    reg [7:0] peripheral_inputs = 0;
    integer transactions = 0;
    integer high_count, i;

`define CSR(N) .clk(clk), .rst_n(rst_n), .clk_en(clk_en), \
    .cmd_valid(cmd_valid[N]), .cmd_ready(cmd_ready[N]), \
    .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata), \
    .rsp_valid(rsp_valid[N]), .rsp_ready(rsp_ready[N]), \
    .rsp_rdata(rsp_rdata[N]), .rsp_error(rsp_error[N])

    common_gpio #(.WIDTH(8)) gpio (`CSR(0), .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe));
    common_pwm #(.COUNTER_WIDTH(8), .RESET_PERIOD(10)) pwm (`CSR(1), .pwm_out(pwm_out));
    common_timer #(.COUNTER_WIDTH(8)) timer (`CSR(2), .timer_irq(timer_irq));
    common_irq #(.WIDTH(8)) irq (`CSR(3), .irq_in(irq_in), .irq_any(irq_any));
    common_uart uart (`CSR(4), .uart_rx(peripheral_inputs[0]), .uart_tx(uart_tx));
    common_spi_master #(.NUM_CS(3), .CPOL(1), .CPHA(1)) spi (
        `CSR(5), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi),
        .spi_miso(peripheral_inputs[1]), .spi_cs_n(spi_cs_n));
    common_i2c_master i2c (`CSR(6), .i2c_scl_in(peripheral_inputs[2]),
        .i2c_sda_in(peripheral_inputs[3]), .i2c_scl_drive_low(i2c_scl_drive_low),
        .i2c_sda_drive_low(i2c_sda_drive_low));
    common_qspi_controller #(.CPOL(1)) qspi (`CSR(7), .qspi_cs_n(qspi_cs_n),
        .qspi_sclk(qspi_sclk), .qspi_dq_in(peripheral_inputs[7:4]),
        .qspi_dq_out(qspi_dq_out), .qspi_dq_oe(qspi_dq_oe));
    common_sd_spi sd (`CSR(8), .card_present(peripheral_inputs[0]),
        .sd_miso(peripheral_inputs[1]), .sd_cs_n(sd_cs_n),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi));
`undef CSR

    // External pins change even during CE pauses: placeholders must never drive.
    always @(negedge clk) peripheral_inputs <= peripheral_inputs + 8'h37;
    always @(posedge clk) begin
        #1;
        if ({uart_tx, spi_sclk, spi_mosi, spi_cs_n,
             i2c_scl_drive_low, i2c_sda_drive_low, qspi_cs_n, qspi_sclk,
             qspi_dq_out, qspi_dq_oe, sd_cs_n, sd_sclk, sd_mosi}
            !== {1'b1,1'b1,1'b0,3'b111,1'b0,1'b0,1'b1,1'b1,
                 4'b0000,4'b0000,1'b1,1'b0,1'b1})
            $fatal(1, "placeholder electrical activity or unknown pin");
    end

    task check_response;
        input integer index;
        input [1:0] expected_error;
        input [31:0] expected_data;
        begin
            if (rsp_valid[index] !== 1'b1 || rsp_error[index] !== expected_error ||
                rsp_rdata[index] !== expected_data)
                $fatal(1, "response index=%0d addr=%02x got valid=%b error=%h data=%h expected %h/%h",
                    index, cmd_addr, rsp_valid[index], rsp_error[index], rsp_rdata[index],
                    expected_error, expected_data);
        end
    endtask

    task transfer;
        input integer index;
        input write_enable;
        input [7:0] address;
        input [31:0] write_data;
        input [1:0] expected_error;
        input [31:0] expected_data;
        reg [63:0] freeze_snapshot;
        begin
            @(negedge clk);
            clk_en = 0; cmd_valid = 9'b1 << index; rsp_ready = 0;
            cmd_write = write_enable; cmd_addr = address; cmd_wdata = write_data;
            repeat (2) begin
                @(posedge clk); #1;
                if (rsp_valid[index] !== 0 || cmd_ready[index] !== 0)
                    $fatal(1, "command accepted with CE=0 index=%0d", index);
            end
            @(negedge clk); clk_en = 1;
            #1;
            if (cmd_ready[index] !== 1) $fatal(1, "command not ready index=%0d", index);
            @(posedge clk); #1;
            check_response(index, expected_error, expected_data);
            @(negedge clk); cmd_valid = 0;
            repeat (3) begin
                @(posedge clk); #1;
                check_response(index, expected_error, expected_data);
                if (cmd_ready[index] !== 0) $fatal(1, "accepted command while response blocked");
            end
            @(negedge clk); clk_en = 0; rsp_ready = 9'b1 << index;
            freeze_snapshot = {gpio_out, gpio_oe, pwm.counter, pwm.period, pwm.duty,
                               timer.remaining, timer.reload_value, timer_irq, irq_any, pwm_out};
            repeat (3) begin
                @(posedge clk); #1;
                check_response(index, expected_error, expected_data);
                if (freeze_snapshot !== {gpio_out, gpio_oe, pwm.counter, pwm.period, pwm.duty,
                                         timer.remaining, timer.reload_value, timer_irq, irq_any, pwm_out})
                    $fatal(1, "functional state changed with CE=0");
            end
            @(negedge clk); clk_en = 1;
            @(posedge clk); #1;
            if (rsp_valid[index] !== 0) $fatal(1, "response did not retire");
            @(negedge clk); rsp_ready = 0;
            transactions = transactions + 1;
        end
    endtask

    task tick;
        input integer count;
        begin repeat (count) begin @(posedge clk); #1; end end
    endtask

    initial begin
        #1; rst_n = 0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        tick(1);
        if (rsp_valid !== 0 || gpio_out !== 0 || gpio_oe !== 0 ||
            pwm_out !== 0 || timer_irq !== 0 || irq_any !== 0)
            $fatal(1, "reset state invalid");

        // Every placeholder errors on both writes and reads, including address 0.
        for (i = 4; i < 9; i = i + 1) begin
            transfer(i, 1, 8'h00, 32'hdeadbeef, 1, 0);
            transfer(i, 0, 8'h00, 0, 1, 0);
            transfer(i, 1, 8'hfc, 32'hffffffff, 1, 0);
        end
        for (i = 0; i < 4; i = i + 1) begin
            transfer(i, 1, 8'hff, 32'hdeadbeef, 1, 0);
            transfer(i, 0, 8'h01, 0, 1, 0);
        end

        gpio_in = 8'h5a; tick(3);
        transfer(0, 0, 8'h00, 0, 0, 32'h5a);
        transfer(0, 1, 8'h00, 32'hff, 2, 0);
        transfer(0, 1, 8'h08, 32'h0f, 0, 0);
        transfer(0, 1, 8'h04, 32'ha5, 0, 0);
        transfer(0, 1, 8'h0c, 32'h0a, 0, 0);
        transfer(0, 1, 8'h10, 32'h03, 0, 0);
        transfer(0, 1, 8'h14, 32'hff, 0, 0);
        transfer(0, 0, 8'h04, 0, 0, 32'h53);
        transfer(0, 0, 8'h08, 0, 0, 32'h0f);
        transfer(0, 0, 8'h0c, 0, 2, 0);
        if (gpio_out !== 8'h53 || gpio_oe !== 8'h0f) $fatal(1, "GPIO value mismatch");

        transfer(1, 1, 8'h04, 0, 3, 0);
        transfer(1, 1, 8'h04, 256, 3, 0);
        transfer(1, 1, 8'h08, 11, 3, 0);
        transfer(1, 1, 8'h00, 2, 3, 0);
        transfer(1, 1, 8'h0c, 0, 2, 0);
        transfer(1, 1, 8'h08, 3, 0, 0);
        transfer(1, 1, 8'h04, 2, 3, 0);
        transfer(1, 1, 8'h00, 1, 0, 0);
        high_count = 0;
        repeat (40) begin tick(1); if (pwm_out === 1) high_count = high_count + 1; end
        if (high_count != 12) $fatal(1, "PWM duty count %0d != 12", high_count);
        transfer(1, 1, 8'h08, 10, 0, 0);
        repeat (20) begin tick(1); if (pwm_out !== 1) $fatal(1, "PWM 100 percent failed"); end
        transfer(1, 1, 8'h08, 0, 0, 0);
        repeat (20) begin tick(1); if (pwm_out !== 0) $fatal(1, "PWM 0 percent failed"); end
        transfer(1, 1, 8'h00, 0, 0, 0);

        transfer(2, 1, 8'h00, 1, 3, 0); // Cannot start with reload=0.
        transfer(2, 1, 8'h04, 0, 3, 0);
        transfer(2, 1, 8'h04, 256, 3, 0);
        transfer(2, 1, 8'h08, 0, 2, 0);
        transfer(2, 1, 8'h04, 20, 0, 0);
        transfer(2, 1, 8'h00, 1, 0, 0);
        if (timer.remaining !== 16 || timer_irq !== 0) $fatal(1, "timer start/ticks invalid");
        tick(15);
        if (timer.remaining !== 1 || timer_irq !== 0) $fatal(1, "timer expired early");
        tick(1);
        if (timer_irq !== 1 || timer.remaining !== 0 || timer.enabled !== 0)
            $fatal(1, "one-shot expiry invalid");
        transfer(2, 1, 8'h0c, 1, 0, 0);
        transfer(2, 0, 8'h0c, 0, 0, 0);
        transfer(2, 1, 8'h04, 100, 0, 0);
        transfer(2, 1, 8'h00, 3, 0, 0);
        tick(96);
        if (timer_irq !== 1 || timer.remaining !== 100 || timer.enabled !== 1)
            $fatal(1, "periodic expiry/reload invalid");
        transfer(2, 1, 8'h0c, 1, 0, 0);
        if (timer_irq !== 0) $fatal(1, "timer W1C failed");
        tick(100);
        if (timer_irq !== 1) $fatal(1, "periodic timer did not retrigger");
        transfer(2, 1, 8'h00, 0, 0, 0);
        transfer(2, 1, 8'h0c, 1, 0, 0);

        transfer(3, 1, 8'h00, 3, 0, 0);
        irq_in = 1; tick(4);
        if (irq_any !== 1) $fatal(1, "IRQ rising edge missing");
        transfer(3, 0, 8'h04, 0, 0, 1);
        transfer(3, 1, 8'h04, 1, 0, 0);
        tick(5);
        if (irq_any !== 0) $fatal(1, "IRQ level retriggered edge collector");
        irq_in = 2; tick(4);
        transfer(3, 0, 8'h0c, 0, 0, 2);
        transfer(3, 1, 8'h00, 1, 0, 0);
        if (irq_any !== 0) $fatal(1, "IRQ mask ignored");
        transfer(3, 0, 8'h04, 0, 0, 2);
        transfer(3, 1, 8'h08, 0, 2, 0);
        transfer(3, 1, 8'h04, 2, 0, 0);

        // Expiration coincident with W1C must remain pending.
        transfer(2, 1, 8'h04, 1, 0, 0);
        transfer(2, 1, 8'h00, 3, 0, 0);
        transfer(2, 1, 8'h0c, 1, 0, 0);
        if (timer_irq !== 1) $fatal(1, "timer W1C lost simultaneous expiry");
        transfer(2, 1, 8'h00, 0, 0, 0);
        transfer(2, 1, 8'h0c, 1, 0, 0);
        transfer(2, 0, 8'h08, 0, 0, 0);
        transfer(1, 0, 8'h04, 0, 0, 10);

        // A new synchronized edge also wins over simultaneous IRQ W1C.
        irq_in = 0; tick(4);
        transfer(3, 1, 8'h00, 2, 0, 0);
        @(negedge clk); irq_in = 2;
        tick(2);
        @(negedge clk); cmd_valid = 9'b1 << 3;
        cmd_write = 1; cmd_addr = 8'h04; cmd_wdata = 2;
        @(posedge clk); #1;
        check_response(3, 0, 0);
        if (irq_any !== 1 || irq.pending !== 2) $fatal(1, "IRQ W1C lost simultaneous edge");
        @(negedge clk); cmd_valid = 0; rsp_ready = 9'b1 << 3;
        tick(1);
        @(negedge clk); rsp_ready = 0;
        transactions = transactions + 1;

        // Reset aborts outstanding responses even with CE low.
        @(negedge clk); cmd_addr = 8'hfc; cmd_write = 1; cmd_valid = 9'h1ff;
        @(posedge clk); #1;
        if (rsp_valid !== 9'h1ff) $fatal(1, "parallel request setup failed");
        @(negedge clk); clk_en = 0; rst_n = 0; cmd_valid = 0;
        #1;
        if (rsp_valid !== 0 || cmd_ready !== 0 || gpio_oe !== 0 || gpio_out !== 0 ||
            pwm_out !== 0 || timer_irq !== 0 || irq_any !== 0)
            $fatal(1, "asynchronous reset failed with CE=0");
        tick(2);
        @(negedge clk); rst_n = 1; clk_en = 1;
        transfer(0, 0, 8'h04, 0, 0, 0);
        transfer(4, 1, 8'h00, 32'h55, 1, 0);
        if (transactions < 70) $fatal(1, "too few checked transactions");
        $display("COMMON_PERIPHERALS PASS transactions=%0d modules=9 functional=4 placeholder=5", transactions);
        $finish;
    end
    initial begin #2000000; $fatal(1, "watchdog timeout"); end
endmodule
