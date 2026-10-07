// csc_dbg -- self-starting wrapper around st_isp_csc for yosys `sim` checks.
module csc_dbg(input clk, output done, output pass, output [31:0] digest);
    reg [7:0] rc = 8'd0;
    reg st = 1'b0;
    wire rst_n = rc[7];
    always @(posedge clk) begin
        if (!rst_n) rc <= rc + 8'd1;
        st <= (rc == 8'd126);
    end
    st_isp_csc u (.clk(clk), .clk_en(1'b1), .rst_n(rst_n), .start(st),
                  .done(done), .pass(pass), .digest(digest), .cycles());
endmodule
