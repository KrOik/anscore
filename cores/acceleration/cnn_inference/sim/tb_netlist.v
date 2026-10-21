`timescale 1ns/1ps
module tb_netlist;
    reg clk=0, rst=0, uart_rx=1;
    wire tx1,tx2,tx3;
    integer to=0;
    top dut(.clk(clk),.rst(rst),.uart_rx(uart_rx),
            .uart_tx_p15(tx1),.uart_tx_u16(tx2),.uart_tx_v22(tx3));
    always #10 clk=~clk;
    always @(posedge clk) begin
        if (to>100 && (^dut.\u_eng.crc === 1'bx)) begin
            $display("X crc t=%0t state=%b ph=%h layer=%b ic=%0d sx=%0d sy=%0d ppx=%0d ppy=%0d",
                     $time, dut.\u_eng.state [3:0], dut.\u_eng.ph ,
                     dut.\u_eng.layer , dut.\u_eng.ic , dut.\u_eng.sx , dut.\u_eng.sy ,
                     dut.\u_eng.ppx , dut.\u_eng.ppy );
            $display("  wreg0=%h wreg15=%h wq=%h",
                     dut.\u_eng.wreg[0] , dut.\u_eng.wreg[15] , dut.\u_eng.wmem_q );
            $finish;
        end
        if (dut.\u_eng.done === 1'b1) begin
            $display("NETSIM done crc=%h cyc=%h", dut.\u_eng.crc , dut.\u_eng.cyc );
            $finish;
        end
        to=to+1;
    end
endmodule
