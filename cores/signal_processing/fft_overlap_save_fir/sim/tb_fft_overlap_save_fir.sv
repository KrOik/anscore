`timescale 1ns/1ps
module tb_fft_overlap_save_fir;
 parameter integer LN=3,DW=12,TW=8,WRAPPER=0;
 localparam integer N=1<<LN;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,g_valid=0,k_valid=0,r_ready=0,c_valid=0,s_valid=0,m_ready=0;
 reg [31:0] g_taps=0,g_frac=0,c_count=0;
 reg [TW-1:0] g_tag=0,c_tag=0;
 reg signed [DW-1:0] k_re=0,k_im=0,s_re=0,s_im=0;
 reg k_last=0,k_invalid=0,c_end=0,c_restart=0,s_last=0,s_invalid=0;
 wire g_ready,k_ready,r_valid,c_ready,s_ready,m_valid,m_keep,m_last,m_error;
 wire r_overflow,r_inexact,m_overflow,m_inexact,busy;
 wire [3:0] r_status,m_status;
 wire [31:0] r_taps,r_frac,r_received,m_count,m_total,m_received;
 wire [TW-1:0] r_tag,m_tag;
 wire signed [DW-1:0] m_re,m_im;
 wire [LN-1:0] m_index;
 wire [5:0] phase_state;
 generate if(WRAPPER)begin:real_case
  real_fft_overlap_save_fir #(.LOG_N(LN),.DATA_W(DW),.TAG_W(TW)) dut (
   .clk(clk),.rst(rst),.g_valid(g_valid),.g_ready(g_ready),.g_taps(g_taps),.g_frac(g_frac),.g_tag(g_tag),
   .k_valid(k_valid),.k_ready(k_ready),.k_data(k_re),.k_last(k_last),.k_invalid(k_invalid),
   .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_taps(r_taps),.r_frac(r_frac),
   .r_received(r_received),.r_overflow(r_overflow),.r_inexact(r_inexact),.r_tag(r_tag),
   .c_valid(c_valid),.c_ready(c_ready),.c_count(c_count),.c_end(c_end),.c_restart(c_restart),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_re),.s_last(s_last),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_data(m_re),.m_im_residual(m_im),
   .m_keep(m_keep),.m_last(m_last),.m_error(m_error),.m_status(m_status),
   .m_overflow(m_overflow),.m_inexact(m_inexact),.m_index(m_index),
   .m_count(m_count),.m_total(m_total),.m_received(m_received),.m_tag(m_tag),.busy(busy));
  assign phase_state=dut.filter.state;
 end else begin:complex_case
  fft_overlap_save_fir #(.LOG_N(LN),.DATA_W(DW),.TAG_W(TW)) dut (
   .clk(clk),.rst(rst),.g_valid(g_valid),.g_ready(g_ready),.g_taps(g_taps),.g_frac(g_frac),.g_tag(g_tag),
   .k_valid(k_valid),.k_ready(k_ready),.k_re(k_re),.k_im(k_im),.k_last(k_last),.k_invalid(k_invalid),
   .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_taps(r_taps),.r_frac(r_frac),
   .r_received(r_received),.r_overflow(r_overflow),.r_inexact(r_inexact),.r_tag(r_tag),
   .c_valid(c_valid),.c_ready(c_ready),.c_count(c_count),.c_end(c_end),.c_restart(c_restart),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_re(s_re),.s_im(s_im),.s_last(s_last),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_re(m_re),.m_im(m_im),
   .m_keep(m_keep),.m_last(m_last),.m_error(m_error),.m_status(m_status),
   .m_overflow(m_overflow),.m_inexact(m_inexact),.m_index(m_index),
   .m_count(m_count),.m_total(m_total),.m_received(m_received),.m_tag(m_tag),.busy(busy));
  assign phase_state=dut.state;
 end endgenerate

 integer cycles=0,configs=0,commands=0,taps_seen=0,samples=0,outputs=0,markers=0;
 integer resets=0,directed_resets=0,holds=0;
 reg count_enable=0,m_held=0,r_held=0;
 reg [511:0] saved_m;
 reg [255:0] saved_r;
 wire [511:0] m_bundle={m_re,m_im,m_keep,m_last,m_error,m_status,m_overflow,m_inexact,
                       m_index,m_count,m_total,m_received,m_tag};
 wire [255:0] r_bundle={r_status,r_taps,r_frac,r_received,r_overflow,r_inexact,r_tag};
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>40000000)$fatal(1,"HDL watchdog");
  if(rst)begin
   if(g_ready||c_ready||k_ready||s_ready||r_valid||m_valid)$fatal(1,"reset handshake leak");
   m_held<=0;r_held<=0;
  end else begin
   if(m_held&&(!m_valid||(m_bundle!==saved_m)))$fatal(1,"stalled output changed");
   if(r_held&&(!r_valid||(r_bundle!==saved_r)))$fatal(1,"stalled configuration reply changed");
   m_held<=m_valid&&!m_ready;r_held<=r_valid&&!r_ready;
   if(m_valid&&!m_ready)begin saved_m<=m_bundle;holds=holds+1;end
   if(r_valid&&!r_ready)begin saved_r<=r_bundle;holds=holds+1;end
   if(count_enable)begin
    if(g_valid&&g_ready)configs=configs+1;
    if(c_valid&&c_ready)commands=commands+1;
    if(k_valid&&k_ready)taps_seen=taps_seen+1;
    if(s_valid&&s_ready)samples=samples+1;
    if(m_valid&&m_ready)begin if(m_keep)outputs=outputs+1;else markers=markers+1;end
   end
  end
 end

 task send_g(input integer nt,input integer nf,input integer tag_value);
  begin
   @(negedge clk);g_taps=nt;g_frac=nf;g_tag=tag_value;g_valid=1;
   c_valid=1;c_count=32'hffffffff;c_tag=~tag_value;
   while(!g_ready)@(negedge clk);
   @(posedge clk);if(c_ready)$fatal(1,"configuration priority failed");
   @(negedge clk);g_valid=0;c_valid=0;g_taps=32'hffffffff;g_frac=31;g_tag=~tag_value;
  end
 endtask
 task send_k(input integer re_value,input integer im_value,input integer last_value,input integer invalid_value);
  begin
   repeat((taps_seen%3)+1)@(negedge clk);
   k_re=re_value;k_im=im_value;k_last=last_value;k_invalid=invalid_value;k_valid=1;
   while(!k_ready)@(negedge clk);
   @(posedge clk);@(negedge clk);k_valid=0;k_re=~re_value;k_im=~im_value;k_last=~last_value;k_invalid=1;
  end
 endtask
 task get_r(input integer status_value,input integer nt,input integer nf,input integer got,
            input integer ov,input integer ix,input integer tag_value);
  begin
   @(negedge clk);while(!r_valid)@(negedge clk);
   repeat(3)@(negedge clk);
   if(r_status!==status_value[3:0]||r_taps!==nt[31:0]||r_frac!==nf[31:0]||
      r_received!==got[31:0]||r_overflow!==ov[0]||r_inexact!==ix[0]||r_tag!==tag_value[TW-1:0])
    $fatal(1,"configuration mismatch status=%0d expected=%0d",r_status,status_value);
   if(c_ready||g_ready||s_ready||k_ready)$fatal(1,"configuration reply ownership");
   r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
  end
 endtask
 task send_c(input integer count_value,input integer end_value,input integer restart_value,input integer tag_value);
  begin
   @(negedge clk);c_count=count_value;c_end=end_value;c_restart=restart_value;c_tag=tag_value;c_valid=1;
   while(!c_ready)@(negedge clk);
   @(posedge clk);@(negedge clk);c_valid=0;c_count=32'hffffffff;c_end=~end_value;
   c_restart=~restart_value;c_tag=~tag_value;
  end
 endtask
 task send_s(input integer re_value,input integer im_value,input integer last_value,input integer invalid_value);
  begin
   repeat((samples%3)+1)@(negedge clk);
   s_re=re_value;s_im=im_value;s_last=last_value;s_invalid=invalid_value;s_valid=1;
   while(!s_ready)@(negedge clk);
   @(posedge clk);@(negedge clk);s_valid=0;s_re=~re_value;s_im=~im_value;s_last=~last_value;s_invalid=1;
  end
 endtask
 task get_o(input integer er,input integer ei,input integer keep_value,input integer last_value,
  input integer error_value,input integer status_value,input integer ov,input integer ix,
  input integer index_value,input integer count_value,input integer total_value,
  input integer received_value,input integer tag_value);
  begin
   @(negedge clk);while(!m_valid)@(negedge clk);
   repeat(1+(index_value%4))@(negedge clk);
   if(m_re!==er[DW-1:0]||m_im!==ei[DW-1:0]||m_keep!==keep_value[0]||m_last!==last_value[0]||
      m_error!==error_value[0]||m_status!==status_value[3:0]||m_overflow!==ov[0]||m_inexact!==ix[0]||
      m_index!==index_value[LN-1:0]||m_count!==count_value[31:0]||m_total!==total_value[31:0]||
      m_received!==received_value[31:0]||m_tag!==tag_value[TW-1:0])
    $fatal(1,"output mismatch idx=%0d/%0d re=%0d/%0d im=%0d/%0d status=%0d/%0d flags=%0d%0d/%0d%0d",
     m_index,index_value,m_re,er,m_im,ei,m_status,status_value,m_overflow,m_inexact,ov,ix);
   if(c_ready||g_ready||s_ready||k_ready)$fatal(1,"output ownership");
   m_ready=1;@(posedge clk);@(negedge clk);m_ready=0;
  end
 endtask
 task do_reset;
  begin
   @(negedge clk);rst=1;g_valid=0;c_valid=0;k_valid=0;s_valid=0;r_ready=0;m_ready=0;
   repeat(3)@(negedge clk);rst=0;
   repeat(2)@(negedge clk);
   if(m_valid||r_valid||busy||!g_ready||!c_ready)$fatal(1,"reset recovery");
   if(count_enable)resets=resets+1;else directed_resets=directed_resets+1;
  end
 endtask
 task wait_phase(input integer expected);
  begin @(negedge clk);while(phase_state!=expected)@(negedge clk);end
 endtask
 task unity_config;
  begin send_g(1,0,3);send_k(1,0,1,0);get_r(0,1,0,1,0,0,3);end
 endtask
 task impulse_block(input integer length_value,input integer end_value);
  integer j;
  begin
   send_c(length_value,end_value,0,5);
   for(j=0;j<length_value;j=j+1)send_s((j==0)?16:0,0,j==length_value-1,0);
  end
 endtask
 task assert_no_config;
  begin send_c(N,0,0,5);get_o(0,0,0,1,1,2,0,0,0,N,0,0,5);end
 endtask
 task directed;
  integer j;
  begin
   do_reset;assert_no_config;
   send_g(2,0,3);send_k(1,0,0,0);do_reset;assert_no_config;
   send_g(1,0,3);send_k(1,0,1,0);wait_phase(5);repeat(4)@(negedge clk);do_reset;assert_no_config;
   send_g(1,0,3);send_k(1,0,1,0);@(negedge clk);while(!r_valid)@(negedge clk);
   repeat(4)@(negedge clk);do_reset;assert_no_config;
   unity_config;send_c(N,0,0,5);send_s(16,0,0,0);do_reset;assert_no_config;
   unity_config;impulse_block(N,0);wait_phase(10);do_reset;assert_no_config;
   unity_config;impulse_block(N,0);wait_phase(15);do_reset;assert_no_config;
   unity_config;impulse_block(N,0);wait_phase(19);do_reset;assert_no_config;
   unity_config;impulse_block(N,0);@(negedge clk);while(!m_valid)@(negedge clk);
   repeat(4)@(negedge clk);do_reset;assert_no_config;
   send_g(2,0,3);send_k(1,0,0,0);send_k(0,0,1,0);get_r(0,2,0,2,0,0,3);
   impulse_block(N-1,0);m_ready=1;wait_phase(20);do_reset;assert_no_config;
   send_g(N,0,3);
   for(j=0;j<N;j=j+1)send_k((j==0)?1:0,0,j==N-1,0);
   get_r(0,N,0,N,0,0,3);impulse_block(1,1);m_ready=1;wait_phase(20);do_reset;assert_no_config;
   if(directed_resets!=11)$fatal(1,"directed reset count");
  end
 endtask

 integer fd,scan,op,a,b,c,d,e,f,g,h,i,j,k,l,m;
 string vector_path;
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vectors");
  directed;count_enable=1;
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"vector open");
  scan=$fscanf(fd,"%d",op);
  while(scan==1&&op!=0)begin
   case(op)
    1:begin scan=$fscanf(fd,"%d %d %d",a,b,c);if(scan!=3)$fatal(1,"G parse");send_g(a,b,c);end
    2:begin scan=$fscanf(fd,"%d %d %d %d",a,b,c,d);if(scan!=4)$fatal(1,"K parse");send_k(a,b,c,d);end
    3:begin scan=$fscanf(fd,"%d %d %d %d %d %d %d",a,b,c,d,e,f,g);
     if(scan!=7)$fatal(1,"R parse");get_r(a,b,c,d,e,f,g);end
    4:begin scan=$fscanf(fd,"%d %d %d %d",a,b,c,d);if(scan!=4)$fatal(1,"C parse");send_c(a,b,c,d);end
    5:begin scan=$fscanf(fd,"%d %d %d %d",a,b,c,d);if(scan!=4)$fatal(1,"S parse");send_s(a,b,c,d);end
    6:begin scan=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h,i,j,k,l,m);
     if(scan!=13)$fatal(1,"O parse");get_o(a,b,c,d,e,f,g,h,i,j,k,l,m);end
    9:do_reset;
    default:$fatal(1,"unknown vector op %0d",op);
   endcase
   scan=$fscanf(fd,"%d",op);
  end
  if(scan!=1||op!=0)$fatal(1,"missing vector terminator");
  scan=$fgetc(fd);
  while(scan!=-1)begin
   if((scan!=9)&&(scan!=10)&&(scan!=13)&&(scan!=32))$fatal(1,"trailing vector data");
   scan=$fgetc(fd);
  end
  $fclose(fd);
  @(negedge clk);while(busy)@(negedge clk);
  repeat(4)begin @(negedge clk);if(m_valid||r_valid)$fatal(1,"stale output after suite");end
  $display("FFT_FIR_PASS log_n=%0d width=%0d tag_w=%0d wrapper=%0d configs=%0d commands=%0d taps=%0d samples=%0d outputs=%0d markers=%0d resets=%0d directed_resets=%0d holds=%0d cycles=%0d",
   LN,DW,TW,WRAPPER,configs,commands,taps_seen,samples,outputs,markers,resets,directed_resets,holds,cycles);
  $finish;
 end
endmodule
