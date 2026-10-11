// Existing kernels, CE=1. Test fixture only; no additional IP count.
module sys_legacy_4(input wire clk,rst_n,input wire [5:0] selected,input wire [95:0] q_data,input wire q_valid,output wire q_ready,output wire [191:0] r_data,output wire r_valid,input wire r_ready);
wire [7:0] ready,valid,fault; wire [31:0] data[0:7],aux[0:7];
assign q_ready=ready[selected[2:0]]; assign r_valid=valid[selected[2:0]]; assign r_data={127'd0,fault[selected[2:0]],aux[selected[2:0]],data[selected[2:0]]};
prod_walking_pattern32 u0(clk,rst_n,1'b1,q_valid&&(selected==0),ready[0],q_data[31:0],q_data[63:32],q_data[95:64],valid[0],r_ready&&(selected==0),data[0],aux[0],fault[0]);
prod_march_step32 u1(clk,rst_n,1'b1,q_valid&&(selected==1),ready[1],q_data[31:0],q_data[63:32],q_data[95:64],valid[1],r_ready&&(selected==1),data[1],aux[1],fault[1]);
prod_stuck_fault32 u2(clk,rst_n,1'b1,q_valid&&(selected==2),ready[2],q_data[31:0],q_data[63:32],q_data[95:64],valid[2],r_ready&&(selected==2),data[2],aux[2],fault[2]);
prod_parity_lane32 u3(clk,rst_n,1'b1,q_valid&&(selected==3),ready[3],q_data[31:0],q_data[63:32],q_data[95:64],valid[3],r_ready&&(selected==3),data[3],aux[3],fault[3]);
prod_redundancy_compare32 u4(clk,rst_n,1'b1,q_valid&&(selected==4),ready[4],q_data[31:0],q_data[63:32],q_data[95:64],valid[4],r_ready&&(selected==4),data[4],aux[4],fault[4]);
prod_range_guard32 u5(clk,rst_n,1'b1,q_valid&&(selected==5),ready[5],q_data[31:0],q_data[63:32],q_data[95:64],valid[5],r_ready&&(selected==5),data[5],aux[5],fault[5]);
prod_onehot_guard32 u6(clk,rst_n,1'b1,q_valid&&(selected==6),ready[6],q_data[31:0],q_data[63:32],q_data[95:64],valid[6],r_ready&&(selected==6),data[6],aux[6],fault[6]);
prod_change_detect32 u7(clk,rst_n,1'b1,q_valid&&(selected==7),ready[7],q_data[31:0],q_data[63:32],q_data[95:64],valid[7],r_ready&&(selected==7),data[7],aux[7],fault[7]);
endmodule
