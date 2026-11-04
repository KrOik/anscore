`timescale 1ns/1ps
module tb_weighted_interval_schedule;
 parameter integer N=16,E=16,W=16,T=8;
 localparam IW=(N<=1)?1:$clog2(N), CW=$clog2(N+1), SW=W+$clog2(N);
 localparam INW=2*E+W+T+2;
 localparam OUTW=3+IW+2*E+W+1+CW+SW+N+T+2;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,s_valid=0,s_keep=0,s_last=0,m_ready=0;
 wire s_ready,m_valid,m_keep,m_first,m_last,m_selected;
 reg signed [E-1:0] s_start=0,s_end=0;
 reg [W-1:0] s_weight=0;reg [T-1:0] s_tag=0;
 wire [IW-1:0] m_index;wire signed [E-1:0] m_start,m_end;
 wire [W-1:0] m_weight;wire [CW-1:0] m_count;
 wire [SW-1:0] m_total_weight;wire [N-1:0] m_selection;
 wire [T-1:0] m_tag;wire [1:0] m_error;
 weighted_interval_schedule #(.MAX_ITEMS(N),.ENDPOINT_W(E),.WEIGHT_W(W),.TAG_W(T)) dut(.*);
 wire [OUTW-1:0] payload={m_keep,m_first,m_last,m_index,m_start,m_end,m_weight,m_selected,
  m_count,m_total_weight,m_selection,m_tag,m_error};
 reg [INW-1:0] inputs[0:25000];
 reg [OUTW-1:0] held;
 reg held_valid=0;
 integer cycles=0,blocked=0,holds=0,resets=0,source=0,received=0;
 integer inf,outf,input_count,output_count,offered=0,age=0,frame_tail=-1,max_latency=0;
 integer frame_items=0,expected_latency=0,old_state=0,work=0,selection_reads=0,pred_reads=0;
 reg started=0,main_run=0;
 reg [1023:0] input_file,output_file;
 task tick;begin @(posedge clk);#1;end endtask
 task clear_reset;
  begin
   rst=1;s_valid=0;m_ready=0;#1;
   if(s_ready || m_valid)$fatal(1,"reset public gate");
   tick;
   if(dut.state!=0 || dut.count!=0 || dut.processed!=0 || dut.best_mask!=0)$fatal(1,"reset control");
   @(negedge clk);rst=0;held_valid=0;
  end
 endtask
 task send(input integer a,input integer b,input integer w,input integer keep,input integer last,input integer tag);
  begin
   s_start=a;s_end=b;s_weight=w;s_keep=keep;s_last=last;s_tag=tag;s_valid=1;
   #1; // Allow reset release and combinational ready to settle before polling.
   while(!s_ready)begin tick;@(negedge clk);end
   tick;@(negedge clk);s_valid=0;
  end
 endtask
 task setup_frame(input integer partial);
  integer k,c;
  begin
   c=(N<4)?N:4;
   if(partial)send(-1,0,1,1,0,1);
   else for(k=0;k<c;k=k+1)send(-1,0,1,1,k==c-1,1);
  end
 endtask
 task fresh;
  integer k,c,waited;
  begin
   setup_frame(0);c=(N<4)?N:4;waited=0;
   for(k=0;k<c;k=k+1)begin
    while(!m_valid)begin tick;@(negedge clk);waited=waited+1;if(waited>4*N*N+2*N+20)$fatal(1,"fresh deadline");end
    if(!m_keep || m_first!=(k==0) || m_last!=(k==c-1) || m_index!=k ||
       m_start!=-1 || m_end!=0 || m_weight!=1 || m_selected!=(k==0) ||
       m_count!=c || m_total_weight!=1 || m_selection!=1 || m_tag!=1 || m_error!=0)
       $fatal(1,"fresh full result");
    repeat(2)begin tick;@(negedge clk);end
    m_ready=1;tick;@(negedge clk);m_ready=0;
   end
   if(!s_ready || m_valid)$fatal(1,"fresh retirement");
  end
 endtask
 task reset_probe(input integer probe);
  integer target,waited;
  reg match;
  begin
   if(probe==10)setup_frame(1);
   else if(probe==15)send(7,7,0,0,1,1);
   else if(probe==16)send(0,0,1,1,1,1);
   else if(probe!=0)setup_frame(0);
   waited=0;match=0;
   while(!match)begin
    if(probe<10)match=(dut.state==probe);
    else case(probe)
     10:match=(dut.state==0 && dut.frame_open);
     11:match=(dut.state==2 && dut.scan>0);
     12:match=(dut.state==5 && dut.scan>0);
     13:match=(dut.completed>0 && dut.state==1);
     14:begin m_ready=1;match=(dut.state==9 && m_index>0);end
     default:match=m_valid;
    endcase
    if(!match)begin tick;@(negedge clk);waited=waited+1;if(waited>4*N*N+2*N+50)$fatal(1,"probe unreachable %0d",probe);end
   end
   if(probe==17)begin
    s_valid=1;s_keep=1;s_last=1;s_start=0;s_end=1;s_weight=1;s_tag=0;
    repeat(3)begin tick;@(negedge clk);if(s_ready)$fatal(1,"held accepts source");end
   end
   // Reset now, without a further active edge in the selected phase.
   clear_reset;resets=resets+1;fresh;
  end
 endtask
 always @(posedge clk)begin
  cycles=cycles+1;
  if(!rst)begin
   if(held_valid && payload!==held)$fatal(1,"held payload changed");
   if(held_valid && !m_valid)$fatal(1,"held valid dropped");
   held_valid=m_valid&&!m_ready;held=payload;
   if(s_valid&&!s_ready)blocked=blocked+1;
   if(m_valid&&!m_ready)holds=holds+1;
   if(main_run)begin
    if(s_valid&&s_ready)begin
     frame_items=frame_items+s_keep;
     if(s_last)begin
      frame_tail=cycles;started=0;
      expected_latency=(dut.next_errors!=0 || frame_items==0)?0:frame_items*(4*frame_items+2)+2;
      frame_items=0;
     end
    end
    if(dut.state==6)work=work+1;
    if(dut.state==1)selection_reads=selection_reads+1;
    if(dut.state==4)pred_reads=pred_reads+1;
    if(m_valid&&m_ready)begin $fdisplay(outf,"%h",payload);received=received+1;end
   end
  end else held_valid=0;
 end
 always @(negedge clk)if(main_run && !rst)begin
  if(m_valid && !started)begin
   if(cycles-frame_tail!=expected_latency)$fatal(1,"first latency got%0d expected%0d",cycles-frame_tail,expected_latency);
   if(cycles-frame_tail>max_latency)max_latency=cycles-frame_tail;
   started=1;
  end
 end
 integer p,guard;
 initial begin
  if(!$value$plusargs("INPUT=%s",input_file) || !$value$plusargs("OUTPUT=%s",output_file) ||
     !$value$plusargs("COUNT=%d",input_count) || !$value$plusargs("OUTCOUNT=%d",output_count))$fatal(1,"args");
  $readmemh(input_file,inputs,0,input_count-1);outf=$fopen(output_file,"w");
  tick;@(negedge clk);clear_reset;
  for(p=0;p<18;p=p+1)if(!(N==1 && p>=11 && p<=14))reset_probe(p);
  main_run=1;guard=0;
  while(received<output_count)begin
   if(!offered && source<input_count && cycles%7!=0)begin
    {s_start,s_end,s_weight,s_keep,s_last,s_tag}=inputs[source];s_valid=1;offered=1;
   end
   if(m_valid)begin age=age+1;m_ready=(age>=4 && cycles%5!=0);end
   else begin age=0;m_ready=0;end
   @(posedge clk);
   if(s_valid&&s_ready)begin source=source+1;offered=0;end
   #1;@(negedge clk);if(!offered)s_valid=0;
   guard=guard+1;if(guard>3000000)$fatal(1,"main guard");
  end
  main_run=0;
  if(source!=input_count || holds==0 || blocked==0)$fatal(1,"coverage");
  $fclose(outf);
  $display("PASS interval records=%0d blocked=%0d held=%0d resets=%0d max_latency=%0d work=%0d select_reads=%0d pred_reads=%0d",received,blocked,holds,resets,max_latency,work,selection_reads,pred_reads);
  $finish;
 end
endmodule
