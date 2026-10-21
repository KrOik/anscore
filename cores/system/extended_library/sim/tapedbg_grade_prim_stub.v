// ============================================================================
// tapedbg_grade_prim_stub.v -- structurally-clean rPLL/OSC models used ONLY
// by the GRADE-RTL candidate (tools/grade_rtl.py).  The behavioural models in
// hv_sim_stubs.v are correct for event simulation but contain delay-based
// always blocks that yosys proc lowers to latch/undriven warnings, which
// would poison the Module-Completeness stage with false positives.
// Simulation keeps using hv_sim_stubs.v.
// ============================================================================
module OSC #(
    parameter integer FREQ_DIV = 100,
    parameter         DEVICE   = "GW2A-18"
)(
    output wire OSCOUT
);
assign OSCOUT = 1'b0;
endmodule

module rPLL #(
    parameter         FCLKIN         = "100.0",
    parameter         DYN_IDIV_SEL   = "false",
    parameter integer IDIV_SEL       = 0,
    parameter         DYN_FBDIV_SEL  = "false",
    parameter integer FBDIV_SEL      = 0,
    parameter         DYN_ODIV_SEL   = "false",
    parameter integer ODIV_SEL       = 8,
    parameter [3:0]   PSDA_SEL       = "0000",
    parameter         DYN_DA_EN      = "false",
    parameter [3:0]   DUTYDA_SEL     = "1000",
    parameter         CLKOUT_FT_DIR  = 1'b1,
    parameter         CLKOUTP_FT_DIR = 1'b1,
    parameter integer CLKOUT_DLY_STEP  = 0,
    parameter integer CLKOUTP_DLY_STEP = 0,
    parameter         CLKFB_SEL      = "internal",
    parameter         CLKOUT_BYPASS  = "false",
    parameter         CLKOUTP_BYPASS = "false",
    parameter         CLKOUTD_BYPASS = "false",
    parameter integer DYN_SDIV_SEL   = 2,
    parameter         CLKOUTD_SRC    = "CLKOUT",
    parameter         CLKOUTD3_SRC   = "CLKOUT",
    parameter         DEVICE         = "GW2A-18"
)(
    output wire       CLKOUT,
    output wire       CLKOUTP,
    output wire       CLKOUTD,
    output wire       CLKOUTD3,
    output wire       LOCK,
    input  wire       CLKIN,
    input  wire       CLKFB,
    input  wire [5:0] FBDSEL,
    input  wire [5:0] IDSEL,
    input  wire [5:0] ODSEL,
    input  wire [3:0] PSDA,
    input  wire [3:0] DUTYDA,
    input  wire [3:0] FDLY,
    input  wire       RESET,
    input  wire       RESET_P
);
assign CLKOUT   = 1'b0;
assign LOCK     = 1'b1;
assign CLKOUTP  = 1'b0;
assign CLKOUTD  = 1'b0;
assign CLKOUTD3 = 1'b0;
endmodule
