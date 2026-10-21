`timescale 1ns/1ps
module tb_uart_4;
reg clk=0; always #10 clk=~clk;
wire uart_tx; wire [1:0] led;
prod_top #(.GROUP(4),.REPORT_DELAY(16)) dut(.*);
localparam [551:0] EXPECTED=552'h50323520473d34204d3d464620453d3030303030303030204e3d303030303034303020443d4433454345444143204c3d303030303030303420533d30303030303630300d0a;
reg [7:0] value;
integer k,bit_index;
initial begin
    for(k=0;k<69;k=k+1) begin
        @(negedge uart_tx);
        repeat(651) @(posedge clk);
        #1; value[0]=uart_tx;
        for(bit_index=1;bit_index<8;bit_index=bit_index+1) begin
            repeat(434) @(posedge clk); #1; value[bit_index]=uart_tx;
        end
        repeat(434) @(posedge clk); #1;
        if(uart_tx!==1) $fatal(1,"UART stop bit failed");
        if(value!==EXPECTED[(68-k)*8+:8]) $fatal(1,"UART group4 byte%0d got%h expected%h",k,value,EXPECTED[(68-k)*8+:8]);
    end
    if(led!==2'b01) $fatal(1,"UART LED verdict mismatch");
    $display("PASS UART group=4 bytes=69 115200 8N1"); $finish;
end
initial begin #25000000; $fatal(1,"UART timeout"); end
endmodule
