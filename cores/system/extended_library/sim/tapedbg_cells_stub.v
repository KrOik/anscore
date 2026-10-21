// ============================================================================
// tapedbg_cells_stub.v -- minimal clean Gowin LUT cell models for the
// GRADE-RTL flow (tools/grade_rtl.py).  The vendor cells_sim.v carries
// (* blackbox *) attributes and duplicates the rPLL/OSC stubs in
// hv_sim_stubs.v, so it cannot be part of the graded candidate; these two
// behavioural models are all ring_osc.v needs to elaborate.
// ============================================================================
module LUT1 (
    output wire F,
    input  wire I0
);
parameter [1:0] INIT = 2'b00;
assign F = I0 ? INIT[1] : INIT[0];
endmodule

module LUT2 (
    output wire F,
    input  wire I0,
    input  wire I1
);
parameter [3:0] INIT = 4'b0000;
wire [1:0] s = I1 ? INIT[3:2] : INIT[1:0];
assign F = I0 ? s[1] : s[0];
endmodule
