// Canonical inverse Park -> common-mode SVPWM duty generator.
module voltage_modulator(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire signed [11:0] voltage_d,voltage_q,input wire [7:0] theta,
 input wire [15:0] period,input wire [31:0] sample_id,
 output wire m_valid,input wire m_ready,
 output wire [15:0] duty_u,duty_v,duty_w,m_period,
 output wire [1:0] error,output wire [3:0] rotation_flags,
 output wire [31:0] m_sample_id
);
wire iv,ir,pf;wire [31:0] result,aux;
reg [15:0] period0;reg [31:0] id0;reg [3:0] flags1;
acc_inv_park_s12 rotation(clk,rst_n,1'b1,s_valid,s_ready,
 {20'd0,voltage_d},{20'd0,voltage_q},{24'd0,theta},iv,ir,result,aux,pf);
svpwm_duty modulator(clk,rst_n,iv,ir,result[11:0],result[23:12],period0,id0,
 m_valid,m_ready,duty_u,duty_v,duty_w,m_period,error,m_sample_id);
assign rotation_flags=flags1;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin period0<=0;id0<=0;flags1<=0;end
 else begin
  if(s_valid&&s_ready)begin period0<=period;id0<=sample_id;end
  if(iv&&ir)flags1<=aux[11:8];
 end
end
endmodule
