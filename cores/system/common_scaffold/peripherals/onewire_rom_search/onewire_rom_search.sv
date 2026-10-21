// Search ROM (F0), standard-speed open-drain OneWire. No electrical PHY claim.
module onewire_rom_search #(
 parameter CLK_HZ=27000000,MAX_DEVICES=16,TOTAL_TIMEOUT_US=2000000
)(input wire clk,rst_n,ce,start_valid,abort,ow_in,
 output wire start_ready,output wire ow_drive_low,
 output reg[63:0]rom_data,output wire rom_valid,input wire rom_ready,
 output wire rom_last,output reg[15:0]device_count,output reg no_devices,
 output wire busy,output wire done_valid,input wire done_ready,output reg[7:0]error_code);
 localparam IDLE=0,RESET_BUS=1,COMMAND=2,READ_ID=3,READ_COMP=4,CHOOSE=5,WRITE_DIR=6,RESULT=7,DONE=8;
 localparam DIV=(CLK_HZ+999999)/1000000,DW=DIV<2?1:$clog2(DIV);
 localparam BAD=CLK_HZ<1000000||CLK_HZ>250000000||CLK_HZ%1000000!=0||MAX_DEVICES<1||MAX_DEVICES>65535||TOTAL_TIMEOUT_US<1000||TOTAL_TIMEOUT_US>100000000;
 reg[3:0]state;reg[DW-1:0]divider;reg[1:0]sync;
 reg[15:0]read_cycles;reg[9:0]us;reg[31:0]elapsed;reg presence,id_bit,comp_bit,direction;
 reg[2:0]cmd_bit;reg[5:0]bit_index;reg[6:0]last_discrepancy,last_zero;
 reg[63:0]previous;reg[7:0]crc,pending_error;
 wire tick=divider==DIV-1;
 wire slot=state==COMMAND||state==READ_ID||state==READ_COMP||state==WRITE_DIR;
 wire write_bit=state==COMMAND?(cmd_bit>=4):direction;
 assign ow_drive_low=rst_n&&((state==RESET_BUS&&us<480)||(slot&&us<((state==READ_ID||state==READ_COMP)?3:(write_bit?6:60))));
 assign start_ready=state==IDLE;assign busy=state!=IDLE&&state!=DONE;
 assign rom_valid=state==RESULT;assign rom_last=last_zero==0;
 assign done_valid=state==DONE;
 function[7:0] crc_step;input[7:0]c;input b;begin crc_step=(c>>1)^((c[0]^b)?8'h8c:8'h00);end endfunction
 task finish;input[7:0]code;begin state<=DONE;error_code<=code;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;divider<=0;read_cycles<=0;sync<=3;us<=0;elapsed<=0;presence<=0;id_bit<=0;comp_bit<=0;direction<=0;cmd_bit<=0;bit_index<=0;last_discrepancy<=0;last_zero<=0;previous<=0;rom_data<=0;crc<=0;pending_error<=0;device_count<=0;no_devices<=0;error_code<=0;end
 else begin
 sync<={sync[0],ow_in};
 if(state==READ_ID||state==READ_COMP)begin
  read_cycles<=read_cycles+1'b1;
  // Decision compensates2FF latency; effective physical pin sample is14us.
  if(read_cycles==14*DIV+1)begin if(state==READ_ID)id_bit<=sync[1];else comp_bit<=sync[1];end
 end else read_cycles<=0;
 if(tick)divider<=0;else divider<=divider+1'b1;
 if(busy&&tick&&elapsed<TOTAL_TIMEOUT_US)elapsed<=elapsed+1'b1;
 if(busy&&elapsed>=TOTAL_TIMEOUT_US&&pending_error==0)pending_error<=6;
 if(busy&&ce&&abort&&pending_error==0)pending_error<=7;
 if(state==DONE&&ce&&done_ready)state<=IDLE;
 if(state==IDLE&&ce&&start_valid)begin
  us<=0;elapsed<=0;presence<=0;cmd_bit<=0;bit_index<=0;last_discrepancy<=0;last_zero<=0;previous<=0;rom_data<=0;crc<=0;pending_error<=0;device_count<=0;no_devices<=0;error_code<=0;divider<=0;
  if(BAD)finish(1);else if(!sync[1])finish(2);else state<=RESET_BUS;
 end else if(busy)begin
  // An exposed result remains irrevocable, including timeout/abort.
  if(state==RESULT)begin
   if(ce&&rom_ready)begin
    device_count<=device_count+1'b1;
    if(pending_error!=0)finish(pending_error);
    else if(elapsed>=TOTAL_TIMEOUT_US)finish(6);
    else if(ce&&abort)finish(7);
    else if(last_zero==0)finish(0);
    else if(device_count+1>=MAX_DEVICES)finish(5);
    else begin previous<=rom_data;last_discrepancy<=last_zero;last_zero<=0;bit_index<=0;crc<=0;presence<=0;us<=0;divider<=0;state<=RESET_BUS;end
   end
  end else if(pending_error!=0)finish(pending_error);
  else if(ce&&abort)finish(7);
  else if(state==CHOOSE)begin
   if(id_bit&&comp_bit)finish(3);
   else begin
    if(id_bit!=comp_bit)begin direction<=id_bit;rom_data[bit_index]<=id_bit;crc<=crc_step(crc,id_bit);end
    else if(bit_index+1<last_discrepancy)begin direction<=previous[bit_index];rom_data[bit_index]<=previous[bit_index];crc<=crc_step(crc,previous[bit_index]);if(!previous[bit_index])last_zero<=bit_index+1'b1;end
    else if(bit_index+1==last_discrepancy)begin direction<=1;rom_data[bit_index]<=1;crc<=crc_step(crc,1);end
    else begin direction<=0;rom_data[bit_index]<=0;crc<=crc_step(crc,0);last_zero<=bit_index+1'b1;end
    us<=0;divider<=0;state<=WRITE_DIR;
   end
  end else if(tick)begin
   if(state==RESET_BUS)begin
    if(us==550)presence<=!sync[1];
    if(us==959)begin
     us<=0;
     if(!sync[1])finish(2);
     else if(!presence)begin if(device_count==0)begin no_devices<=1;finish(0);end else finish(8);end
     else begin state<=COMMAND;cmd_bit<=0;end
    end else us<=us+1'b1;
   end else if(slot)begin
    if(us==69)begin
     us<=0;read_cycles<=0;
     if(!sync[1])finish(2);
     else if(state==COMMAND)begin if(cmd_bit==7)state<=READ_ID;else cmd_bit<=cmd_bit+1'b1;end
     else if(state==READ_ID)state<=READ_COMP;
     else if(state==READ_COMP)state<=CHOOSE;
     else if(bit_index==63)begin if(crc!=0)finish(4);else state<=RESULT;end
     else begin bit_index<=bit_index+1'b1;state<=READ_ID;end
    end else us<=us+1'b1;
   end
  end
 end
 end end
endmodule
