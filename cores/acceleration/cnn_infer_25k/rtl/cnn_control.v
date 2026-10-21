// Transport-neutral CSR loader and complete per-layer synchronous trace RAM.
module cnn_control #(parameter [63:0] BUILD_ID=64'd0)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output reg resp_error,output reg [31:0] resp_data,
 input wire resp_ready,output wire [7:0] probe
);
 localparam IDLE=0,WAIT_LOAD=1,WAIT_READ=2,RESPONSE=3;
 reg [1:0] state,region;
 reg [15:0] load_address,read_address;
 reg [31:0] trace[0:10596],trace_q;
 reg [15:0] tap_count;
 wire accept=req_valid&&req_ready;
 wire write_ok=req_addr[1:0]==0&&req_strobe==15;
 wire load_ready,load_error,start_ready,tap_valid,done_valid;
 wire [2:0] tap_stage;wire [15:0] tap_index;wire [31:0] tap_data,cycles;
 wire [3:0] done_error;
 wire load=accept&&req_write&&write_ok&&req_addr==8'h10&&load_ready;
 wire launch=accept&&req_write&&write_ok&&req_addr==8'h14&&req_data==1&&start_ready;
 wire acknowledge=accept&&req_write&&write_ok&&req_addr==8'h14&&req_data==2&&done_valid;
 wire complete=done_valid&&done_error==0&&tap_count==10597;
 wire read_trace=accept&&!req_write&&req_addr==8'h28&&complete;
 reg [15:0] capture_address;
 assign req_ready=rst_n&&state==IDLE;
 assign resp_valid=rst_n&&state==RESPONSE;
 cnn_serial_engine engine(clk,rst_n,load,load_ready,region,load_address,req_data,load_error,
  launch,start_ready,tap_valid,1'b1,tap_stage,tap_index,tap_data,done_valid,acknowledge,done_error,cycles);
 always @*case(tap_stage)
  0:capture_address=tap_index;
  1:capture_address=3136+tap_index;
  2:capture_address=6272+tap_index;
  3:capture_address=7056+tap_index;
  4:capture_address=8624+tap_index;
  5:capture_address=10192+tap_index;
  6:capture_address=10584+tap_index;
  7:capture_address=10594+tap_index;
 endcase
 always @(posedge clk)begin
  if(rst_n&&tap_valid)trace[capture_address]<=tap_data;
  if(read_trace)trace_q<=trace[read_address];
 end
 // Registered probe only; this does not alter the functional data path.
 reg [7:0] probe_reg;assign probe=probe_reg;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;region<=0;load_address<=0;read_address<=0;
   tap_count<=0;resp_error<=0;resp_data<=0;probe_reg<=0;end
  else begin
   probe_reg<={done_error!=0,done_valid,start_ready,tap_valid,launch,load,req_valid,req_ready};
   if(launch)tap_count<=0;
   else if(tap_valid)tap_count<=tap_count+1'b1;
   case(state)
    IDLE:if(accept)begin
     state<=RESPONSE;resp_error<=0;resp_data<=0;
     if(req_addr[1:0]!=0)resp_error<=1;
     else if(req_write)begin
      if(req_strobe!=15)resp_error<=1;
      else case(req_addr)
       8'h08:if(start_ready&&req_data<3)begin region<=req_data[1:0];load_address<=0;end else resp_error<=1;
       8'h0c:if(start_ready&&req_data<65536)load_address<=req_data[15:0];else resp_error<=1;
       8'h10:if(load_ready)state<=WAIT_LOAD;else resp_error<=1;
       8'h14:if(!launch&&!acknowledge)resp_error<=1;
       8'h24:if(req_data<10597)read_address<=req_data[15:0];else resp_error<=1;
       default:resp_error<=1;
      endcase
     end else case(req_addr)
      8'h00:resp_data<=32'h434e4e31;
      8'h04:resp_data<={24'd0,done_error,1'b0,done_valid,start_ready,load_ready};
      8'h08:resp_data<={30'd0,region};
      8'h0c:resp_data<={16'd0,load_address};
      8'h18:resp_data<=cycles;
      8'h1c:resp_data<={16'd0,tap_count};
      8'h20:resp_data<={28'd0,done_error};
      8'h24:resp_data<={16'd0,read_address};
      8'h28:if(complete)state<=WAIT_READ;else resp_error<=1;
      8'h30:resp_data<=BUILD_ID[31:0];
      8'h34:resp_data<=BUILD_ID[63:32];
      default:resp_error<=1;
     endcase
    end
    WAIT_LOAD:begin
     resp_error<=load_error;if(!load_error)load_address<=load_address+1'b1;
     state<=RESPONSE;
    end
    WAIT_READ:begin resp_data<=trace_q;state<=RESPONSE;
     if(read_address<10596)read_address<=read_address+1'b1;
    end
    RESPONSE:if(resp_ready)state<=IDLE;
   endcase
  end
 end
endmodule
