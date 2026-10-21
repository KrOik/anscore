`timescale 1ns/1ns
module tb;
reg clk=0; wire uart_tx, dbg_uart;
fft_stream_top dut(.clk(clk), .uart_tx(uart_tx), .dbg_uart(dbg_uart));
always #18.5 clk = ~clk;
integer edges=0;
reg last=1;
always @(posedge clk) begin
    edges <= edges + 1;
    if (dbg_uart !== last) begin
        last <= dbg_uart;
        $display("[%0d] dbg_uart -> %b", edges, dbg_uart);
    end
    if (edges % 1000000 == 0) $display("[%0d] alive f_done=%b fstate=%0d send_req=%b", edges, dut.f_done, dut.fstate, dut.send_req);
    if (edges > 30000000) begin $display("TIMEOUT"); $finish; end
end
endmodule
