// Primitive-independent user-scan transport. NOT a soft TAP or device wrapper.
// 72-bit DR, LSB first: CRC8[71:64] over payload bytes [7:0] .. [63:56].
// Command payload: {A5,tag8,write1,strobe4,addr8,data32,reserved3=0}.
module scan_csr_mailbox(
 input wire clk,tck,rst_n,scan_selected,scan_capture,scan_shift,scan_update,tdi,
 output wire tdo,
 output wire req_valid,output reg req_write,output reg [7:0] req_addr,
 output reg [31:0] req_data,output reg [3:0] req_strobe,input wire req_ready,
 input wire resp_valid,input wire [31:0] resp_data,input wire resp_error,
 output wire resp_ready
);
 (* ASYNC_REG="TRUE" *) reg [1:0] clk_release,tck_release;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) clk_release<=0;else clk_release<={clk_release[0],1'b1};
 always @(posedge tck or negedge rst_n)
  if(!rst_n) tck_release<=0;else tck_release<={tck_release[0],1'b1};
 reg request_toggle,ack_toggle;
 (* ASYNC_REG="TRUE" *) reg request_meta,request_sync,ack_meta,ack_sync;
 reg [55:0] command_hold;
 reg [40:0] response_hold; // tag, CSR error, data
 reg [40:0] response_snapshot;
 reg [71:0] shift_reg;
 reg [6:0] shifted;
 reg ack_seen,response_have,command_error;
 wire busy=request_toggle!=ack_sync;
 reg [63:0] capture_payload;
 function [7:0] crc64;
  input [63:0] payload;
  reg [7:0] c;integer b,k;
  begin
   c=0;
   for(b=0;b<8;b=b+1) begin
    c=c^payload[b*8+:8];
    for(k=0;k<8;k=k+1) c=c[7]?(c<<1)^8'h07:c<<1;
   end
   crc64=c;
  end
 endfunction
 always @* capture_payload={8'h5a,response_snapshot[40:33],
  4'd0,command_error,response_snapshot[32],response_have,busy,response_snapshot[31:0],8'h01};
 assign tdo=shift_reg[0];
 always @(posedge tck or negedge rst_n) begin
  if(!rst_n) begin
   request_toggle<=0;command_hold<=0;ack_meta<=0;ack_sync<=0;ack_seen<=0;
   response_have<=0;command_error<=0;shift_reg<=0;shifted<=0;response_snapshot<=0;
  end else if(!tck_release[1]) begin
   request_toggle<=0;command_hold<=0;ack_meta<=0;ack_sync<=0;ack_seen<=0;
   response_have<=0;command_error<=0;shift_reg<=0;shifted<=0;response_snapshot<=0;
  end else begin
   ack_meta<=ack_toggle;ack_sync<=ack_meta;
   if(ack_sync!=ack_seen) begin
    ack_seen<=ack_sync;response_have<=1;response_snapshot<=response_hold;
   end
   if(!scan_selected) shifted<=0;
   else if(scan_capture) begin
    shift_reg<={crc64(capture_payload),capture_payload};shifted<=0;
   end else if(scan_shift) begin
    shift_reg<={tdi,shift_reg[71:1]};
    if(shifted<73) shifted<=shifted+1'b1;
   end else if(scan_update) begin
    shifted<=0;
    // A full zero frame is the side-effect-free response polling command.
    if(shifted==72&&shift_reg==0) begin end
    else if(shifted!=72||shift_reg[63:56]!=8'ha5||shift_reg[2:0]!=0||
            shift_reg[71:64]!=crc64(shift_reg[63:0])||busy) command_error<=1;
    else begin
     command_hold<=shift_reg[55:0];request_toggle<=~request_toggle;
     response_have<=0;command_error<=0;
    end
   end
  end
 end
 reg [1:0] state;
 reg request_seen;
 assign req_valid=state==1;
 assign resp_ready=state==2;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   request_meta<=0;request_sync<=0;request_seen<=0;ack_toggle<=0;state<=0;
   req_write<=0;req_addr<=0;req_data<=0;req_strobe<=0;response_hold<=0;
  end else if(!clk_release[1]) begin
   request_meta<=0;request_sync<=0;request_seen<=0;ack_toggle<=0;state<=0;
   req_write<=0;req_addr<=0;req_data<=0;req_strobe<=0;response_hold<=0;
  end else begin
   request_meta<=request_toggle;request_sync<=request_meta;
   case(state)
    0:if(request_sync!=request_seen) begin
     request_seen<=request_sync;req_write<=command_hold[47];
     req_strobe<=command_hold[46:43];req_addr<=command_hold[42:35];
     req_data<=command_hold[34:3];state<=1;
    end
    1:if(req_ready) state<=2;
    2:if(resp_valid) begin
     response_hold<={command_hold[55:48],resp_error,resp_data};
     ack_toggle<=request_seen;state<=0;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
