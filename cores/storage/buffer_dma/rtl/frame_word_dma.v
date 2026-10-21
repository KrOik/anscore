// One descriptor at a time, one acknowledged memory transaction at a time.
// WRITE=1 consumes full-word packets; WRITE=0 produces them. Common reset
// aborts control only; the owner must reset its slot queues at the same time.
module frame_word_dma #(parameter WRITE=1)(
 input wire clk,rst_n,
 input wire start_valid, output wire start_ready,
 input wire [31:0] base_address, input wire [15:0] word_count,
 input wire s_valid, output wire s_ready, input wire [31:0] s_data,
 input wire [3:0] s_keep, input wire s_last,
 output wire m_valid, input wire m_ready, output wire [31:0] m_data,
 output wire [3:0] m_keep, output wire m_last,
 output wire req_valid,input wire req_ready,output wire req_write,
 output wire [31:0] req_addr,req_data,output wire [3:0] req_strobe,
 input wire resp_valid,output wire resp_ready,input wire [31:0] resp_data,
 input wire resp_error,
 output wire done_valid,input wire done_ready,output reg done_error,
 output reg [31:0] words,cycles,stalls
);
 localparam IDLE=0,INPUT_WORD=1,REQUEST=2,RESPONSE=3,OUTPUT_WORD=4,DONE=5;
 reg [2:0] state;
 reg [31:0] address,data;
 reg [15:0] remaining;
 assign start_ready=rst_n&&state==IDLE;
 assign s_ready=rst_n&&WRITE&&state==INPUT_WORD;
 assign m_valid=rst_n&&!WRITE&&state==OUTPUT_WORD;
 assign m_data=data;
 assign m_keep=4'hf;
 assign m_last=remaining==1;
 assign req_valid=rst_n&&state==REQUEST;
 assign req_write=WRITE!=0;
 assign req_addr=address;
 assign req_data=data;
 assign req_strobe=4'hf;
 assign resp_ready=rst_n&&state==RESPONSE;
 assign done_valid=rst_n&&state==DONE;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;address<=0;data<=0;remaining<=0;
   done_error<=0;words<=0;cycles<=0;stalls<=0;end
  else begin
   if(state!=IDLE&&state!=DONE)cycles<=cycles+1'b1;
   if((state==INPUT_WORD&&!s_valid)||(req_valid&&!req_ready)||
      (state==RESPONSE&&!resp_valid)||(m_valid&&!m_ready))stalls<=stalls+1'b1;
   case(state)
    IDLE:if(start_valid)begin
     address<=base_address;remaining<=word_count;words<=0;cycles<=0;stalls<=0;
     // Reject misalignment, zero length and 32-bit byte-address overflow.
     done_error<=0;
     if(base_address[1:0]!=0||word_count==0||
        {1'b0,base_address}+({17'd0,word_count}<<2)>33'h100000000)begin
      done_error<=1;state<=DONE;
     end else state<=WRITE?INPUT_WORD:REQUEST;
    end
    INPUT_WORD:if(s_valid)begin
     if(s_keep!=4'hf||s_last!=(remaining==1))begin done_error<=1;state<=DONE;end
     else begin data<=s_data;state<=REQUEST;end
    end
    REQUEST:if(req_ready)state<=RESPONSE;
    RESPONSE:if(resp_valid)begin
     if(resp_error)begin done_error<=1;state<=DONE;end
     else if(!WRITE)begin data<=resp_data;state<=OUTPUT_WORD;end
     else begin
      words<=words+1'b1;
      if(remaining==1)state<=DONE;
      else begin remaining<=remaining-1'b1;address<=address+4;state<=INPUT_WORD;end
     end
    end
    OUTPUT_WORD:if(m_ready)begin
     words<=words+1'b1;
     if(remaining==1)state<=DONE;
     else begin remaining<=remaining-1'b1;address<=address+4;state<=REQUEST;end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin done_error<=1;state<=DONE;end
   endcase
  end
 end
endmodule
