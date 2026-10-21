// hv_sim_stubs -- iverilog behavioural models for Gowin primitives used by
// top_hwverify. Synthesis uses the real cells_sim.v / vendor mapping instead.
`timescale 1ns/1ps

// OSC: on-chip oscillator. 250 MHz / FREQ_DIV. FREQ_DIV=100 -> 2.5 MHz.
module OSC #(
    parameter integer FREQ_DIV = 100,
    parameter         DEVICE   = "GW2A-18"
) (
    output wire OSCOUT
);
    localparam real HALF_NS = 4000.0 * FREQ_DIV / 100.0 / 2.0; // 250MHz/FDIV
    reg o = 1'b0;
    initial o = 1'b0;
    always #(HALF_NS) o = ~o;
    assign OSCOUT = o;
endmodule

// rPLL behavioural model: emits CLKOUT at FCLKIN*(FBDIV_SEL+1)/(IDIV_SEL+1),
// LOCK asserts after ~2 us. Only CLKOUT/LOCK are modelled.
module rPLL (
    output reg  CLKOUT,
    output wire CLKOUTP,
    output wire CLKOUTD,
    output wire CLKOUTD3,
    output reg  LOCK,
    input  wire CLKIN,
    input  wire CLKFB,
    input  wire [5:0] FBDSEL,
    input  wire [5:0] IDSEL,
    input  wire [5:0] ODSEL,
    input  wire [3:0] PSDA,
    input  wire [3:0] DUTYDA,
    input  wire [3:0] FDLY,
    input  wire RESET,
    input  wire RESET_P
);
    parameter         FCLKIN = "100.0";
    parameter         DYN_IDIV_SEL = "false";
    parameter integer IDIV_SEL = 0;
    parameter         DYN_FBDIV_SEL = "false";
    parameter integer FBDIV_SEL = 0;
    parameter         DYN_ODIV_SEL = "false";
    parameter integer ODIV_SEL = 8;
    parameter [3:0]   PSDA_SEL = "0000";
    parameter         DYN_DA_EN = "false";
    parameter [3:0]   DUTYDA_SEL = "1000";
    parameter         CLKOUT_FT_DIR = 1'b1;
    parameter         CLKOUTP_FT_DIR = 1'b1;
    parameter integer CLKOUT_DLY_STEP = 0;
    parameter integer CLKOUTP_DLY_STEP = 0;
    parameter         CLKFB_SEL = "internal";
    parameter         CLKOUT_BYPASS = "false";
    parameter         CLKOUTP_BYPASS = "false";
    parameter         CLKOUTD_BYPASS = "false";
    parameter integer DYN_SDIV_SEL = 2;
    parameter         CLKOUTD_SRC = "CLKOUT";
    parameter         CLKOUTD3_SRC = "CLKOUT";

    // model the specific configuration used by top_hwverify:
    // FCLKIN=27 MHz, IDIV=1, FBDIV=2 -> CLKOUT=54 MHz (18.52 ns period).
    // RESET holds CLKOUT low and LOCK deasserted; ~2 us lock time after
    // release so pll_lock_cycles is non-trivial in simulation.
    initial begin CLKOUT = 1'b0; LOCK = 1'b0; end
    always @(posedge RESET) begin LOCK = 1'b0; CLKOUT = 1'b0; end
    always @(negedge RESET) begin #2000 LOCK = 1'b1; end
    always #9.26 if (!RESET && LOCK) CLKOUT = ~CLKOUT;
    assign CLKOUTP = 1'b0;
    assign CLKOUTD = 1'b0;
    assign CLKOUTD3 = 1'b0;
endmodule
