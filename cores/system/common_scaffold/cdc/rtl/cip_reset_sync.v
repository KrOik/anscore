// Reset infrastructure intentionally has no CE: asynchronous assert,
// STAGES destination-clock edges before release even when datapath is paused.
module cip_reset_sync #(parameter STAGES=2)(
    input wire clk, async_rst_n,
    output wire sync_rst_n
);
(* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] release_regs;
assign sync_rst_n = release_regs[STAGES-1];
always @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) release_regs <= 0;
    else release_regs <= {release_regs[STAGES-2:0], 1'b1};
end
initial if (STAGES < 2) $fatal(1, "STAGES must be at least two");
endmodule
