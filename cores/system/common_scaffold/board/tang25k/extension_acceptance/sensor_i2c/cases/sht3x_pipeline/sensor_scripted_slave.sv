// Synthesizable synchronous scripted pin slave; no physical sensor pins.
module sensor_scripted_slave #(parameter SENSOR=0,CORRUPT=0)(
 input wire clk,rst_n,scl,sda,output reg drive_low,output reg fault,
 output reg[15:0]starts,stops,read_bytes,write_bytes);
 reg prev_scl,prev_sda,reading,master_nack;reg[3:0]bit_count;reg[1:0]phase;
 reg[7:0]rx,pointer,read_base;reg[3:0]read_index;reg[15:0]polls;reg[15:0]read_word;
 wire rise=!prev_scl&&scl,fall=prev_scl&&!scl;
 wire start=prev_sda&&!sda&&scl,stop=!prev_sda&&sda&&scl;
 wire[7:0]address_write=SENSOR==0?8'hd0:SENSOR==1?8'h90:8'h88;
 function[7:0]value_byte;input[7:0]a;input[3:0]n;begin
 value_byte=0;
 if(SENSOR==0)case(a)
 0:value_byte=CORRUPT?8'h57:8'h58;1:value_byte=8'h59;2:value_byte=8'h23;3:value_byte=7;4:value_byte=8'h31;5:value_byte=8'h92;6:value_byte=8'h99;15:value_byte=8'h83;default:value_byte=0;
 endcase
 else if(SENSOR==1)value_byte=read_base==1?(n==0?read_word[15:8]:read_word[7:0]):(n==0?8'h80:(CORRUPT?8'h00:8'h01));
 else case(n)0:value_byte=8'hbe;1:value_byte=8'hef;2:value_byte=CORRUPT?8'h93:8'h92;3:value_byte=8'h12;4:value_byte=8'h34;5:value_byte=8'h37;default:value_byte=0;endcase
 end endfunction
 wire[7:0]current_byte=value_byte(pointer,read_index);
 wire[7:0]next_byte=value_byte(pointer+1'b1,read_index+1'b1);
 always @(posedge clk)begin
 if(!rst_n)begin prev_scl<=1;prev_sda<=1;drive_low<=0;fault<=0;reading<=0;master_nack<=0;bit_count<=0;phase<=3;rx<=0;pointer<=0;read_base<=0;read_index<=0;polls<=0;read_word<=0;starts<=0;stops<=0;read_bytes<=0;write_bytes<=0;end
 else begin
 prev_scl<=scl;prev_sda<=sda;
 if(start)begin starts<=starts+1'b1;reading<=0;bit_count<=0;phase<=0;rx<=0;drive_low<=0;end
 else if(stop)begin stops<=stops+1'b1;reading<=0;phase<=3;drive_low<=0;end
 else if(rise)begin
 if(reading)begin
 if(bit_count<8)bit_count<=bit_count+1'b1;
 else if(bit_count==8)begin
 master_nack<=sda;bit_count<=9;read_bytes<=read_bytes+1'b1;
 if(SENSOR==0&&sda!=((pointer==6)||(pointer==15)||(polls==3)))fault<=1;
 if(SENSOR==1&&sda!=(read_index==1))fault<=1;
 if(SENSOR==2&&sda!=(read_index==5))fault<=1;
 end
 end else if(phase!=3)begin
 if(bit_count<8)begin rx<={rx[6:0],sda};bit_count<=bit_count+1'b1;end
 else if(bit_count==8)bit_count<=9;
 end
 end else if(fall)begin
 if(reading)begin
 if(bit_count<8)drive_low<=~current_byte[7-bit_count];else if(bit_count==8)drive_low<=0;
 else if(master_nack)begin reading<=0;phase<=3;drive_low<=0;end
 else begin pointer<=pointer+1'b1;read_index<=read_index+1'b1;bit_count<=0;drive_low<=~next_byte[7];end
 end else if(phase!=3)begin
 if(bit_count==8)drive_low<=1;
 else if(bit_count==9)begin
 drive_low<=0;bit_count<=0;rx<=0;
 if(phase==0)begin
 if(rx!=address_write&&rx!=(address_write|1))fault<=1;
 if(rx[0])begin
 reading<=1;read_index<=0;read_base<=pointer;
 if(SENSOR==1&&pointer==1)begin read_word<=polls==0?16'h4583:16'hc583;drive_low<=polls==0;polls<=polls+1'b1;end
 else begin drive_low<=~value_byte(pointer,0)>>7;if(SENSOR==0)polls<=polls+1'b1;end
 end else phase<=1;
 end else if(phase==1)begin
 if(SENSOR==2)begin if(rx!=8'h24)fault<=1;write_bytes<=write_bytes+1'b1;end
 else pointer<=rx;
 phase<=2;
 end else begin
 write_bytes<=write_bytes+1'b1;
 if(SENSOR==1)begin if((write_bytes==0&&rx!=8'hc5)||(write_bytes==1&&rx!=8'h83))fault<=1;end
 else if(SENSOR==2&&rx!=0)fault<=1;
 else if(SENSOR==0)fault<=1;
 end
 end
 end
 end
 end
 end
endmodule
