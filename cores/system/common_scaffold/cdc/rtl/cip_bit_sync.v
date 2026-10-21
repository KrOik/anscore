// Single slow level ONLY. This does not synchronize a bus or preserve pulses.
module cip_bit_sync #(parameter STAGES=2, parameter RESET_VALUE=1'b0)(
    input wire clk, rst_n, clk_en, async_in,
    output wire sync_out
);
(* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync_regs;
assign sync_out = sync_regs[STAGES-1];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync_regs <= {STAGES{RESET_VALUE}};
    else if (clk_en) sync_regs <= {sync_regs[STAGES-2:0], async_in};
end
initial if (STAGES < 2) $fatal(1, "STAGES must be at least two");
endmodule
