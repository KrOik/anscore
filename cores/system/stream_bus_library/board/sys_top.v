module sys_top #(parameter PROFILE=0,BIT_CYCLES=434)(input wire clk,uart_rx,output wire uart_tx,output wire [1:0] led);
reg [7:0] por=0; always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por; wire dut_rst_n; wire [5:0] selected; wire [95:0] q_data; wire [191:0] r_data; wire q_valid,q_ready,r_valid,r_ready,active,done,error;
sys_transport #(.PROFILE(PROFILE),.BIT_CYCLES(BIT_CYCLES)) transport(clk,rst_n,uart_rx,uart_tx,selected,dut_rst_n,q_data,q_valid,q_ready,r_data,r_valid,r_ready,active,done,error);
assign led={error,active};
generate if(PROFILE==0) begin:system_ips sys_native_adapters dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==1) begin:legacy_0 sys_legacy_0 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==2) begin:legacy_1 sys_legacy_1 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==3) begin:legacy_2 sys_legacy_2 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==4) begin:legacy_3 sys_legacy_3 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==5) begin:legacy_4 sys_legacy_4 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==6) begin:legacy_5 sys_legacy_5 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==7) begin:legacy_6 sys_legacy_6 dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==8) begin:acquisition sys_acquisition_demo dut(clk,dut_rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
endgenerate
endmodule
