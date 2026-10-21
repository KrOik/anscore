// March C- controller, explicit memory request/response, one command at a time.
module sys_march_controller #(parameter DEPTH=64,WIDTH=32,TIMEOUT=128)(
 input wire clk,rst_n,start,output reg busy,done,
 output wire mem_valid,input wire mem_ready,output wire mem_write,
 output reg [$clog2(DEPTH)-1:0] mem_address,output wire [WIDTH-1:0] mem_wdata,
 input wire rsp_valid,output wire rsp_ready,input wire [WIDTH-1:0] mem_rdata,input wire rsp_error,
 output reg [31:0] errors,output reg [$clog2(DEPTH)-1:0] first_error_address,
 output reg [2:0] first_error_phase
);
localparam AW=$clog2(DEPTH);
reg [2:0] phase;
reg [1:0] state;
reg [31:0] age;
wire read_phase=(phase!=0);
wire ones=(phase==2||phase==4);
wire descending=(phase==3||phase==4);
assign mem_valid=busy&&(state==0||state==2);
assign mem_write=(phase==0||state==2);
assign mem_wdata=(phase==1||phase==3)?{WIDTH{1'b1}}:{WIDTH{1'b0}};
assign rsp_ready=busy&&(state==1||state==3);
task advance_address;
begin
 state<=0;
 if((descending&&mem_address==0)||(!descending&&mem_address==DEPTH-1)) begin
  if(phase==5) begin busy<=0; done<=1; end
  else begin phase<=phase+1'b1; mem_address<=(phase==2||phase==3)?DEPTH-1:0; end
 end else mem_address<=descending?mem_address-1'b1:mem_address+1'b1;
end
endtask
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin busy<=0; done<=0; phase<=0; state<=0; age<=0; mem_address<=0; errors<=0; first_error_address<=0; first_error_phase<=0; end
 else begin
  if(start&&!busy) begin busy<=1; done<=0; phase<=0; state<=0; age<=0; mem_address<=0; errors<=0; first_error_address<=0; first_error_phase<=0; end
  if(busy) begin
   age<=age+1;
   if(mem_valid&&mem_ready) begin state<=state+1'b1; age<=0; end
   else if(rsp_valid&&rsp_ready) begin
    age<=0;
    if(rsp_error) begin errors<=errors+1; busy<=0; done<=1; if(errors==0) begin first_error_address<=mem_address; first_error_phase<=phase; end end
    else begin
     if(state==1&&read_phase) begin
      if(mem_rdata!==(ones?{WIDTH{1'b1}}:{WIDTH{1'b0}})) begin
       errors<=errors+1;
       if(errors==0) begin first_error_address<=mem_address; first_error_phase<=phase; end
      end
      if(phase!=5) state<=2; else advance_address;
     end else advance_address;
    end
   end else if(TIMEOUT!=0&&age>=TIMEOUT-1) begin
    busy<=0; done<=1; errors<=errors+1;
    if(errors==0) begin first_error_address<=mem_address; first_error_phase<=phase; end
   end
  end
 end
end
initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0||WIDTH<1) $fatal(1,"invalid March parameters");
endmodule
