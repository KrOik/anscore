// 25K ROM-stimulus board harness, simulated.
//
// Two independent UART decoders: one on the on-chip stimulus line (so the packet
// bytes the FPGA generates can be compared against rom_stim_25k.py), one on the
// report line (checked against the frozen protocol oracle).  Nothing here is
// baud-adapted: both use the real 115200 timing at 50 MHz, exactly as silicon
// will see it.
`timescale 1ns/1ps
module tb_rom_harness_25k;

// The generated literal top is the design: the same file synthesis reads, with no
// parameter overrides anywhere, so nothing can select different logic here.
reg clk = 0;
always #10 clk = ~clk;                 // 50 MHz oscillator E2
wire tx, dbg;

rom_cfg_25k dut(.clk(clk), .uart_rx_pin(1'b1), .uart_tx(tx), .dbg_uart(dbg));

localparam integer TB_CLK_MHZ = 50;
localparam integer BITNS = (TB_CLK_MHZ * 1000000 / 115200) * 20;  // 8680 ns

// A round this size runs to ~1 s of *simulated* time, so a fixed wall-clock guard
// is useless: 5 s at 50 MHz is hours of host time, and the host timeout would fire
// first.  The bound is taken from the netlist's own case count instead -- every
// case ends within its NOREPORT window (100 ms) plus the bytes it moves, so
// 150 ms per case is a generous ceiling.
reg [63:0] wd_cyc = 0;
always @(posedge clk) begin
    if (!dut.impl.stim_done) wd_cyc = wd_cyc + 1;
    if (wd_cyc > (dut.impl.NCASE + 2) * 7_500_000)
        $fatal(1, "timeout: round did not complete (%0d cases)", dut.impl.NCASE);
end

// iverilog will not take a hierarchical reference in a constant expression, so the
// decoders above use the literal bit time and this block proves it matches the
// netlist instead.
initial begin
    if (dut.impl.CLK_FRE != TB_CLK_MHZ)
        $fatal(1, "TB decodes at %0d MHz but the netlist CLK_FRE is %0d",
               TB_CLK_MHZ, dut.impl.CLK_FRE);
end

integer fs, fr, k, err_s = 0, err_r = 0, n_s = 0, n_r = 0;
reg [7:0] vs, vr;

// stimulus line -> stim.bin
initial begin
    fs = $fopen("stim.bin", "w");
    forever begin
        @(negedge dut.impl.stim_tx);
        #(BITNS + BITNS / 2);
        vs = 8'h00;
        for (k = 0; k < 8; k = k + 1) begin
            vs[k] = dut.impl.stim_tx;
            #(BITNS);
        end
        if (dut.impl.stim_tx !== 1'b1) err_s = err_s + 1;
        $fwrite(fs, "%02x\n", vs);
        n_s = n_s + 1;
        $fflush(fs);
    end
end

// report line -> raw.bin
initial begin
    fr = $fopen("raw.bin", "w");
    forever begin
        @(negedge tx);
        #(BITNS + BITNS / 2);
        vr = 8'h00;
        for (k = 0; k < 8; k = k + 1) begin
            vr[k] = tx;
            #(BITNS);
        end
        if (tx !== 1'b1) err_r = err_r + 1;
        $fwrite(fr, "%02x\n", vr);
        n_r = n_r + 1;
        $fflush(fr);
    end
end

initial forever begin
    @(posedge clk);
    if (dbg !== tx) $fatal(1, "mirror pad differs from uart_tx");
end

initial begin
    wait (dut.impl.stim_done === 1'b1);
    #(BITNS * 40);
    $fclose(fs);
    $fclose(fr);
    $display("ROM SIM stim_bytes=%0d report_bytes=%0d framing_err_stim=%0d framing_err_report=%0d",
             n_s, n_r, err_s, err_r);
    if (err_s == 0 && err_r == 0 && n_s > 0 && n_r > 0)
        $display("ROM SIM DECODE OK");
    else
        $display("ROM SIM DECODE FAIL");
    $finish;
end

endmodule
