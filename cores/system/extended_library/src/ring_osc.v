// ============================================================================
// ring_osc -- tapeout-debug item A13: PVT ring-oscillator cell.
//
// An odd number of inverter stages forms a combinational loop; its free-run
// frequency tracks process/voltage/temperature of the die, which is exactly
// what is wanted for a tapeout corner probe.  The oscillator only runs while
// `en` is high (a NAND stage closes the loop), and `ro` is the raw toggling
// node -- sample it in a real clock domain with a synchroniser before
// counting edges.
//
// The stages are EXPLICIT Gowin LUT primitives (LUT1 inverter / LUT2 NAND)
// marked (* keep *): a behavioural inverter chain gets folded into a
// constant by synth_gowin (verified -- the loop collapsed to 2 cells), so
// the loop has to be built from tech cells the mapper will not touch.
// ============================================================================
module ring_osc #(
    parameter STAGES = 15          // must be odd (1 NAND + 14 inverters)
)(
    input  wire en,
    output wire ro
);

`ifdef TAPEDBG_SIM
// zero-delay loop would hang the event simulator; model ~100 MHz instead
reg ro_r = 1'b0;
always #5 ro_r = ~ro_r;
assign ro = en & ro_r;
`else

(* keep *) wire [STAGES-1:0] st;

// stage 0: F = ~(en & st[STAGES-1])  -> NAND2 closes the loop
(* keep *) LUT2 #(
    .INIT(4'b0111)
) g_nand (
    .F(st[0]), .I0(en), .I1(st[STAGES-1])
);

genvar i;
generate
    for (i = 1; i < STAGES; i = i + 1) begin : g_inv
        (* keep *) LUT1 #(
            .INIT(2'b01)              // F = ~I0
        ) g (
            .F(st[i]), .I0(st[i-1])
        );
    end
endgenerate

assign ro = st[STAGES-1];
`endif

endmodule
