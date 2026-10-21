// One outstanding CSR transaction; response routing held until consumption.
module buffer_dma_control #(parameter FRAME_COUNT=32,SLOT_WORDS=256)(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,output wire resp_valid,resp_error,
 output wire [31:0] resp_data,input wire resp_ready,output wire [7:0] probe
);
 reg busy,local_route,local_error;
 reg [31:0] local_data,seed;
 reg stalls,start;
 wire start_ready,done,error;
 wire [31:0] checked_words,check_errors,run_cycles;
 wire bready,bvalid,berror;wire [31:0] bdata;
 wire local_address=req_addr>=8'he0;
 wire accept=req_valid&&req_ready;
 assign req_ready=rst_n&&!busy&&(local_address||bready);
 assign resp_valid=rst_n&&busy&&(local_route||bvalid);
 assign resp_data=local_route?local_data:bdata;
 assign resp_error=local_route?local_error:berror;
 buffer_dma_selftest #(.FRAME_COUNT(FRAME_COUNT),.SLOT_WORDS(SLOT_WORDS)) runner(
 .clk(clk),.rst_n(rst_n),.start(start),.seed(seed),.stalls_enable(stalls),
 .start_ready(start_ready),.done(done),.error(error),.checked_words(checked_words),
 .check_errors(check_errors),.run_cycles(run_cycles),.probe(probe),
 .csr_valid(req_valid&&!busy&&!local_address),.csr_write(req_write),.csr_addr(req_addr),
 .csr_data(req_data),.csr_strobe(req_strobe),.csr_ready(bready),
 .csr_resp_valid(bvalid),.csr_resp_error(berror),.csr_resp_data(bdata),
 .csr_resp_ready(busy&&!local_route&&resp_ready));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;local_route<=0;local_error<=0;local_data<=0;
   seed<=32'h512a309b;stalls<=1;start<=0;end
  else begin
   start<=0;
   if(resp_valid&&resp_ready)busy<=0;
   if(accept)begin
    busy<=1;local_route<=local_address;local_error<=0;local_data<=0;
    if(local_address)begin
     if(req_addr[1:0]!=0)local_error<=1;
     else if(req_write)begin
      if(req_strobe!=15)local_error<=1;
      else case(req_addr)
       8'he0:if(req_data==1&&start_ready&&!start)start<=1;else local_error<=1;
       8'he4:if(start_ready&&!start)seed<=req_data;else local_error<=1;
       8'he8:if(start_ready&&!start&&req_data<=1)stalls<=req_data[0];else local_error<=1;
       default:local_error<=1;
      endcase
     end else case(req_addr)
      8'he0:local_data<={29'd0,error,done,start_ready&&!start};
      8'he4:local_data<=seed;
      8'he8:local_data<={31'd0,stalls};
      8'hec:local_data<=FRAME_COUNT;
      8'hf0:local_data<=checked_words;
      8'hf4:local_data<=check_errors;
      8'hf8:local_data<=run_cycles;
      8'hfc:local_data<=32'h42444631;
      default:local_error<=1;
     endcase
    end
   end
  end
 end
endmodule
