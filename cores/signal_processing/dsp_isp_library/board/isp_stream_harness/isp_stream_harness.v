// External IMG1 packet -> bounded synchronous RAM -> ISP stream core -> RAM -> UART.
// Fork of the silicon-proven image_harness plumbing (GW2A CE-widening safe:
// fabric-reg small RAMs via block_ram MEM_IMPL, no-gap lookahead input reads).
// CORE selects the DUT branch; config_word selects a canned config where the
// core requires one. 8x8 frame, one packet per run.
//   CORE=0 median_stream   K3, PAD_MODE build param, no runtime config
//   CORE=1 convolution_stream K3; config_word[3:0] selects canned kernel
//   CORE=2 gradient_stream; config_word[1:0]={scharr,l1}, [17:5]=threshold;
//          odata packs grad_word[29:0] = {angle stuff, mag, gy, gx} low bits
//   CORE=5 chains/morph_median delivery bundle (morphology then median);
//          config_word[11:0] is morphology's {mask,binary,op}, as in CORE=3
module isp_stream_harness #(parameter CORE=0, parameter BITS=8, parameter PAD_MODE=1,
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
 wire in_ready,out_valid,cfg_ready,cfg_error,marker_error;
 wire [31:0] result;
 wire in_valid=state==RUN && input_count<count;
 wire out_ready=state==RUN && phase>=stall[2:0];
 wire input_fire=in_valid && in_ready;
 wire output_fire=out_valid && out_ready;
 wire core_reset=rst_n && state!=RESET;
 wire [29:0] odata;
 wire sof,eol;
 assign result={sof,eol,odata};

 generate
 if(CORE==0) begin: median
  median_stream #(.BITS(BITS),.WIDTH(8),.HEIGHT(8),.K(3),.PAD_MODE(PAD_MODE)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(odata[BITS-1:0]),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .marker_error(marker_error));
  assign odata[29:BITS]=0;
  assign cfg_ready=1'b1;
  assign cfg_error=|config_word;
 end else if(CORE==1) begin: conv
  reg [107:0] kcoeff;reg signed [31:0] kbias;reg [5:0] kshift;
  reg seen_done,seen_err;wire c_done,c_err;
  always @* begin
   case(config_word[3:0])
    4'd1:begin kcoeff={12'sd1,12'sd2,12'sd1,12'sd2,12'sd4,12'sd2,12'sd1,12'sd2,12'sd1};kbias=0;kshift=4;end
    4'd2:begin kcoeff={12'sd0,-12'sd1,12'sd0,-12'sd1,12'sd5,-12'sd1,12'sd0,-12'sd1,12'sd0};kbias=0;kshift=0;end
    4'd3:begin kcoeff={12'sd1,12'sd0,-12'sd1,12'sd2,12'sd0,-12'sd2,12'sd1,12'sd0,-12'sd1};kbias=0;kshift=0;end
    default:begin kcoeff={12'sd0,12'sd0,12'sd0,12'sd0,12'sd1,12'sd0,12'sd0,12'sd0,12'sd0};kbias=0;kshift=0;end
   endcase
  end
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:4]);
  assign cfg_error=seen_err | (|config_word[31:4]);
  convolution_stream #(.BITS(BITS),.WIDTH(8),.HEIGHT(8),.K(3),.PAD_MODE(PAD_MODE)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(odata[BITS-1:0]),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .cfg_valid(state==CONFIG),.cfg_ready(),.cfg_coeff(kcoeff),.cfg_bias(kbias),.cfg_shift(kshift),
   .cfg_done(c_done),.cfg_error(c_err),.marker_error(marker_error),.busy());
  assign odata[29:BITS]=0;
 end else if(CORE==2) begin: grad
  wire [3*(BITS+5)+4:0] grad_word;
  reg seen_done,seen_err;wire g_done,g_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(g_done)seen_done<=1;if(g_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:18]);
  assign cfg_error=seen_err | (|config_word[31:18]);
  gradient_stream #(.BITS(BITS),.WIDTH(8),.HEIGHT(8),.PAD_MODE(PAD_MODE)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(grad_word),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .cfg_valid(state==CONFIG),.cfg_ready(),.cfg_scharr(config_word[1]),.cfg_l1(config_word[0]),
   .cfg_threshold(config_word[17:5]),.cfg_reserved(2'b00),
   .cfg_done(g_done),.cfg_error(g_err),.marker_error(marker_error),.busy());
  assign odata=grad_word[29:0];
 end else if(CORE==3) begin: morph
  reg seen_done,seen_err;wire m_done,m_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(m_done)seen_done<=1;if(m_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:12]);
  assign cfg_error=seen_err | (|config_word[31:12]);
  morphology_stream #(.BITS(BITS),.WIDTH(8),.HEIGHT(8),.K(3),.PAD_MODE(PAD_MODE)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(odata[BITS-1:0]),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:12])),.cfg_ready(),
   .cfg_op(config_word[1:0]),.cfg_binary(config_word[2]),.cfg_mask(config_word[11:3]),
   .cfg_done(m_done),.cfg_error(m_err),.marker_error(marker_error),.busy());
  assign odata[29:BITS]=0;
 end else if(CORE==4) begin: bayer
  reg seen_done,seen_err;wire b_done,b_err;
  wire [3*BITS-1:0] bayer_tdata;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(b_done)seen_done<=1;if(b_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:4]);
  assign cfg_error=seen_err | (|config_word[31:4]);
  assign odata={{(30-3*BITS){1'b0}}, bayer_tdata};
  bayer_demosaic #(.BITS(BITS),.WIDTH(8),.HEIGHT(8)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(bayer_tdata),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:4])),.cfg_ready(),
   .cfg_cfa(config_word[1:0]),.cfg_ox(config_word[2]),.cfg_oy(config_word[3]),.cfg_reserved(config_word[7:4]),
   .cfg_done(b_done),.cfg_error(b_err),.marker_error(marker_error),.busy());
 end else if(CORE==5) begin: morph_median
  // Delivery bundle: morphology feeding a median denoise.  Configuration is
  // morphology's; the median stage takes none, so the legality test and the
  // cfg_valid gate are identical to the CORE==3 branch.
  reg seen_done,seen_err;wire mm_done,mm_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(mm_done)seen_done<=1;if(mm_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:12]);
  assign cfg_error=seen_err | (|config_word[31:12]);
  morph_median_stream #(.BITS(BITS),.WIDTH(8),.HEIGHT(8),.K(3),.PAD_MODE(PAD_MODE)) core(
   .clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[BITS-1:0]),.s_tvalid(in_valid),.s_tuser(input_count==0),.s_tlast(input_count[2:0]==7),.s_tready(in_ready),
   .m_tdata(odata[BITS-1:0]),.m_tvalid(out_valid),.m_tuser(sof),.m_tlast(eol),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:12])),.cfg_ready(),
   .cfg_op(config_word[1:0]),.cfg_binary(config_word[2]),.cfg_mask(config_word[11:3]),
   .cfg_done(mm_done),.cfg_error(mm_err),.marker_error(marker_error),.busy());
  assign odata[29:BITS]=0;
 end else begin: bad
  assign in_ready=1'b0;assign out_valid=1'b0;assign cfg_ready=1'b0;assign cfg_error=1'b1;
  assign marker_error=1'b0;assign odata=30'b0;assign sof=1'b0;assign eol=1'b0;
 end
 endgenerate

 // Dedicated synchronous RAM processes: never reset storage.
 // Present input_count while idle; +1 lookahead only during the take cycle.
 wire input_read=state==PREFETCH || in_valid;
 wire [5:0] input_address=state==PREFETCH ? 6'd0 :
     (input_fire ? input_count[5:0]+6'd1 : input_count[5:0]);
 wire input_write=rst_n && state==LOAD && rx_valid && !rx_error && index>=14 && byte_index[1:0]==3;
 block_ram #(.MEM_IMPL(0)) input_store(.clk(clk),.we(input_write),.waddr(byte_index[7:2]),.wdata({rx_data,assembly[23:0]}),.re(input_read),.raddr(input_address),.q(input_q));
 block_ram #(.MEM_IMPL(0)) output_store(.clk(clk),.we(output_fire),.waddr(output_count[5:0]),.wdata(result),.re(state==READ),.raddr(read_index[5:0]),.q(output_q));
 reg [7:0] tx_data;
 wire tx_ready;
 wire tx_valid=state==HEADER || state==DATA;
 uart_tx #(.CLK_FRE(CLK_FRE)) tx(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),.tx_data_ready(tx_ready),.tx_pin(uart_tx),.tx_busy());
 assign dbg_uart=uart_tx;
 always @* begin
 tx_data=0;
 if(state==DATA) tx_data=output_q>>(8*byte_index[1:0]);
 else case(index)
 0:tx_data="I";1:tx_data="M";2:tx_data="R";3:tx_data="1";
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
 if(marker_error) flags[5]<=1;
 if(rx_valid && state!=LOAD) flags[2]<=1;
 case(state)
 LOAD: if(rx_valid && !rx_error) begin
 case(index)
 0: if(rx_data=="I") begin index<=1;flags<={5'd0,flags[2],2'd0};input_count<=0;output_count<=0;cycles<=0;end
 1: if(rx_data=="M") index<=2;else index<=0;
 2: if(rx_data=="G") index<=3;else index<=0;
 3: if(rx_data=="1") index<=4;else index<=0;
 4,5,6,7: begin tag<={rx_data,tag[31:8]};index<=index+1'b1;end
 8,9,10,11: begin config_word<={rx_data,config_word[31:8]};index<=index+1'b1;end
 12:begin count<=rx_data;index<=13;end
 13:begin stall<=rx_data;index<=14;byte_index<=0;
 if(count!=64 || rx_data>7) begin flags[0]<=1;count<=0;index<=0;state<=HEADER;end
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
 CHECK:if(cfg_error) begin flags[3]<=1;count<=0;index<=0;state<=HEADER;end else state<=PREFETCH;
 PREFETCH:state<=RUN;
 RUN:begin
 cycles<=cycles+1'b1;phase<=phase+1'b1;
 if(input_fire) input_count<=input_count+1'b1;
 if(output_fire) begin output_count<=output_count+1'b1;if(output_count+1==count) begin index<=0;state<=HEADER;end end
 if(cycles==32'd16383) begin flags[4]<=1;count<=output_count+(output_fire?1'b1:1'b0);index<=0;state<=HEADER;end
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
