// External SCL1 packet -> bounded synchronous RAM -> scale_poly6_stream ->
// RAM -> UART.  Mirrors the image_harness store/replay/export pattern but
// with runtime dimensions and a 16-bit pixel count.
//
// Request (little-endian):
//   "SCL1" tag:u32 in_w:u16 in_h:u16 out_w:u16 out_h:u16 count:u16
//   stall:u8 pad:u8 then count*4 bytes (pixel u32, RGB in [23:0]).
//   count must equal in_w*in_h, 1<=count<=4096, widths<=MAXW_H, heights>0,
//   out_w*out_h<=4096.
// Response:
//   "SCR1" tag dims:u64 in_count:u16 out_count:u16 flags:u8 rsvd:u8
//   cycles:u32 then out_count*4 bytes; result bits31/30 = SOF/EOL.
// flags: bit0 bad dims/count/stall, bit1 rx framing, bit2 rx while busy,
//        bit3 cfg_error, bit4 watchdog, bit5 marker_error.
module scale_harness #(parameter MAXP=2048, MAXW_H=256)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
 reg [12:0] por=0;
 always @(posedge clk) if(!por[12]) por<=por+1'b1;
 wire rst_n=por[12];
 localparam LOAD=0,RESET=1,CONFIG=2,CFGWAIT=3,CHECK=4,PREFETCH=5,RUN=6,
            HEADER=7,READ=8,DATA=9;
 reg [3:0] state=LOAD;
 reg [7:0] index,stall,flags;
 reg [31:0] tag,cycles;
 reg [15:0] in_w,in_h,out_w,out_h,count;
 reg [12:0] input_count,output_count,read_index;
 reg [12:0] word_index;      // payload word index during LOAD
 reg [12:0] byte_index;      // export byte lane counter
 reg [1:0]  wbyte;           // word lane during LOAD assembly
 reg [31:0] assembly;
 reg [11:0] col;             // column of current replayed input pixel
 reg [2:0] phase;
 wire [31:0] input_q,output_q;
 wire [7:0] rx_data;
 wire rx_valid,rx_error;
 uart_rx #(.CLK_FRE(27),.BAUD_RATE(115200)) rx(
  .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.rx_pin(uart_rx_pin),
  .rx_data(rx_data),.rx_valid(rx_valid),.rx_ack(rx_valid),
  .framing_err(rx_error));

 // ---------------- DUT ----------------
 wire in_ready,out_valid,cfg_ready,cfg_error,cfg_done,marker_error;
 wire in_valid=state==RUN && input_count<count;
 wire out_ready=state==RUN && phase>=stall[2:0];
 wire input_fire=in_valid && in_ready;
 wire output_fire=out_valid && out_ready;
 wire core_reset=rst_n && state!=RESET;
 wire [23:0] pixel;
 wire sof,eol,busy;
 scale_poly6_stream #(.MAX_W(MAXW_H)) core(
  .clk(clk),.rst_n(core_reset),
  .s_tdata(input_q[23:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),
  .s_tlast(col==in_w-16'd1),.s_tready(in_ready),
  .m_tdata(pixel),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),
  .m_tready(out_ready),
  .cfg_valid(state==CONFIG),.cfg_ready(cfg_ready),
  .cfg_in_w(in_w[11:0]),.cfg_in_h(in_h[11:0]),
  .cfg_out_w(out_w[11:0]),.cfg_out_h(out_h[11:0]),
  .cfg_done(cfg_done),.cfg_error(cfg_error),.marker_error(marker_error),
  .busy(busy));
 wire [31:0] result={sof,eol,6'b0,pixel};

 // ---------------- stores ----------------
 // Present input_count while idle; +1 lookahead only during the take cycle.
 wire input_read=state==PREFETCH || in_valid;
 wire [11:0] input_address=state==PREFETCH ? 12'd0 :
     (input_fire ? input_count[11:0]+13'd1 : input_count[11:0]);
 wire input_write=rst_n && state==LOAD && rx_valid && !rx_error &&
                  index==8'd22 && wbyte==2'd3;
 reg [31:0] input_mem[0:MAXP-1];
 reg [31:0] input_qr;
 always @(posedge clk) begin
  if(input_write) input_mem[word_index[11:0]]<={rx_data,assembly[23:0]};
  if(input_read) input_qr<=input_mem[input_address];
 end
 assign input_q=input_qr;
 reg [31:0] output_mem[0:MAXP-1];
 reg [31:0] output_qr;
 always @(posedge clk) begin
  if(output_fire) output_mem[output_count[11:0]]<=result;
  if(state==READ) output_qr<=output_mem[read_index[11:0]];
 end
 assign output_q=output_qr;

 // ---------------- UART TX ----------------
 reg [7:0] tx_data;
 wire tx_ready;
 wire tx_valid=state==HEADER || state==DATA;
 uart_tx #(.CLK_FRE(27),.BAUD_RATE(115200)) tx(
  .clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),
  .tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
 assign dbg_uart=uart_tx;
 always @* begin
  tx_data=0;
  if(state==DATA) tx_data=output_q>>(8*byte_index[1:0]);
  else case(index)
   0:tx_data="S";1:tx_data="C";2:tx_data="R";3:tx_data="1";
   4,5,6,7:tx_data=tag>>(8*(index-4));
   8:tx_data=in_w[7:0]; 9:tx_data=in_w[15:8];
   10:tx_data=in_h[7:0]; 11:tx_data=in_h[15:8];
   12:tx_data=out_w[7:0]; 13:tx_data=out_w[15:8];
   14:tx_data=out_h[7:0]; 15:tx_data=out_h[15:8];
   16:tx_data=input_count[7:0]; 17:tx_data={3'd0,input_count[12:8]};
   18:tx_data=output_count[7:0]; 19:tx_data={3'd0,output_count[12:8]};
   20:tx_data=flags;21:tx_data=8'd0;
   22,23,24,25:tx_data=cycles>>(8*(index-22));
  endcase
 end

 // ---------------- FSM ----------------
 wire [31:0] in_total = {16'd0,in_w}*{16'd0,in_h};
 wire [31:0] out_total = {16'd0,out_w}*{16'd0,out_h};
 wire dims_ok = in_w!=0 && in_h!=0 && out_w!=0 && out_h!=0 &&
                in_w<=MAXW_H && out_w<=MAXW_H && in_h<=16'd256 &&
                out_h<=16'd256 &&
                count==in_total[15:0] && in_total<=MAXP &&
                out_total<=MAXP;
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=LOAD;index<=0;byte_index<=0;wbyte<=0;count<=0;stall<=0;flags<=0;
   tag<=0;cycles<=0;input_count<=0;output_count<=0;read_index<=0;phase<=0;
   col<=0;in_w<=0;in_h<=0;out_w<=0;out_h<=0;assembly<=0;word_index<=0;
  end else begin
   if(rx_error) flags[1]<=1;
   if(marker_error) flags[5]<=1;
   if(rx_valid && state!=LOAD) flags[2]<=1;
   case(state)
   LOAD: if(rx_valid && !rx_error) begin
    case(index)
    0: if(rx_data=="S") begin index<=1;flags<={5'd0,flags[2],2'd0};
        input_count<=0;output_count<=0;cycles<=0;end
    1: if(rx_data=="C") index<=2; else index<=0;
    2: if(rx_data=="L") index<=3; else index<=0;
    3: if(rx_data=="1") index<=4; else index<=0;
    4,5,6,7: begin tag<={rx_data,tag[31:8]};index<=index+8'd1;end
    8,9:   begin in_w <={rx_data,in_w[15:8]};index<=index+8'd1;end
    10,11: begin in_h <={rx_data,in_h[15:8]};index<=index+8'd1;end
    12,13: begin out_w<={rx_data,out_w[15:8]};index<=index+8'd1;end
    14,15: begin out_h<={rx_data,out_h[15:8]};index<=index+8'd1;end
    16,17: begin count<={rx_data,count[15:8]};index<=index+8'd1;end
    18:begin stall<=rx_data;index<=19;end
    19:begin index<=20;
     if(!dims_ok || rx_data!=8'd0 || stall[2:0]!=stall) begin
      flags[0]<=1;count<=0;index<=0;state<=HEADER;
     end else begin word_index<=0;wbyte<=0;index<=22;end
    end
    22:begin
     case(wbyte)
      0:assembly[7:0]<=rx_data;
      1:assembly[15:8]<=rx_data;
      2:assembly[23:16]<=rx_data;
      default:assembly[31:24]<=rx_data;
     endcase
     wbyte<=wbyte+2'd1;
     if(wbyte==2'd3) begin
      if(word_index==count[12:0]-13'd1) state<=RESET;
      word_index<=word_index+13'd1;
     end
    end
    default:index<=0;
    endcase
   end
   RESET:begin input_count<=0;output_count<=0;cycles<=0;phase<=0;col<=0;
    state<=CONFIG;end
   CONFIG:if(cfg_ready) state<=CFGWAIT;
   CFGWAIT:if(cfg_error) begin flags[3]<=1;count<=0;index<=0;state<=HEADER;end
           else if(cfg_done) state<=CHECK;
   CHECK:state<=PREFETCH;
   PREFETCH:state<=RUN;
   RUN:begin
    cycles<=cycles+32'd1;phase<=phase+3'd1;
    if(input_fire) begin
     input_count<=input_count+13'd1;
     if(col==in_w-16'd1) col<=0; else col<=col+12'd1;
    end
    if(output_fire) begin
     output_count<=output_count+13'd1;
     if(output_count+13'd1==out_total[12:0]) begin index<=0;state<=HEADER;end
    end
    if(cycles==32'd8000000) begin
     flags[4]<=1;index<=0;state<=HEADER;
    end
   end
   HEADER:if(tx_ready) begin
    if(index==25) begin read_index<=0;byte_index<=0;
     if(output_count==0) begin state<=LOAD;index<=0;end
     else state<=READ;
    end else index<=index+8'd1;
   end
   READ:state<=DATA;
   DATA:if(tx_ready) begin
    if(byte_index[1:0]==3) begin byte_index<=0;read_index<=read_index+13'd1;
     if(read_index+13'd1==output_count) begin state<=LOAD;index<=0;end
     else state<=READ;
    end else byte_index<=byte_index+13'd1;
   end
   default:state<=LOAD;
   endcase
  end
 end
endmodule
