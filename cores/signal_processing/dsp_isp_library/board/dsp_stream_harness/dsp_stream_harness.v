// External BLK1 packet -> bounded synchronous RAM -> DSP stream core -> RAM -> UART.
// Same proven plumbing contract as block_harness (RES1 reports, stall replay,
// watchdog).  CORE selects the DUT; config_word maps to each core's config
// fields; out-of-range bits are rejected at CHECK like the reference harness.
//   CORE=0 farrow_cubic_stream  cfg={delay[5:0],mu[18:6],clear[19]}
//   CORE=1 agc_stream           cfg={target[6:0],attack[10:7],release[14:11],
//                                  est[18:15],mode[19],mute[20],bypass[21],clear[22]}
//                               (gmin=-96,gmax=32 fixed by adapter)
//   CORE=2 biquad_sos_stream    config_word[1:0] selects canned SOS table,
//                               config_word[2]=cfg_clear
//   CORE=3 lms_stream (serial)  cfg={mu[15:0],nlms[16],update_en[17],
//                                  taps[22:18],coef_clr[23]}; floor=64 fixed
//   CORE=4 mag_squared          cfg_shift=config_word[4:0]
//   CORE=5 agc_power_stream     cfg={power_shift[27:23],AGC control[22:0]}
//                               (gmin=-96,gmax=32 fixed by the bundle)
module dsp_stream_harness #(parameter CORE=0, parameter integer CLK_FRE=27,
 parameter MEM_IMPL=1)(
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

 generate
 if(CORE==0) begin: g_farrow
  wire [15:0] fd;wire fu;
  reg seen_done,seen_err;wire c_done,c_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:20]);
  assign cfg_error=seen_err | (|config_word[31:20]);
  assign result={15'b0,fu,fd};
  farrow_cubic_stream core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[15:0]),.s_tvalid(in_valid),.s_tready(in_ready),
   .m_tdata(fd),.m_tvalid(out_valid),.m_tready(out_ready),.m_tuser(fu),
   .cfg_valid(state==CONFIG && !(|config_word[31:20])),.cfg_ready(),
   .cfg_delay(config_word[5:0]),.cfg_mu(config_word[18:6]),.cfg_clear(config_word[19]),
   .cfg_done(c_done),.cfg_error(c_err));
 end else if(CORE==1) begin: g_agc
  wire [15:0] ad;wire au,al;
  reg seen_done,seen_err;wire c_done,c_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:23]);
  assign cfg_error=seen_err | (|config_word[31:23]);
  assign result={al,au,14'b0,ad};
  agc_stream core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[15:0]),.s_tvalid(in_valid),.s_tready(in_ready),
   .s_tuser(input_count==0),.s_tlast(input_count==count-1),
   .m_tdata(ad),.m_tuser(au),.m_tlast(al),.m_tvalid(out_valid),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:23])),.cfg_ready(),
   .cfg_target(config_word[6:0]),.cfg_gmin(-9'sd96),.cfg_gmax(9'sd32),
   .cfg_attack(config_word[10:7]),.cfg_release(config_word[14:11]),.cfg_est(config_word[18:15]),
   .cfg_mode(config_word[19]),.cfg_mute(config_word[20]),.cfg_bypass(config_word[21]),
   .cfg_clear(config_word[22]),
   .cfg_done(c_done),.cfg_error(c_err),.clip_sticky(),.env_code(),.gain_code());
 end else if(CORE==2) begin: g_biquad
  reg seen_done,seen_err;wire c_done,c_err;
  // Canned signed18 Q3.15 sections; must match CANNED_SOS in protocol.py.
  // Table selected by config_word[1:0]; each entry packs b0,b1,b2,a1,a2
  // at [k*90+0/18/36/54/72] per section, identity padding after.
  reg [359:0] ktable;reg [2:0] ksec;
  `include "dsp_stream_harness_biquad_rom.vh"
  always @* begin
   case(config_word[1:0])
    4'd1:begin ktable=KT1;ksec=KS1;end
    4'd2:begin ktable=KT2;ksec=KS2;end
    4'd3:begin ktable=KT3;ksec=KS3;end
    default:begin ktable=KT0;ksec=KS0;end
   endcase
  end
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:3]);
  assign cfg_error=seen_err | (|config_word[31:3]);
  biquad_sos_stream #(.MAX_SOS(4)) core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q[15:0]),.s_tvalid(in_valid),.s_tready(in_ready),
   .m_tdata(result[15:0]),.m_tuser(result[16]),.m_tvalid(out_valid),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:3])),.cfg_ready(),
   .cfg_sections(ksec),.cfg_clear(config_word[2]),.cfg_coeffs(ktable),
   .cfg_done(c_done),.cfg_error(c_err));
  assign result[31:17]=0;
 end else if(CORE==3) begin: g_lms
  reg seen_done,seen_err;wire c_done,c_err;
  wire taps_bad=(config_word[22:18]==0)||(config_word[22:18]>8);
  wire cfg_bad=(|config_word[31:24])|taps_bad;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | cfg_bad;
  assign cfg_error=seen_err | cfg_bad;
  lms_stream #(.NTAPS(8),.IMPL(0),.MULT_DSP(1)) core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q),.s_tvalid(in_valid),.s_tready(in_ready),
   .m_tdata(result),.m_tuser(),.m_tvalid(out_valid),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !cfg_bad),.cfg_ready(),
   .cfg_taps({2'b00,config_word[22:18]}),.cfg_mu(config_word[15:0]),
   .cfg_nlms(config_word[16]),.cfg_update_en(config_word[17]),
   .cfg_floor(20'd64),.cfg_coef_clr(config_word[23]),
   .cfg_done(c_done),.cfg_error(c_err),
   .cw_en(1'b0),.cw_addr(7'b0),.cw_data(24'sd0),
   .rb_en(1'b0),.rb_addr(7'b0),.rb_valid(),.rb_data());
 end else if(CORE==4) begin: g_mag
  reg seen_done,seen_err;wire c_done,c_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:5]);
  assign cfg_error=seen_err | (|config_word[31:5]);
  mag_squared core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q),.s_tvalid(in_valid),.s_tready(in_ready),
   .m_tdata(result),.m_tuser(),.m_tvalid(out_valid),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:5])),.cfg_ready(),
   .cfg_shift(config_word[4:0]),.cfg_done(c_done),.cfg_error(c_err));
 end else if(CORE==5) begin: g_agc_power
  // Delivery bundle: two AGC lanes (I=s_tdata[15:0], Q=s_tdata[31:16]) feeding
  // mag_squared.  The report word is the 32-bit power, so no marker bits ride on
  // it -- the magnitude stage's m_tuser is its saturation flag, which signed16
  // inputs cannot reach.
  reg seen_done,seen_err;wire c_done,c_err;
  always @(posedge clk) begin
   if(!core_reset) begin seen_done<=0;seen_err<=0;end
   else begin if(c_done)seen_done<=1;if(c_err)seen_err<=1;end
  end
  assign cfg_ready=seen_done | (|config_word[31:28]);
  assign cfg_error=seen_err | (|config_word[31:28]);
  agc_power_stream core(.clk(clk),.rst_n(core_reset),
   .s_tdata(input_q),.s_tvalid(in_valid),
   .s_tuser(input_count==0),.s_tlast(input_count==count-1),.s_tready(in_ready),
   .m_tdata(result),.m_tuser(),.m_tvalid(out_valid),.m_tready(out_ready),
   .cfg_valid(state==CONFIG && !(|config_word[31:28])),.cfg_ready(),
   .cfg_word(config_word[27:0]),.cfg_done(c_done),.cfg_error(c_err));
 end else begin: bad
  assign in_ready=1'b0;assign out_valid=1'b0;assign cfg_ready=1'b1;assign cfg_error=1'b1;
  assign result=32'b0;
 end
 endgenerate

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
 CHECK:if(cfg_error) begin flags[3]<=1;count<=0;index<=0;state<=HEADER;end else state<=PREFETCH;
 PREFETCH:state<=RUN;
 RUN:begin
 cycles<=cycles+1'b1;phase<=phase+1'b1;
 if(input_fire) input_count<=input_count+1'b1;
 if(output_fire) begin output_count<=output_count+1'b1;if(output_count+1==count) begin index<=0;state<=HEADER;end end
 if(cycles==32'd65535) begin flags[4]<=1;count<=output_count+(output_fire?1'b1:1'b0);index<=0;state<=HEADER;end
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
