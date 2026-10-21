// Three independent held result mailboxes, one-outstanding transport-neutral CSR.
module video_results_csr #(parameter [63:0] BUILD_ID=0)(
 input wire clk,rst_n,
 input wire [2:0] result_valid,input wire [95:0] result_frame,result_crc,result_pixels,
 input wire [23:0] result_error,input wire [38:0] result_version,
 input wire req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,output reg resp_error,output reg [31:0] resp_data,
 input wire resp_ready,output reg [2:0] occupied
);
reg response;reg [63:0] timestamp;
reg [31:0] frames[0:2],crcs[0:2],pixels[0:2],versions[0:2],serials[0:2],dropped[0:2];
reg [7:0] errors[0:2];reg [63:0] times[0:2];
integer g;integer lane;reg [31:0] read_value;reg read_error;
wire take=req_valid&&req_ready;
wire ack_ok=req_addr==8'h10&&req_write&&req_strobe==15&&req_data[31:3]==0&&req_data[2:0]!=0;
wire [2:0] ack=(take&&ack_ok)?req_data[2:0]:3'd0;
assign req_ready=rst_n&&!response;assign resp_valid=rst_n&&response;
always @* begin
 read_value=0;read_error=0;lane=0;
 if(req_addr[1:0]!=0)read_error=1;
 else case(req_addr)
  0:read_value=32'h56494431;
  4:read_value={29'd0,occupied};
  8:read_value=BUILD_ID[31:0];12:read_value=BUILD_ID[63:32];
  default:begin
   if(req_addr<8'h40||req_addr>=8'ha0)read_error=1;
   else begin
    lane=(req_addr-8'h40)>>5;
    case(req_addr[4:2])
     0:read_value=frames[lane];1:read_value=crcs[lane];2:read_value=pixels[lane];
     3:read_value={24'd0,errors[lane]};4:read_value=versions[lane];
     5:read_value=serials[lane];6:read_value=times[lane][31:0];7:read_value=times[lane][63:32];
    endcase
    if(!occupied[lane])read_error=1;
   end
  end
 endcase
 // Live per-lane overrun counts are readable even with an empty mailbox.
 if(req_addr==8'ha0)begin read_value=dropped[0];read_error=0;end
 if(req_addr==8'ha4)begin read_value=dropped[1];read_error=0;end
 if(req_addr==8'ha8)begin read_value=dropped[2];read_error=0;end
end
always @(posedge clk)begin
 if(!rst_n)begin
  timestamp<=0;occupied<=0;response<=0;resp_error<=0;resp_data<=0;
  for(g=0;g<3;g=g+1)begin frames[g]<=0;crcs[g]<=0;pixels[g]<=0;errors[g]<=0;
   versions[g]<=0;serials[g]<=0;dropped[g]<=0;times[g]<=0;end
 end else begin
  timestamp<=timestamp+1;
  if(response)begin if(resp_ready)response<=0;end
  else if(take)begin response<=1;resp_data<=read_value;
   resp_error<=req_write?!ack_ok:read_error;
   if(req_write)resp_data<=0;
  end
  for(g=0;g<3;g=g+1)begin
   if(ack[g])occupied[g]<=0;
   if(result_valid[g])begin
    if(!occupied[g]||ack[g])begin
     occupied[g]<=1;frames[g]<=result_frame[g*32+:32];crcs[g]<=result_crc[g*32+:32];
     pixels[g]<=result_pixels[g*32+:32];errors[g]<=result_error[g*8+:8];
     versions[g]<={19'd0,result_version[g*13+:13]};serials[g]<=serials[g]+1;
     times[g]<=timestamp;
    end else dropped[g]<=dropped[g]+1;
   end
  end
 end
end
endmodule

