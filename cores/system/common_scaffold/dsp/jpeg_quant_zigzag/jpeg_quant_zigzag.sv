module jpeg_quant_zigzag #(parameter BITS=16)(
 input wire clk,rst_n,ce,
 input wire table_valid,output wire table_ready,input wire [5:0] table_index,input wire [7:0] table_value,
 input wire cfg_valid,cfg_inverse,output wire cfg_ready,output reg cfg_done,cfg_error,
 input wire signed [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 output reg signed [BITS-1:0] m_data,output reg m_valid,input wire m_ready,
 output wire busy,output reg saturated
);
 localparam CAP=0,SCAN_READ=1,SCAN_CHECK=2,COPY_READ=3,COPY_WRITE=4,
 COEF_READ=5,PREP=6,DIVIDE=7,STORE=8,OUT_READ=9,OUT_LOAD=10,OUT_HOLD=11;
 reg [3:0] state;reg inverse,pending_inverse,configured;
 reg [63:0] written;reg invalid_table;
 reg [5:0] count;
 reg [7:0] shadow[0:63],active[0:63],q;
 reg signed [BITS-1:0] memory[0:63],sample_q;
 reg negative;
 reg [BITS:0] numerator,quotient;
 reg [8:0] remainder;
 reg [5:0] bit_count;
 reg signed [BITS+9:0] value;
 wire [9:0] shifted_remainder={remainder,numerator[BITS]};
 wire [BITS:0] quotient_next={quotient[BITS-1:0],shifted_remainder>={2'b0,q}};
 wire signed [BITS+7:0] multiplied=sample_q*$signed({1'b0,q});
 wire signed [BITS+9:0] maximum=(1<<(BITS-1))-1;
 wire signed [BITS+9:0] minimum=-(1<<(BITS-1));
 assign busy=state!=CAP || count!=0;
 assign cfg_ready=ce&&!busy;
 assign table_ready=ce&&!busy&&!cfg_valid;
 assign s_ready=ce&&state==CAP&&configured&&!(cfg_valid&&!busy)&&!(table_valid&&!busy);
 function [5:0] zigzag;
 input [5:0] i;
 begin case(i)
 6'd0:zigzag=6'd0;
6'd1:zigzag=6'd1;
6'd2:zigzag=6'd8;
6'd3:zigzag=6'd16;
6'd4:zigzag=6'd9;
6'd5:zigzag=6'd2;
6'd6:zigzag=6'd3;
6'd7:zigzag=6'd10;
6'd8:zigzag=6'd17;
6'd9:zigzag=6'd24;
6'd10:zigzag=6'd32;
6'd11:zigzag=6'd25;
6'd12:zigzag=6'd18;
6'd13:zigzag=6'd11;
6'd14:zigzag=6'd4;
6'd15:zigzag=6'd5;
6'd16:zigzag=6'd12;
6'd17:zigzag=6'd19;
6'd18:zigzag=6'd26;
6'd19:zigzag=6'd33;
6'd20:zigzag=6'd40;
6'd21:zigzag=6'd48;
6'd22:zigzag=6'd41;
6'd23:zigzag=6'd34;
6'd24:zigzag=6'd27;
6'd25:zigzag=6'd20;
6'd26:zigzag=6'd13;
6'd27:zigzag=6'd6;
6'd28:zigzag=6'd7;
6'd29:zigzag=6'd14;
6'd30:zigzag=6'd21;
6'd31:zigzag=6'd28;
6'd32:zigzag=6'd35;
6'd33:zigzag=6'd42;
6'd34:zigzag=6'd49;
6'd35:zigzag=6'd56;
6'd36:zigzag=6'd57;
6'd37:zigzag=6'd50;
6'd38:zigzag=6'd43;
6'd39:zigzag=6'd36;
6'd40:zigzag=6'd29;
6'd41:zigzag=6'd22;
6'd42:zigzag=6'd15;
6'd43:zigzag=6'd23;
6'd44:zigzag=6'd30;
6'd45:zigzag=6'd37;
6'd46:zigzag=6'd44;
6'd47:zigzag=6'd51;
6'd48:zigzag=6'd58;
6'd49:zigzag=6'd59;
6'd50:zigzag=6'd52;
6'd51:zigzag=6'd45;
6'd52:zigzag=6'd38;
6'd53:zigzag=6'd31;
6'd54:zigzag=6'd39;
6'd55:zigzag=6'd46;
6'd56:zigzag=6'd53;
6'd57:zigzag=6'd60;
6'd58:zigzag=6'd61;
6'd59:zigzag=6'd54;
6'd60:zigzag=6'd47;
6'd61:zigzag=6'd55;
6'd62:zigzag=6'd62;
6'd63:zigzag=6'd63;
default:zigzag=0;
 endcase end endfunction
 initial if(BITS<2||BITS>16) $fatal(1,"invalid BITS");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=CAP;inverse<=0;pending_inverse<=0;configured<=0;written<=0;invalid_table<=0;count<=0;
 cfg_done<=0;cfg_error<=0;m_valid<=0;m_data<=0;saturated<=0;
 q<=0;sample_q<=0;negative<=0;numerator<=0;quotient<=0;remainder<=0;bit_count<=0;value<=0;
 end else if(ce) begin
 cfg_done<=0;cfg_error<=0;
 if(table_valid&&table_ready) begin shadow[table_index]<=table_value;written[table_index]<=1;end
 case(state)
 CAP:if(cfg_valid&&cfg_ready) begin
 if(written!={64{1'b1}}) cfg_error<=1;
 else begin pending_inverse<=cfg_inverse;invalid_table<=0;count<=0;state<=SCAN_READ;end
 end else if(s_valid&&s_ready) begin
 memory[inverse?zigzag(count):count]<=s_data;
 if(count==63) begin count<=0;state<=COEF_READ;saturated<=0;end else count<=count+1'b1;
 end
 SCAN_READ:begin q<=shadow[count];state<=SCAN_CHECK;end
 SCAN_CHECK:begin
 if(q==0) invalid_table<=1;
 if(count==63) begin count<=0;
 if(invalid_table||q==0) begin cfg_error<=1;state<=CAP;end else state<=COPY_READ;
 end else begin count<=count+1'b1;state<=SCAN_READ;end
 end
 COPY_READ:begin q<=shadow[count];state<=COPY_WRITE;end
 COPY_WRITE:begin active[count]<=q;
 if(count==63) begin count<=0;inverse<=pending_inverse;configured<=1;cfg_done<=1;state<=CAP;end
 else begin count<=count+1'b1;state<=COPY_READ;end
 end
 COEF_READ:begin sample_q<=memory[count];q<=active[count];state<=PREP;end
 PREP:if(inverse) begin value<=multiplied;state<=STORE;end
 else begin
 negative<=sample_q[BITS-1];
 numerator<=(sample_q[BITS-1]?- $signed({sample_q[BITS-1],sample_q}):$signed({sample_q[BITS-1],sample_q}))+(q>>1);
 quotient<=0;remainder<=0;bit_count<=BITS+1;state<=DIVIDE;
 end
 DIVIDE:begin
 numerator<={numerator[BITS-1:0],1'b0};quotient<=quotient_next;
 remainder<=shifted_remainder>=q?shifted_remainder-q:shifted_remainder;
 if(bit_count==1) begin value<=negative?-$signed({1'b0,quotient_next}):$signed({1'b0,quotient_next});state<=STORE;end
 else bit_count<=bit_count-1'b1;
 end
 STORE:begin
 if(value>maximum) begin memory[count]<=maximum[BITS-1:0];saturated<=1;end
 else if(value<minimum) begin memory[count]<=minimum[BITS-1:0];saturated<=1;end
 else memory[count]<=value[BITS-1:0];
 if(count==63) begin count<=0;state<=OUT_READ;end else begin count<=count+1'b1;state<=COEF_READ;end
 end
 OUT_READ:begin sample_q<=memory[inverse?count:zigzag(count)];state<=OUT_LOAD;end
 OUT_LOAD:begin m_data<=sample_q;m_valid<=1;state<=OUT_HOLD;end
 OUT_HOLD:if(m_ready) begin m_valid<=0;
 if(count==63) begin count<=0;state<=CAP;end else begin count<=count+1'b1;state<=OUT_READ;end
 end
 endcase
 end end
endmodule
