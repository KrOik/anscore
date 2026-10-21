module sensor_ads1115_top #(parameter CLK_HZ=50000000,BAUD=115200,CORRUPT=0)(input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
sensor_i2c_top #(.SENSOR(1),.CORRUPT(CORRUPT),.CLK_HZ(CLK_HZ),.BAUD(BAUD))inner(.*);
endmodule
