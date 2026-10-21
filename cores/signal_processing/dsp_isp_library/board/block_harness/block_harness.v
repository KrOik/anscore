// External packet -> bounded synchronous RAM -> real algorithm -> RAM -> UART.
module block_harness #(parameter CORE=0, BITS=8, MEM_IMPL=0,
 parameter integer CLK_FRE=27)(
 input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
 reg [12:0] por=0;
 always @(posedge clk) if(!por[12]) por<=por+1'b1;
 wire rst_n=por[12];
 localparam LOAD=0,RESET=1,CONFIG=2,CHECK=3,PREFETCH=4,RUN=5,HEADER=6,READ=7,DATA=8;
 reg [3:0] state=LOAD;
 reg [7:0] index,byte_index,count,stall,flags;
 reg [31:0] tag,config_word,assembly,cycles;
 reg [6:0] input_count,output_count,read_index;
 reg [2:0] phase;
 wire [31:0] input_q,output_q;
 wire [7:0] rx_data;
 wire rx_valid,rx_error;
 uart_rx #(.CLK_FRE(CLK_FRE)) rx(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.rx_pin(uart_rx_pin),.rx_data(rx_data),.rx_valid(rx_valid),.rx_ack(rx_valid),.framing_err(rx_error));
 wire in_ready,out_valid,cfg_ready,cfg_error;
 wire [31:0] result;
 wire in_valid=state==RUN && input_count<count;
 wire out_ready=state==RUN && phase>=stall[2:0];
 wire input_fire=in_valid && in_ready;
 wire output_fire=out_valid && out_ready;
 wire core_reset=rst_n && state!=RESET;
 generate if(CORE==0) begin: dc
 dc_stream core(.clk(clk),.rst_n(core_reset),.s_tdata(input_q[15:0]),.s_tvalid(in_valid),.s_tready(in_ready),.m_tdata(result),.m_tvalid(out_valid),.m_tready(out_ready),.cfg_valid(state==CONFIG),.cfg_ready(cfg_ready),.cfg_mode(config_word[1:0]),.cfg_pole(config_word[17:2]),.cfg_window_log2(config_word[21:18]),.cfg_done(),.cfg_error(cfg_error));
 end else if(CORE==1) begin: csc
 wire [3*BITS-1:0] color;
 wire sof,eol;
 csc_stream #(.BITS(BITS)) core(.clk(clk),.rst_n(core_reset),.s_tdata(input_q[3*BITS-1:0]),.s_tvalid(in_valid),.s_tready(in_ready),.s_tuser(input_count==0),.s_tlast(input_count==count-1),.m_tdata(color),.m_tvalid(out_valid),.m_tready(out_ready),.m_tuser(sof),.m_tlast(eol),.cfg_valid(state==CONFIG),.cfg_ready(cfg_ready),.cfg_mode(config_word[3:2]),.cfg_standard(config_word[1]),.cfg_limited(config_word[0]),.cfg_error(cfg_error));
 assign result={sof,eol,{(30-3*BITS){1'b0}},color};
 end else begin: identity
 reg [31:0] data;
 reg valid;
 assign in_ready=!valid || out_ready;
 assign out_valid=valid;
 assign result=data;
 assign cfg_ready=1'b1;
 assign cfg_error=1'b0;
 always @(posedge clk) begin
 if(!core_reset) begin valid<=0;data<=0;end
 else if(in_ready) begin valid<=in_valid;if(in_valid) data<=input_q;end
 end
 end endgenerate
 // Dedicated synchronous RAM processes: never reset storage.
 // Present input_count while idle; +1 lookahead only during the take cycle.
 wire input_read=state==PREFETCH || in_valid;
 wire [5:0] input_address=state==PREFETCH ? 6'd0 :
     (input_fire ? input_count[5:0]+6'd1 : input_count[5:0]);
 wire input_write=rst_n && state==LOAD && rx_valid && !rx_error && index>=14 && byte_index[1:0]==3;
 block_ram #(.MEM_IMPL(MEM_IMPL)) input_store(.clk(clk),.we(input_write),.waddr(byte_index[7:2]),.wdata({rx_data,assembly[23:0]}),.re(input_read),.raddr(input_address),.q(input_q));
 block_ram #(.MEM_IMPL(MEM_IMPL)) output_store(.clk(clk),.we(output_fire),.waddr(output_count[5:0]),.wdata(result),.re(state==READ),.raddr(read_index[5:0]),.q(output_q));
 reg [7:0] tx_data;
 wire tx_ready;
 wire tx_valid=state==HEADER || state==DATA;
 uart_tx #(.CLK_FRE(CLK_FRE)) tx(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),.tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
 assign dbg_uart=uart_tx;
 always @* begin
 tx_data=0;
 if(state==DATA) tx_data=output_q>>(8*byte_index[1:0]);
 else case(index)
 0:tx_data="R";1:tx_data="E";2:tx_data="S";3:tx_data="1";
 4,5,6,7:tx_data=tag>>(8*(index-4));
 8,9,10,11:tx_data=config_word>>(8*(index-8));
 12:tx_data=count;13:tx_data=flags;14:tx_data={1'b0,input_count};15:tx_data={1'b0,output_count};
 16,17,18,19:tx_data=cycles>>(8*(index-16));
 endcase
 end
 always @(posedge clk) begin
 if(!rst_n) begin state<=LOAD;index<=0;byte_index<=0;count<=0;stall<=0;flags<=0;tag<=0;config_word<=0;assembly<=0;cycles<=0;input_count<=0;output_count<=0;read_index<=0;phase<=0;end
 else begin
 if(rx_error) flags[1]<=1;
 if(rx_valid && state!=LOAD) flags[2]<=1;
 case(state)
 LOAD: if(rx_valid && !rx_error) begin
 case(index)
 0: if(rx_data=="B") begin index<=1;flags<={5'd0,flags[2],2'd0};input_count<=0;output_count<=0;cycles<=0;end
 1: if(rx_data=="L") index<=2;else index<=0;
 2: if(rx_data=="K") index<=3;else index<=0;
 3: if(rx_data=="1") index<=4;else index<=0;
 4,5,6,7: begin tag<={rx_data,tag[31:8]};index<=index+1'b1;end
 8,9,10,11: begin config_word<={rx_data,config_word[31:8]};index<=index+1'b1;end
 12:begin count<=rx_data;index<=13;end
 13:begin stall<=rx_data;index<=14;byte_index<=0;
 if(count==0 || count>64 || rx_data>7) begin flags[0]<=1;count<=0;index<=0;state<=HEADER;end
 end
 default:begin
 byte_index<=byte_index+1'b1;
 if(byte_index[1:0]==0) assembly[7:0]<=rx_data;
 if(byte_index[1:0]==1) assembly[15:8]<=rx_data;
 if(byte_index[1:0]==2) assembly[23:16]<=rx_data;
 if(byte_index=={count[5:0],2'b00}-1'b1) state<=RESET;
 end
 endcase
 end
 RESET:begin input_count<=0;output_count<=0;cycles<=0;phase<=0;state<=CONFIG;end
 CONFIG:if(cfg_ready) state<=CHECK;
 CHECK:if(cfg_error || (CORE==0 && config_word[31:22]!=0) || (CORE==1 && config_word[31:4]!=0) || (CORE==2 && config_word!=0)) begin flags[3]<=1;count<=0;index<=0;state<=HEADER;end else state<=PREFETCH;
 PREFETCH:state<=RUN;
 RUN:begin
 cycles<=cycles+1'b1;phase<=phase+1'b1;
 if(input_fire) input_count<=input_count+1'b1;
 if(output_fire) begin output_count<=output_count+1'b1;if(output_count+1==count) begin index<=0;state<=HEADER;end end
 if(cycles==32'd4095) begin flags[4]<=1;count<=output_count+(output_fire?1'b1:1'b0);index<=0;state<=HEADER;end
 end
 HEADER:if(tx_ready) begin if(index==19) begin read_index<=0;byte_index<=0;if(count==0) begin state<=LOAD;index<=0;end else state<=READ;end else index<=index+1'b1;end
 READ:state<=DATA;
 DATA:if(tx_ready) begin
 if(byte_index[1:0]==3) begin byte_index<=0;read_index<=read_index+1'b1;
 if(read_index+1==count) begin state<=LOAD;index<=0;end else state<=READ;
 end else byte_index<=byte_index+1'b1;
 end
 default:state<=LOAD;
 endcase
 end
 end
endmodule
