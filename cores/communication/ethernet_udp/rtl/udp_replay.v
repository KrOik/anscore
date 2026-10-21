// Synthesizable finite digital RMII loopback owner. No physical PHY bypass claim.
module udp_replay(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_packets,cmd_length,input wire [31:0] cmd_seed,cmd_timeout,
 input wire [1:0] cmd_fault,
 output wire done_valid,input wire done_ready,output reg [4:0] error,
 output reg [31:0] cycles,tx_packets,rx_packets,tx_bytes,rx_bytes,tx_crc,rx_crc,
 output wire probe_txen,output wire [1:0] probe_txd
);
 localparam IDLE=0,CLEAR=1,COMMAND=2,LOAD=3,WAIT_PACKET=4,ABORT=5,RESPONSE=6;
 reg[2:0] state;reg[15:0] packets,length;reg[31:0] seed,timeout,packet;
 reg[1:0] fault;reg[10:0] send_index,receive_index;
 reg packet_received;reg[31:0] rng;reg[12:0] wire_index;
 wire core_reset=rst_n&&state!=CLEAR&&state!=ABORT;
 wire tready,sready,tdone,txen;wire[1:0] txd;wire[2:0] terror;
 wire rv,rk,rl;wire[7:0] rd;wire[95:0] ru;wire[31:0] rip;wire[15:0] rp;
 wire[31:0] rg,rb,ro,rf,rbytes,ug,bh,bi,bu,tf,tbytes;
 wire rready=state==WAIT_PACKET&&!fault[1]&&rng[2:0]!=0;
 wire advance=state==WAIT_PACKET&&tdone&&packet_received&&error==0;
 wire[95:0] owner={64'd0,packet};
 function[7:0] pattern(input[31:0] p,input[10:0] n,input[31:0] key);
 begin if(n<4)pattern=p>>(n*8);else pattern=key[7:0]+p[7:0]*17+n[7:0]*29;end endfunction
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);reg[31:0] x;integer j;
 begin x=c;for(j=0;j<8;j=j+1)x=(x[0]^b[j])?(x>>1)^32'hedb88320:x>>1;crcbyte=x;end endfunction
 wire[7:0] send_data=pattern(packet,send_index,seed);
 // Flip one body dibit per frame without updating its transmitted FCS.
 wire[1:0] loop_data=txd^((fault[0]&&wire_index==200)?2'd1:2'd0);
 assign probe_txen=txen;assign probe_txd=loop_data;
 assign cmd_ready=rst_n&&state==IDLE;assign done_valid=rst_n&&state==RESPONSE;
 rmii_udp_transmitter sender(clk,core_reset,state==COMMAND,tready,
  48'h84ba591684c2,32'hc0a88901,16'd11452,16'd9000,length,packet[15:0],owner,
  state==LOAD,sready,send_data,1'b1,send_index==length-1'b1,
  txen,txd,tdone,advance,terror,,tf,tbytes);
 rmii_udp_receiver #(.MAC(48'h84ba591684c2),.IP(32'hc0a88901),.PORT(9000))
  receiver(clk,core_reset,txen,loop_data,rv,rready,rd,rk,rl,ru,rip,rp,
   rg,rb,ro,rf,rbytes,ug,bh,bi,bu);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;packets<=0;length<=0;seed<=0;timeout<=0;packet<=0;fault<=0;
   send_index<=0;receive_index<=0;packet_received<=0;rng<=1;wire_index<=0;
   error<=0;cycles<=0;tx_packets<=0;rx_packets<=0;tx_bytes<=0;rx_bytes<=0;
   tx_crc<=32'hffffffff;rx_crc<=32'hffffffff;
  end else begin
   if(txen)wire_index<=wire_index+1'b1;else wire_index<=0;
   if(state!=IDLE&&state!=CLEAR&&state!=ABORT&&state!=RESPONSE)begin
    cycles<=cycles+1'b1;rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    if(cycles>=timeout-1)begin error<=2;state<=ABORT;end
    else if(rb||ro||bh||bi||bu)begin error<=4;state<=ABORT;end
    else if(tdone&&terror!=0)begin error<=16;state<=ABORT;end
    else begin
     if(state==COMMAND&&tready)begin send_index<=0;receive_index<=0;packet_received<=0;state<=LOAD;end
     if(state==LOAD&&sready)begin
      tx_bytes<=tx_bytes+1'b1;tx_crc<=crcbyte(tx_crc,send_data);
      if(send_index==length-1'b1)state<=WAIT_PACKET;else send_index<=send_index+1'b1;
     end
     if(rv&&rready)begin
      rx_bytes<=rx_bytes+1'b1;rx_crc<=crcbyte(rx_crc,rd);
      if(!rk||rd!=pattern(packet,receive_index,seed)||rl!=(receive_index==length-1'b1)||
         ru[31:0]!=packet||rip!=32'hc0a8890f||rp!=11452)begin error<=8;state<=ABORT;end
      else if(rl)begin rx_packets<=rx_packets+1'b1;packet_received<=1;end
      else receive_index<=receive_index+1'b1;
     end
     if(advance)begin
      tx_packets<=tx_packets+1'b1;
      if(packet==packets-1'b1)state<=RESPONSE;
      else begin packet<=packet+1'b1;state<=COMMAND;end
     end
    end
   end else case(state)
    IDLE:if(cmd_valid)begin
     packets<=cmd_packets;length<=cmd_length;seed<=cmd_seed;timeout<=cmd_timeout;fault<=cmd_fault;
     rng<=cmd_seed==0?1:cmd_seed;packet<=0;cycles<=0;error<=0;
     tx_packets<=0;rx_packets<=0;tx_bytes<=0;rx_bytes<=0;tx_crc<=32'hffffffff;rx_crc<=32'hffffffff;
     if(cmd_packets==0||cmd_length<4||cmd_length>1472||cmd_timeout==0)begin error<=1;state<=RESPONSE;end
     else state<=CLEAR;
    end
    CLEAR:state<=COMMAND;
    ABORT:state<=RESPONSE;
    RESPONSE:if(done_ready)state<=IDLE;
   endcase
  end
 end
endmodule
