// Transport-neutral same-clock CSR, byte addressed, one response slot.
// Canonical sys_register_snapshot supplies the simultaneous capture bank.
module csr_metrics_snapshot #(parameter WORDS=51)(
 input wire clk,rst_n,input wire [WORDS*32-1:0] live,
 input wire req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,output reg resp_valid,resp_error,
 output reg [31:0] resp_data,input wire resp_ready
);
 wire accept=req_valid&&req_ready;
 wire capture=accept&&req_write&&req_addr==0&&req_strobe==15&&req_data==1;
 wire [WORDS*32-1:0] snapshot;
 wire [63:0] timestamp;
 wire [31:0] snapshot_id;
 reg captured;
 sys_register_snapshot #(.WORDS(WORDS)) bank(clk,rst_n,live,capture,,1'b1,,snapshot,timestamp,snapshot_id);
 assign req_ready=rst_n&&(!resp_valid||resp_ready);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin resp_valid<=0;resp_error<=0;resp_data<=0;captured<=0;end
  else begin
   if(resp_valid&&resp_ready)resp_valid<=0;
   if(capture)captured<=1;
   if(accept)begin
    resp_valid<=1;resp_error<=0;resp_data<=0;
    if(req_addr[1:0]!=0)resp_error<=1;
    else if(req_write)begin
     if(!capture)resp_error<=1;
    end else case(req_addr)
     0:resp_data<=snapshot_id;
     4:resp_data<=timestamp[31:0];
     8:resp_data<=timestamp[63:32];
     12:resp_data<={31'd0,captured};
     default:if(req_addr>=16&&((req_addr-16)>>2)<WORDS&&captured)
      resp_data<=snapshot[((req_addr-16)>>2)*32+:32];
      else resp_error<=1;
    endcase
   end
  end
 end
 initial if(WORDS<1||WORDS>60)$fatal(1,"CSR snapshot WORDS must be 1..60");
endmodule
