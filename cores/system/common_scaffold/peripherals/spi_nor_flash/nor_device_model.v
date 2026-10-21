// Independent behavioral 3-wire NOR device: interprets actual SCK/CS/MOSI edges.
module nor_device_model #(parameter integer MIN_CS_NS=40)(
 input wire rst_n,cs_n,sclk,mosi,force_busy,reject_wren,input wire[1:0]busy_polls,
 output reg miso
);
 reg[7:0]mem[0:65535];reg[7:0]command,shift,outbyte;reg[23:0]address;
 integer bit_count,byte_count,data_count,busy_left,idx,base;reg wel;reg[7:0]incoming;
 time last_high;integer transactions,programs,erases;
 function[7:0]status;begin status={6'b0,wel,(busy_left>0||force_busy)};end endfunction
 function[7:0]read_mem;input[23:0]a;begin read_mem=a<65536?mem[a]:8'hff;end endfunction
 initial begin for(idx=0;idx<65536;idx=idx+1)mem[idx]=8'hff;wel=0;busy_left=0;miso=1;bit_count=0;byte_count=0;transactions=0;programs=0;erases=0;last_high=0;end
 always @(negedge cs_n)begin
  if(rst_n&&$time-last_high<MIN_CS_NS)$fatal(1,"flash CS high interval");
  bit_count=0;byte_count=0;data_count=0;command=0;address=0;shift=0;outbyte=8'hff;miso=1;transactions=transactions+1;
 end
 always @(posedge sclk)if(!cs_n&&rst_n)begin
  incoming={shift[6:0],mosi};shift=incoming;
  if(bit_count==7)begin
   bit_count=0;shift=0;byte_count=byte_count+1;
   if(byte_count==1)begin
    command=incoming;
    case(incoming)
     8'h9f:outbyte=8'hef;
     8'h05:outbyte=status();
     8'h03,8'h0b,8'h02,8'h20,8'h06:outbyte=8'hff;
     default:$fatal(1,"unsupported wire opcode %h",incoming);
    endcase
   end else case(command)
    8'h9f:case(byte_count)2:outbyte=8'h40;3:outbyte=8'h18;default:outbyte=8'hff;endcase
    8'h05:outbyte=status();
    8'h03,8'h0b,8'h02,8'h20:begin
     if(byte_count<=4)begin
      address={address[15:0],incoming};
      if(byte_count==4&&command==8'h03)outbyte=read_mem(address);
     end else if(command==8'h03)begin address=address+1;outbyte=read_mem(address);end
     else if(command==8'h0b)begin if(byte_count==5)outbyte=read_mem(address);else begin address=address+1;outbyte=read_mem(address);end end
     else if(command==8'h02)begin
      if(!wel||busy_left>0||force_busy)$fatal(1,"program without WEL/ready");
      if(address<65536)mem[address]=mem[address]&incoming;
      address={address[23:8],address[7:0]+8'd1};data_count=data_count+1;
     end
    end
    default:begin end
   endcase
  end else bit_count=bit_count+1;
 end
 always @(negedge sclk)if(!cs_n&&rst_n)miso=outbyte[7-bit_count];
 always @(posedge cs_n)if(rst_n)begin
  if(bit_count!=0)$display("NOTE partial SPI byte aborted by host/reset");
  case(command)
   8'h06:if(!force_busy&&busy_left==0&&!reject_wren)wel=1;
   8'h02:if(data_count>0)begin wel=0;busy_left=busy_polls;programs=programs+1;end
   8'h20:if(byte_count==4)begin
    if(!wel||busy_left>0||force_busy||address[11:0]!=0)$fatal(1,"erase without WEL/ready/alignment");
    base={address[23:12],12'b0};for(idx=0;idx<4096;idx=idx+1)if(base+idx<65536)mem[base+idx]=8'hff;
    wel=0;busy_left=busy_polls;erases=erases+1;
   end
   8'h05:if(byte_count>=2&&busy_left>0)busy_left=busy_left-1;
   default:begin end
  endcase
  last_high=$time;miso=1;
 end
endmodule
