// Two canonical conditional-integration regulators, one atomic d/q sample.
module dq_current_pi(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire signed [11:0] reference_d,reference_q,current_d,current_q,
 input wire signed [11:0] kp,ki,input wire [3:0] gain_shift,
 input wire restart,freeze_integral,input wire [31:0] sample_id,
 output wire m_valid,input wire m_ready,output wire signed [11:0] voltage_d,voltage_q,
 output wire signed [11:0] integral_d,integral_q,
 output wire [11:0] flags_d,flags_q,output wire [1:0] fault,error_clipped,
 output wire [31:0] m_sample_id
);
wire signed [12:0] ed=$signed({reference_d[11],reference_d})-$signed({current_d[11],current_d});
wire signed [12:0] eq=$signed({reference_q[11],reference_q})-$signed({current_q[11],current_q});
wire signed [11:0] d_error=ed>2047?12'sd2047:ed< -2048?-12'sd2048:ed[11:0];
wire signed [11:0] q_error=eq>2047?12'sd2047:eq< -2048?-12'sd2048:eq[11:0];
wire dr,qr,dv,qv;wire [31:0] dout,qout,daux,qaux;
wire [31:0] control={restart,freeze_integral,1'b1,25'd0,gain_shift};
assign s_ready=dr&&qr;assign m_valid=dv&&qv;
acc_ipi_pid_s12 d_regulator(clk,rst_n,1'b1,s_valid&&qr,dr,
 {20'd0,d_error},{8'd0,ki,kp},control,dv,m_ready&&qv,dout,daux,fault[0]);
acc_ipi_pid_s12 q_regulator(clk,rst_n,1'b1,s_valid&&dr,qr,
 {20'd0,q_error},{8'd0,ki,kp},control,qv,m_ready&&dv,qout,qaux,fault[1]);
assign voltage_d=dout[11:0];assign voltage_q=qout[11:0];
assign integral_d=daux[25:14];assign integral_q=qaux[25:14];
assign flags_d=dout[23:12];assign flags_q=qout[23:12];
reg [31:0] tag;reg [1:0] clipped;
assign m_sample_id=tag;assign error_clipped=clipped;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin tag<=0;clipped<=0;end
 else if(s_valid&&s_ready)begin tag<=sample_id;clipped<={(eq>2047||eq< -2048),(ed>2047||ed< -2048)};end
end
endmodule
