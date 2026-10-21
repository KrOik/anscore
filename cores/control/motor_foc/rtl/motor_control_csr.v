// One outstanding CSR response and one owned motor command/result.
module motor_control_csr #(parameter [63:0] BUILD_ID=0)(
 input wire clk,rst_n,external_fault_n,monitor_tick,qa,qb,qindex,index_reset,
 input wire req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output reg resp_error,output reg [31:0] resp_data,
 input wire resp_ready,
 output wire [2:0] high_gate,low_gate,output wire applied_update
);
reg response,busy,pending,occupied,enable,clear_fault,capture_wait;
reg [31:0] cfg[0:14];reg [31:0] result[0:11];reg [31:0] serial;
reg [63:0] timestamp;reg [63:0] result_time;
wire ready,done,safe,pwm_fault;wire [31:0] id,faults;wire [7:0] error,cause;
wire [63:0] fault_time;wire signed [31:0] position,velocity;
wire signed [11:0] md,mq,vd,vq;wire [15:0] du,dv,dw;
wire take=req_valid&&req_ready;
wire command=take&&req_write&&req_addr==8'h10&&req_strobe==15;
wire ack=command&&req_data==2&&occupied;
assign req_ready=rst_n&&!response;assign resp_valid=rst_n&&response;
motor_controller controller(clk,rst_n,enable,external_fault_n,clear_fault,monitor_tick,
 qa,qb,qindex,index_reset,pending,ready,cfg[0][1:0],cfg[0][8],cfg[0][9],
 cfg[1][9:0],cfg[2][9:0],cfg[3][9:0],cfg[4][7:0],cfg[5],cfg[6][15:0],
 cfg[7][11:0],cfg[8][11:0],cfg[9][11:0],cfg[10][11:0],cfg[11][3:0],
 cfg[12][15:0],cfg[13][15:0],cfg[14],done,ack,id,error,position,velocity,
 md,mq,vd,vq,du,dv,dw,high_gate,low_gate,safe,pwm_fault,cause,fault_time,faults,applied_update);
integer i,lane;reg [31:0] read_value;reg bad;
always @* begin
 read_value=0;bad=0;lane=0;
 if(req_addr[1:0]!=0)bad=1;
 else case(req_addr)
  0:read_value=32'h464f4331;
  4:read_value={26'd0,pwm_fault,safe,clear_fault,enable,occupied,busy};
  8:read_value=BUILD_ID[31:0];12:read_value=BUILD_ID[63:32];
  20:read_value={24'd0,cause};24:read_value=faults;
  28:read_value=fault_time[31:0];32:read_value=fault_time[63:32];
  36:read_value=serial;40:read_value=result_time[31:0];44:read_value=result_time[63:32];
  default:begin
   if(req_addr>=8'h40&&req_addr<=8'h78)begin lane=(req_addr-8'h40)>>2;read_value=cfg[lane];end
   else if(req_addr>=8'h80&&req_addr<=8'hac)begin lane=(req_addr-8'h80)>>2;read_value=result[lane];if(!occupied)bad=1;end
   else bad=1;
  end
 endcase
end
always @(posedge clk)begin
 if(!rst_n)begin
  response<=0;busy<=0;pending<=0;occupied<=0;enable<=0;clear_fault<=0;capture_wait<=0;
  resp_error<=0;resp_data<=0;serial<=0;timestamp<=0;result_time<=0;
  for(i=0;i<15;i=i+1)cfg[i]<=0;
  for(i=0;i<12;i=i+1)result[i]<=0;
  cfg[9]<=8;cfg[10]<=4;cfg[11]<=4;cfg[12]<=256;cfg[13]<=2;
 end else begin
  timestamp<=timestamp+1;
  if(pending&&ready)pending<=0;
  // Allow the first-fault register to observe the controller's new trip.
  if(done&&!occupied&&!capture_wait)capture_wait<=1;
  if(done&&!occupied&&capture_wait)begin
   occupied<=1;serial<=serial+1;result_time<=timestamp;
   result[0]<=id;result[1]<={24'd0,error};result[2]<=position;result[3]<=velocity;
   result[4]<={{20{md[11]}},md};result[5]<={{20{mq[11]}},mq};
   result[6]<={{20{vd[11]}},vd};result[7]<={{20{vq[11]}},vq};
   result[8]<={16'd0,du};result[9]<={16'd0,dv};result[10]<={16'd0,dw};
   result[11]<={24'd0,cause};
  end
  if(response)begin if(resp_ready)response<=0;end
  else if(take)begin
   response<=1;resp_error<=bad;resp_data<=read_value;
   if(req_write)begin
    resp_data<=0;resp_error<=1;
    if(req_strobe==15&&req_addr[1:0]==0)begin
     if(req_addr>=8'h40&&req_addr<=8'h78&&!busy)begin
      cfg[(req_addr-8'h40)>>2]<=req_data;resp_error<=0;
     end else if(req_addr==8'h10)case(req_data)
      1:if(!busy&&!clear_fault&&ready)begin busy<=1;pending<=1;resp_error<=0;end
      2:if(occupied)begin occupied<=0;busy<=0;capture_wait<=0;resp_error<=0;end
      4:if(!busy&&!enable)begin clear_fault<=1;resp_error<=0;end
      8:if(!busy&&!enable)begin clear_fault<=0;resp_error<=0;end
      16:if(!busy&&!clear_fault&&safe&&!pwm_fault)begin enable<=1;resp_error<=0;end
      32:begin enable<=0;resp_error<=0;end
      default:resp_error<=1;
     endcase
    end
   end
  end
 end
end
endmodule

