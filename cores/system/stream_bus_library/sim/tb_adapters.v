`timescale 1ns/1ps
module tb_adapters #(parameter PROFILE=0);
reg clk=0,rst_n=0,q_valid=0,r_ready=0;
reg [5:0] selected=0;
reg [95:0] q_data=0;
wire [191:0] r_data;
wire q_ready,r_valid;
generate if(PROFILE==0) begin:g0 sys_native_adapters dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==1) begin:g1 sys_legacy_0 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==2) begin:g2 sys_legacy_1 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==3) begin:g3 sys_legacy_2 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==4) begin:g4 sys_legacy_3 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==5) begin:g5 sys_legacy_4 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==6) begin:g6 sys_legacy_5 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==7) begin:g7 sys_legacy_6 dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
else if(PROFILE==8) begin:g8 sys_acquisition_demo dut(clk,rst_n,selected,q_data,q_valid,q_ready,r_data,r_valid,r_ready); end
endgenerate
endmodule
