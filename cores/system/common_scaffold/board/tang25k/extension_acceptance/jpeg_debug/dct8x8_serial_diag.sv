module dct8x8_serial_diag #(parameter BITS=16)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,cfg_inverse,output wire cfg_ready,output reg cfg_done,
 input wire signed [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 output reg signed [BITS-1:0] m_data,output reg m_valid,input wire m_ready,
 output wire[15:0]debug_state,output wire busy,output reg saturated
);
 localparam CAPTURE=0,READ=1,MAC=2,STORE=3,OUT_READ=4,OUT_LOAD=5,OUT_HOLD=6;
 reg [2:0] state;reg inverse,pass;
 reg [5:0] count;reg [2:0] outer,position,tap;
 reg signed [23:0] input_mem[0:63],middle_mem[0:63],sample_q;
 reg signed [15:0] coeff_q;
 reg signed [47:0] acc;
 wire signed [39:0] product=sample_q*coeff_q;
 wire signed [47:0] next_acc=acc+{{8{product[39]}},product};
 wire signed [47:0] rounded=(acc+48'sd8192)>>>14;
 wire signed [23:0] maximum=(1<<(BITS-1))-1;
 wire signed [23:0] minimum=-(1<<(BITS-1));
 wire [5:0] read_address=pass?{tap,outer}:{outer,tap};
 wire [5:0] write_address=pass?{position,outer}:{outer,position};
 wire [5:0] coeff_address=inverse?{tap,position}:{position,tap};
 assign debug_state={state,pass,count,tap,position};
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
 sample_q<=0;coeff_q<=0;acc<=0;m_data<=0;m_valid<=0;cfg_done<=0;saturated<=0;
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
 coeff_q<=coefficient(coeff_address);state<=MAC;
 end
 MAC:begin
 acc<=next_acc;
 if(tap==7) state<=STORE;else begin tap<=tap+1'b1;state<=READ;end
 end
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
 if(sample_q>maximum) begin m_data<=maximum[BITS-1:0];saturated<=1;end
 else if(sample_q<minimum) begin m_data<=minimum[BITS-1:0];saturated<=1;end
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
