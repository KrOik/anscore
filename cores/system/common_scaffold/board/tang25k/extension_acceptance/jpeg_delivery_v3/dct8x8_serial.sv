module dct8x8_serial #(parameter BITS=16)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,cfg_inverse,output wire cfg_ready,output reg cfg_done,
 input wire signed [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 output reg signed [BITS-1:0] m_data,output reg m_valid,input wire m_ready,
 output wire busy,output reg saturated
);
 localparam CAPTURE=0,READ=1,MAC=2,STORE=3,OUT_READ=4,OUT_LOAD=5,OUT_HOLD=6,MUL_PART=7,MUL_SUM=8,MAC_MID=9,MAC_HIGH=10,MUL_CARRY1=11,MUL_CARRY2=12,MUL_CARRY3=13,ROUND_LOW=14;
 reg [3:0] state;reg inverse,pass;
 reg [5:0] count;reg [2:0] outer,position,tap;
 reg signed [23:0] input_mem[0:63],middle_mem[0:63],sample_q;
 reg signed [15:0] coeff_q;
 reg signed [47:0] acc;
 reg[15:0] p00,p10;reg signed[16:0] p01,p11,p20;reg signed[15:0] p21;
 reg signed[17:0] diagonal1,diagonal2;reg signed[18:0] carry1,carry2;reg[7:0] byte0;reg signed[39:0]product_q;
 wire signed[15:0] top_limb=$signed(p21)+$signed(carry2>>>8);
 reg[16:0] acc_low_sum,acc_mid_base,acc_mid_sum;reg[15:0] acc_high_sum;
 reg[12:0] rounded_low;reg[11:0] rounded_high;wire[23:0] rounded={rounded_high+{11'b0,rounded_low[12]},rounded_low[11:0]};
 wire signed [23:0] maximum=(1<<(BITS-1))-1;
 wire signed [23:0] minimum=-(1<<(BITS-1));
 wire [5:0] read_address=pass?{tap,outer}:{outer,tap};
 wire [5:0] write_address=pass?{position,outer}:{outer,position};
 wire [5:0] coeff_address=inverse?{tap,position}:{position,tap};

 assign busy=state!=CAPTURE || count!=0;
 assign cfg_ready=ce&&!busy;
 assign s_ready=ce&&state==CAPTURE&&!(cfg_valid&&!busy);
 function signed [15:0] coefficient;
 input [5:0] address;
 begin case(address)
 // Orthonormal DCT-II, Q14.
6'd0:coefficient=16'sd5793;
6'd1:coefficient=16'sd5793;
6'd2:coefficient=16'sd5793;
6'd3:coefficient=16'sd5793;
6'd4:coefficient=16'sd5793;
6'd5:coefficient=16'sd5793;
6'd6:coefficient=16'sd5793;
6'd7:coefficient=16'sd5793;
6'd8:coefficient=16'sd8035;
6'd9:coefficient=16'sd6811;
6'd10:coefficient=16'sd4551;
6'd11:coefficient=16'sd1598;
6'd12:coefficient=-16'sd1598;
6'd13:coefficient=-16'sd4551;
6'd14:coefficient=-16'sd6811;
6'd15:coefficient=-16'sd8035;
6'd16:coefficient=16'sd7568;
6'd17:coefficient=16'sd3135;
6'd18:coefficient=-16'sd3135;
6'd19:coefficient=-16'sd7568;
6'd20:coefficient=-16'sd7568;
6'd21:coefficient=-16'sd3135;
6'd22:coefficient=16'sd3135;
6'd23:coefficient=16'sd7568;
6'd24:coefficient=16'sd6811;
6'd25:coefficient=-16'sd1598;
6'd26:coefficient=-16'sd8035;
6'd27:coefficient=-16'sd4551;
6'd28:coefficient=16'sd4551;
6'd29:coefficient=16'sd8035;
6'd30:coefficient=16'sd1598;
6'd31:coefficient=-16'sd6811;
6'd32:coefficient=16'sd5793;
6'd33:coefficient=-16'sd5793;
6'd34:coefficient=-16'sd5793;
6'd35:coefficient=16'sd5793;
6'd36:coefficient=16'sd5793;
6'd37:coefficient=-16'sd5793;
6'd38:coefficient=-16'sd5793;
6'd39:coefficient=16'sd5793;
6'd40:coefficient=16'sd4551;
6'd41:coefficient=-16'sd8035;
6'd42:coefficient=16'sd1598;
6'd43:coefficient=16'sd6811;
6'd44:coefficient=-16'sd6811;
6'd45:coefficient=-16'sd1598;
6'd46:coefficient=16'sd8035;
6'd47:coefficient=-16'sd4551;
6'd48:coefficient=16'sd3135;
6'd49:coefficient=-16'sd7568;
6'd50:coefficient=16'sd7568;
6'd51:coefficient=-16'sd3135;
6'd52:coefficient=-16'sd3135;
6'd53:coefficient=16'sd7568;
6'd54:coefficient=-16'sd7568;
6'd55:coefficient=16'sd3135;
6'd56:coefficient=16'sd1598;
6'd57:coefficient=-16'sd4551;
6'd58:coefficient=16'sd6811;
6'd59:coefficient=-16'sd8035;
6'd60:coefficient=16'sd8035;
6'd61:coefficient=-16'sd6811;
6'd62:coefficient=16'sd4551;
6'd63:coefficient=-16'sd1598;
 default:coefficient=0;
 endcase end endfunction
 initial if(BITS<2||BITS>16) $fatal(1,"invalid BITS");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAPTURE;inverse<=0;pass<=0;count<=0;outer<=0;position<=0;tap<=0;
 sample_q<=0;coeff_q<=0;p00<=0;p10<=0;p01<=0;p11<=0;p20<=0;p21<=0;diagonal1<=0;diagonal2<=0;carry1<=0;carry2<=0;byte0<=0;rounded_low<=0;rounded_high<=0;product_q<=0;acc<=0;acc_low_sum<=0;acc_mid_base<=0;acc_mid_sum<=0;acc_high_sum<=0;m_data<=0;m_valid<=0;cfg_done<=0;saturated<=0;
 end else if(ce) begin
 cfg_done<=0;
 if(cfg_valid&&cfg_ready) begin inverse<=cfg_inverse;cfg_done<=1;end
 case(state)
 CAPTURE:if(s_valid&&s_ready) begin
 input_mem[count]<=s_data;
 if(count==63) begin count<=0;outer<=0;position<=0;tap<=0;pass<=0;acc<=0;saturated<=0;state<=READ;end
 else count<=count+1'b1;
 end
 READ:begin
 sample_q<=pass?middle_mem[read_address]:input_mem[read_address];
 coeff_q<=coefficient(coeff_address);state<=MUL_PART;
 end
 MUL_PART:begin
 p00<=sample_q[7:0]*coeff_q[7:0];p10<=sample_q[15:8]*coeff_q[7:0];
 p01<=$signed({1'b0,sample_q[7:0]})*$signed(coeff_q[15:8]);
 p11<=$signed({1'b0,sample_q[15:8]})*$signed(coeff_q[15:8]);
 p20<=$signed(sample_q[23:16])*$signed({1'b0,coeff_q[7:0]});
 p21<=$signed(sample_q[23:16])*$signed(coeff_q[15:8]);state<=MUL_SUM;
 end
 MUL_SUM:begin
 diagonal1<=$signed({p01[16],p01})+$signed({2'b0,p10});
 diagonal2<=$signed({p11[16],p11})+$signed({p20[16],p20});byte0<=p00[7:0];state<=MUL_CARRY1;
 end
 MUL_CARRY1:begin carry1<=$signed({diagonal1[17],diagonal1})+$signed({11'b0,p00[15:8]});state<=MUL_CARRY2;end
 MUL_CARRY2:begin carry2<=$signed({diagonal2[17],diagonal2})+(carry1>>>8);state<=MUL_CARRY3;end
 MUL_CARRY3:begin product_q<={top_limb,carry2[7:0],carry1[7:0],byte0};state<=MAC;end
 MAC:begin
 acc_low_sum<={1'b0,acc[15:0]}+{1'b0,product_q[15:0]};
 acc_mid_base<={1'b0,acc[31:16]}+{1'b0,product_q[31:16]};
 acc_high_sum<=acc[47:32]+{{8{product_q[39]}},product_q[39:32]};state<=MAC_MID;
 end
 MAC_MID:begin acc_mid_sum<=acc_mid_base+{16'b0,acc_low_sum[16]};state<=MAC_HIGH;end
 MAC_HIGH:begin
 acc<={acc_high_sum+{15'b0,acc_mid_sum[16]},acc_mid_sum[15:0],acc_low_sum[15:0]};
 if(tap==7) state<=ROUND_LOW;else begin tap<=tap+1'b1;state<=READ;end
 end
 ROUND_LOW:begin rounded_low<={1'b0,acc[25:14]}+{12'b0,acc[13]};rounded_high<=acc[37:26];state<=STORE;end
 STORE:begin
 if(pass) input_mem[write_address]<=rounded[23:0];else middle_mem[write_address]<=rounded[23:0];
 acc<=0;tap<=0;
 if(position==7) begin position<=0;
 if(outer==7) begin outer<=0;
 if(pass) begin count<=0;state<=OUT_READ;end
 else begin pass<=1;state<=READ;end
 end else begin outer<=outer+1'b1;state<=READ;end
 end else begin position<=position+1'b1;state<=READ;end
 end
 OUT_READ:begin sample_q<=input_mem[count];state<=OUT_LOAD;end
 OUT_LOAD:begin
 if(sample_q[23:BITS-1]!={(25-BITS){sample_q[BITS-1]}}) begin m_data<=sample_q[23]?minimum[BITS-1:0]:maximum[BITS-1:0];saturated<=1;end
 else m_data<=sample_q[BITS-1:0];
 m_valid<=1;state<=OUT_HOLD;
 end
 OUT_HOLD:if(m_ready) begin
 m_valid<=0;
 if(count==63) begin count<=0;state<=CAPTURE;end
 else begin count<=count+1'b1;state<=OUT_READ;end
 end
 endcase
 end end
endmodule
