// External-powered DS18B20 single measurement. Standard-speed open-drain bus.
module ds18b20_temperature #(
 parameter CLK_HZ=27000000,parameter CONVERSION_TIMEOUT_US=800000
)(
 input wire clk,rst_n,ce,start_valid,abort,ow_in,
 output wire start_ready,input wire cfg_match_rom,input wire[63:0]cfg_rom,
 output reg ow_drive_low,output wire busy,output wire done_valid,input wire done_ready,
 output reg[7:0]error_code,output wire result_valid,input wire result_ready,
 output reg signed[15:0]temperature_q4,output reg[1:0]resolution,
 output reg[71:0]scratchpad
);
 localparam DIV=(CLK_HZ+999999)/1000000,DW=DIV<2?1:$clog2(DIV);
 localparam BAD=CLK_HZ<1000000||CLK_HZ>250000000||CLK_HZ%1000000!=0||CONVERSION_TIMEOUT_US<1||CONVERSION_TIMEOUT_US>10000000;
 localparam IDLE=0,RESET_BUS=1,SEND_BYTE=2,POLL=3,READ_BYTE=4,CHECK=5,RESULT=6,DONE=7;
 reg[2:0]state;
 reg[DW-1:0]divider;
 (* ASYNC_REG="TRUE" *) reg[1:0]sync;
 reg[9:0]us;
 reg[31:0]read_cycles,conversion_cycles;
 reg match_mode,read_phase,presence,poll_bit;
 reg[63:0]rom;
 reg[3:0]select_index,byte_index;
 reg[2:0]bit_index;
 reg[7:0]tx_byte,rx_byte,crc,pending_error;
 wire tick=divider==DIV-1;
 wire reading=state==POLL||state==READ_BYTE;
 wire write_bit=tx_byte[bit_index];
 localparam [63:0] TIMEOUT_CYCLES=64'd1*CONVERSION_TIMEOUT_US*DIV;
 // Input synchronizer observation is two clocks after the physical sample.
 // A ready sample exactly at the deadline wins; later samples cannot rescue it.
 wire ready_now=state==POLL&&read_cycles==14*DIV+1&&sync[1]&&conversion_cycles<=TIMEOUT_CYCLES+1;
 wire conversion_timeout=state==POLL&&!poll_bit&&!ready_now&&conversion_cycles>=TIMEOUT_CYCLES+1;
 wire[7:0]fault=pending_error!=0?pending_error:(ce&&abort)?8'd6:conversion_timeout?8'd4:8'd0;
 assign start_ready=state==IDLE;
 assign busy=state!=IDLE&&state!=DONE;
 assign result_valid=state==RESULT;
 assign done_valid=state==DONE;
 function[7:0]crc_step;input[7:0]c;input b;begin crc_step=(c>>1)^((c[0]^b)?8'h8c:0);end endfunction
 task finish;input[7:0]code;begin state<=DONE;error_code<=code;ow_drive_low<=0;end endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;ow_drive_low<=0;divider<=0;sync<=3;us<=0;read_cycles<=0;conversion_cycles<=0;
   match_mode<=0;read_phase<=0;presence<=0;poll_bit<=0;rom<=0;
   select_index<=0;byte_index<=0;bit_index<=0;tx_byte<=0;rx_byte<=0;crc<=0;pending_error<=0;
   error_code<=0;temperature_q4<=0;resolution<=0;scratchpad<=0;
  end else begin
   sync<={sync[0],ow_in};
   if(tick)divider<=0;else divider<=divider+1'b1;
   if(reading)begin
    read_cycles<=read_cycles+1'b1;
    // Compensate two input synchronizer clocks: effective pin sample =14us,
    // before the DS18B20 read-data-valid15us deadline, even at DIV=1.
    if(read_cycles==14*DIV+1)begin
     if(state==POLL)poll_bit<=sync[1];
     else begin rx_byte<={sync[1],rx_byte[7:1]};crc<=crc_step(crc,sync[1]);end
    end
   end else read_cycles<=0;
   if(state==POLL&&!poll_bit&&conversion_cycles<TIMEOUT_CYCLES+2)conversion_cycles<=conversion_cycles+1'b1;
   if(busy&&pending_error==0)begin
    if(ce&&abort)pending_error<=6;
    else if(conversion_timeout)pending_error<=4;
   end
   case(state)
    IDLE:if(ce&&start_valid)begin
     match_mode<=cfg_match_rom;rom<=cfg_rom;read_phase<=0;presence<=0;
     divider<=0;us<=0;bit_index<=0;select_index<=0;byte_index<=0;
     conversion_cycles<=0;read_cycles<=0;rx_byte<=0;crc<=0;pending_error<=0;
     error_code<=0;temperature_q4<=0;resolution<=0;scratchpad<=0;
     if(BAD)finish(1);else if(!sync[1])finish(2);else begin state<=RESET_BUS;ow_drive_low<=1;end
    end
    RESET_BUS:if(tick)begin
     if(us==479)ow_drive_low<=0;
     if(us==550)presence<=!sync[1];
     if(us==959)begin
      us<=0;bit_index<=0;select_index<=0;
      if(fault!=0)finish(fault);
      else if(!sync[1])finish(2);
      else if(!presence)finish(3);
      else begin tx_byte<=match_mode?8'h55:8'hcc;state<=SEND_BYTE;ow_drive_low<=1;end
     end else us<=us+1'b1;
    end
    SEND_BYTE:if(tick)begin
     if(us==(write_bit?5:59))ow_drive_low<=0;
     if(us==69)begin
      us<=0;ow_drive_low<=fault==0&&sync[1];
      if(fault!=0)finish(fault);
      else if(!sync[1])finish(2);
      else if(bit_index!=7)bit_index<=bit_index+1'b1;
      else begin
       bit_index<=0;
       if(match_mode&&select_index<8)begin
        tx_byte<=rom[8*select_index +: 8];select_index<=select_index+1'b1;
       end else if(select_index!=(match_mode?9:1))begin
        tx_byte<=read_phase?8'hbe:8'h44;select_index<=match_mode?9:1;
       end else begin
        read_cycles<=0;rx_byte<=0;
        if(read_phase)begin state<=READ_BYTE;byte_index<=0;crc<=0;end
        else begin state<=POLL;conversion_cycles<=0;poll_bit<=0;end
       end
      end
     end else us<=us+1'b1;
    end
    POLL:if(tick)begin
     if(us==2)ow_drive_low<=0;
     if(us==69)begin
      us<=0;ow_drive_low<=fault==0&&sync[1];read_cycles<=0;
      if(fault!=0)finish(fault);
      else if(!sync[1])finish(2);
      else if(poll_bit)begin read_phase<=1;presence<=0;state<=RESET_BUS;end
     end else us<=us+1'b1;
    end
    READ_BYTE:if(tick)begin
     if(us==2)ow_drive_low<=0;
     if(us==69)begin
      us<=0;ow_drive_low<=fault==0&&sync[1]&&!(bit_index==7&&byte_index==8);read_cycles<=0;
      if(fault!=0)finish(fault);
      else if(!sync[1])finish(2);
      else if(bit_index!=7)bit_index<=bit_index+1'b1;
      else begin
       scratchpad[8*byte_index +: 8]<=rx_byte;bit_index<=0;rx_byte<=0;
       if(byte_index==8)begin state<=CHECK;ow_drive_low<=0;end else byte_index<=byte_index+1'b1;
      end
     end else us<=us+1'b1;
    end
    CHECK:begin
     if(fault!=0)finish(fault);
     else if(crc!=0)finish(5);
     else begin
      resolution<=scratchpad[38:37];
      case(scratchpad[38:37])
       0:temperature_q4<={scratchpad[15:3],3'b000};
       1:temperature_q4<={scratchpad[15:2],2'b00};
       2:temperature_q4<={scratchpad[15:1],1'b0};
       3:temperature_q4<=scratchpad[15:0];
      endcase
      state<=RESULT;
     end
    end
    RESULT:if(ce&&result_ready)finish(fault);
    DONE:if(ce&&done_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
