// ============================================================================
// dft_scan_chain -- tapeout-debug item A1: minimal scan chain.
//
// LEN flip-flops with parallel-capture front mux.  Two operating modes,
// stepped externally so the same chain is reachable from UART register
// bit-bang and from the mini TAP (tck-domain semantics emulated by
// single-cycle pulses):
//
//   cap  = 1-beat pulse: sreg[i] <= cap_i[i]         (functional capture)
//   se=1 & step pulse:   sreg <= {sreg[LEN-2:0], si}  (shift, TDI->si, so=MSB)
//
// so reflects sreg[LEN-1] combinationally, so a host can shift LEN bits and
// read back the captured vector MSB-first (shift order chosen so the first
// bit out is cap[LEN-1]).
//
// fi_stuck (A8 hook): when high, sreg[STUCK_BIT] reads/writes as 0 --
// models a stuck-at-0 fault so the checker/host can prove the chain
// actually reaches silicon (shifting 1s must fail at that bit).
// ============================================================================
module dft_scan_chain #(
    parameter LEN       = 64,
    parameter STUCK_BIT = 3
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           se,       // 1 = shift mode (used with step)
    input  wire           si,       // serial in
    input  wire           step,     // 1-beat pulse: one shift
    input  wire           cap,      // 1-beat pulse: parallel capture
    input  wire [LEN-1:0] cap_i,    // functional data to capture
    input  wire           fi_stuck, // fault injection: stuck-at-0 sreg
    output wire           so,
    output wire [LEN-1:0] chain_o   // whole chain visible for debug
);

reg [LEN-1:0] sreg;
wire [LEN-1:0] sh_next = {sreg[LEN-2:0], si};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sreg <= {LEN{1'b0}};
    end else begin
        if (cap)        sreg <= cap_i;
        else if (step && se) sreg <= sh_next;
        if (fi_stuck)   sreg[STUCK_BIT] <= 1'b0;
    end
end

assign so      = sreg[LEN-1];
assign chain_o = sreg;

endmodule
