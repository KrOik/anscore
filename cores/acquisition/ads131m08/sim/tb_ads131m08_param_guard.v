`timescale 1ns/1ps
module tb_ads131m08_param_guard #(
    parameter integer ADC_COUNT = 1,
    parameter integer FIFO_DEPTH = 512,
    parameter integer SCK_DIV = 1,
    parameter integer CLK_HZ = 50_000_000,
    parameter integer OSR_SEL = 2,
    parameter integer PWR_SEL = 2,
    parameter integer SCHED_DEFAULT = 0,
    parameter integer ADDR_W = 12
);
    ads131m08_multi_ip #(
        .ADC_COUNT(ADC_COUNT), .FIFO_DEPTH(FIFO_DEPTH),
        .SCK_DIV(SCK_DIV), .CLK_HZ(CLK_HZ), .OSR_SEL(OSR_SEL),
        .PWR_SEL(PWR_SEL), .SCHED_DEFAULT(SCHED_DEFAULT), .ADDR_W(ADDR_W)
    ) dut();
    initial begin
        #1;
        $display("PASS tb_ads131m08_param_guard: valid defaults elaborated");
        $finish;
    end
endmodule
