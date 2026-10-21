// Clarke -> Park using unchanged canonical signed/count formats and primitives.
// Angle/sample metadata tracks the same elastic beat as all arithmetic outputs.
module current_transform(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire signed [9:0] ia,ib,ic,input wire [7:0] theta,tolerance,
 input wire plausibility_enable,input wire [31:0] sample_id,
 output wire m_valid,input wire m_ready,
 output wire signed [11:0] d,q,alpha,beta,
 output wire [11:0] residual,output wire [3:0] range_flags,
 output wire sensor_fault,arithmetic_fault,output wire [31:0] m_sample_id
);
wire cv,pr,cf,pf;wire [31:0] clarke_result,clarke_aux,park_result,park_aux;
reg [7:0] angle0;reg [31:0] id0,id1;
reg [11:0] alpha1,beta1,residual1;reg sensor1;
acc_clarke_s12 clarke(clk,rst_n,1'b1,s_valid,s_ready,
 {12'd0,ib,ia},{22'd0,ic},{plausibility_enable,23'd0,tolerance},
 cv,pr,clarke_result,clarke_aux,cf);
acc_park_s12 park(clk,rst_n,1'b1,cv,pr,
 {20'd0,clarke_result[11:0]},{20'd0,clarke_result[23:12]},{24'd0,angle0},
 m_valid,m_ready,park_result,park_aux,pf);
assign d=park_result[11:0];assign q=park_result[23:12];
assign alpha=alpha1;assign beta=beta1;assign residual=residual1;
assign range_flags=park_aux[11:8];assign sensor_fault=sensor1;
assign arithmetic_fault=pf;assign m_sample_id=id1;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin angle0<=0;id0<=0;id1<=0;alpha1<=0;beta1<=0;residual1<=0;sensor1<=0;end
 else begin
  if(s_valid&&s_ready)begin angle0<=theta;id0<=sample_id;end
  if(cv&&pr)begin id1<=id0;alpha1<=clarke_result[11:0];beta1<=clarke_result[23:12];residual1<=clarke_aux[23:12];sensor1<=cf;end
 end
end
endmodule
