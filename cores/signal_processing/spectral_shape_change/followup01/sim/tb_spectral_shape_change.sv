`timescale 1ns/1ps
module tb_spectral_shape_change;
 parameter integer MAX_BINS=7,TAG_W=8,IQ=0;
 localparam integer C=$clog2(MAX_BINS+1),S=32+((MAX_BINS>1)?$clog2(MAX_BINS):0),W=2*S;
 localparam integer BUNDLE_W=4+TAG_W+32+C+2*S+2*W+17+2;
 localparam integer LIMIT=113*MAX_BINS+4096;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cv=0,sv=0,rr=0,restart=0,last=0,invalid=0;
 reg [31:0] command_bins=0,data=0;reg [TAG_W-1:0] tag=0;
 wire cr,sr,mv,busy,metric,inexact;
 wire [3:0] status;wire [TAG_W-1:0] rtag;wire [31:0] rbins;
 wire [C-1:0] received;wire [S-1:0] total,previous;
 wire [W-1:0] numerator,denominator;wire [16:0] q16;
 wire [4:0] core_state;wire ref_bank,history_valid,divide_valid;
 wire [S-1:0] stored_reference;wire [C-1:0] stored_length;
 reg inject_zero=0;
 generate if(IQ)begin:iq_case
  iq_spectral_shape_change #(.MAX_BINS(MAX_BINS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_bins(command_bins),.c_restart(restart),.c_tag(tag),
   .s_valid(sv),.s_ready(sr),.s_iq(data),.s_last(last),.s_invalid(invalid),
   .m_valid(mv),.m_ready(rr),.m_status(status),.m_tag(rtag),.m_bins(rbins),.m_received(received),
   .m_total(total),.m_reference_total(previous),.m_numerator(numerator),.m_denominator(denominator),
   .m_change_q16(q16),.m_metric_valid(metric),.m_inexact(inexact),.busy(busy));
  assign core_state=dut.instrument.state;assign ref_bank=dut.instrument.reference_bank;
  assign history_valid=dut.instrument.history_valid;assign stored_reference=dut.instrument.reference_total;
  assign stored_length=dut.instrument.reference_length;assign divide_valid=dut.instrument.div_valid;
  always @(inject_zero)begin
   if(inject_zero)force dut.instrument.divide.m_divzero=1'b1;
   else release dut.instrument.divide.m_divzero;
  end
 end else begin:power_case
  spectral_shape_change #(.MAX_BINS(MAX_BINS),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_bins(command_bins),.c_restart(restart),.c_tag(tag),
   .s_valid(sv),.s_ready(sr),.s_power(data),.s_last(last),.s_invalid(invalid),
   .m_valid(mv),.m_ready(rr),.m_status(status),.m_tag(rtag),.m_bins(rbins),.m_received(received),
   .m_total(total),.m_reference_total(previous),.m_numerator(numerator),.m_denominator(denominator),
   .m_change_q16(q16),.m_metric_valid(metric),.m_inexact(inexact),.busy(busy));
  assign core_state=dut.state;assign ref_bank=dut.reference_bank;
  assign history_valid=dut.history_valid;assign stored_reference=dut.reference_total;
  assign stored_length=dut.reference_length;assign divide_valid=dut.div_valid;
  always @(inject_zero)begin
   if(inject_zero)force dut.divide.m_divzero=1'b1;
   else release dut.divide.m_divzero;
  end
 end endgenerate
 wire [BUNDLE_W-1:0] bundle={status,rtag,rbins,received,total,previous,numerator,denominator,q16,metric,inexact};
 integer fd,scan,cases,case_index,row_index,beats,j,k,waited;
 integer results=0,holds=0,resets=0,cancellations=0,arith_errors=0,continuous=0;
 integer clocks=0,last_input_clock=-100;
 reg [1023:0] filename;
 reg [31:0] file_bins,file_restart,file_tag;
 reg [3:0] expected_status;
 reg [C-1:0] expected_received;
 reg [S-1:0] expected_total,expected_previous;
 reg [W-1:0] expected_num,expected_den;
 reg [16:0] expected_q;
 reg expected_metric,expected_inexact;
 reg old_bank,old_valid;
 reg [S-1:0] old_total;
 reg [C-1:0] old_length;
 reg [TAG_W-1:0] accepted_tag;
 reg [31:0] accepted_bins;
 always @(posedge clk)begin
  clocks=clocks+1;
  if(!rst && sv && sr)begin
   if(clocks==last_input_clock+1)continuous=continuous+1;
   last_input_clock=clocks;
  end
 end
 task reset_now;
  begin
   rst=1;cv=0;sv=0;rr=0;inject_zero=0;
   repeat(4)@(posedge clk);@(negedge clk);rst=0;repeat(2)@(negedge clk);resets=resets+1;
   if(mv||busy||history_valid||!cr)$fatal(1,"reset recovery case=%0d phase=%0d",case_index,core_state);
  end
 endtask
 task command(input [31:0] count,input again,input [TAG_W-1:0] value_tag);
  integer count_wait;
  begin
   old_bank=ref_bank;old_valid=history_valid;old_total=stored_reference;old_length=stored_length;
   command_bins=count;restart=again;tag=value_tag;accepted_tag=value_tag;accepted_bins=count;cv=1;count_wait=0;
   do begin
    @(posedge clk);count_wait=count_wait+1;
    if(count_wait>LIMIT)$fatal(1,"command deadline case=%0d phase=%0d",case_index,core_state);
   end while(!cr);
   @(negedge clk);cv=0;command_bins=32'hffffffff;restart=!again;tag=~value_tag;
  end
 endtask
 task sample(input [31:0] value,input ending,input bad);
  integer count_wait;
  begin
   data=value;last=ending;invalid=bad;sv=1;count_wait=0;
   do begin
    @(posedge clk);count_wait=count_wait+1;
    if(count_wait>LIMIT)$fatal(1,"sample deadline case=%0d row=%0d phase=%0d",case_index,row_index,core_state);
   end while(!sr);
   @(negedge clk);sv=0;last=0;invalid=0;
  end
 endtask
 task await_output;
  integer count_wait;
  begin
   count_wait=0;
   while(!mv)begin
    @(negedge clk);count_wait=count_wait+1;
    if(count_wait>LIMIT)$fatal(1,"result deadline case=%0d phase=%0d max=%0d",case_index,core_state,MAX_BINS);
   end
  end
 endtask
 task wait_phase(input [4:0] target);
  integer count_wait;
  begin
   count_wait=0;
   while(core_state!=target)begin
    @(negedge clk);count_wait=count_wait+1;
    if(count_wait>LIMIT)$fatal(1,"phase deadline case=%0d target=%0d phase=%0d",case_index,target,core_state);
   end
  end
 endtask
 task retire;
  reg [BUNDLE_W-1:0] held;
  integer pause;
  begin
   if(ref_bank!==old_bank || stored_reference!==old_total || stored_length!==old_length)
    $fatal(1,"reference changed before retirement case=%0d status=%0d",case_index,status);
   held=bundle;cv=1;sv=1;data=32'hdeadbeef;last=1;invalid=1;
   for(pause=0;pause<5;pause=pause+1)begin
    if(cr||sr||!busy)$fatal(1,"admitted under held summary");
    @(posedge clk);@(negedge clk);
    if(!mv||bundle!==held || ref_bank!==old_bank || stored_reference!==old_total)
     $fatal(1,"held summary/reference changed case=%0d",case_index);
    holds=holds+1;
   end
   cv=0;sv=0;last=0;invalid=0;rr=1;
   if(cr||sr)$fatal(1,"retirement fallthrough");
   @(posedge clk);@(negedge clk);rr=0;results=results+1;
   if(held[BUNDLE_W-1 -:4]<=4)begin
    if(ref_bank!==!old_bank || !history_valid || stored_reference!==expected_total || stored_length!==accepted_bins)
     $fatal(1,"reference commit mismatch case=%0d",case_index);
   end else if(held[BUNDLE_W-1 -:4]==5)begin
    if(ref_bank!==old_bank || history_valid!==old_valid || stored_reference!==old_total)
     $fatal(1,"bad command changed history");
   end else begin
    if(ref_bank!==old_bank || history_valid || stored_reference!==old_total)
     $fatal(1,"damaged frame history policy");
   end
  end
 endtask
 task check_expected;
  begin
   await_output();
   if(status!==expected_status || rtag!==accepted_tag || rbins!==accepted_bins || received!==expected_received ||
      total!==expected_total || previous!==expected_previous || numerator!==expected_num || denominator!==expected_den ||
      q16!==expected_q || metric!==expected_metric || inexact!==expected_inexact)
    $fatal(1,"oracle case=%0d status=%0d/%0d total=%h/%h prior=%h/%h num=%h/%h den=%h/%h q=%h/%h recv=%0d/%0d",case_index,
     status,expected_status,total,expected_total,previous,expected_previous,numerator,expected_num,denominator,expected_den,q16,expected_q,received,expected_received);
   retire();
  end
 endtask
 task known_frame(input integer count,input again,input [3:0] expected_kind);
  integer index;
  begin
   command(count,again,TAG_W'(19));
   for(index=0;index<count;index=index+1)sample(32'd1,index==count-1,0);
   expected_status=expected_kind;expected_received=C'(count);expected_total=S'(count);
   expected_previous=(expected_kind==0)?S'(count):0;
   expected_num=0;expected_den=(expected_kind==0)?W'(count*count):0;
   expected_q=0;expected_metric=(expected_kind==0);expected_inexact=0;check_expected();
  end
 endtask
 initial begin
  reset_now();
  if(!$value$plusargs("vectors=%s",filename))$fatal(1,"vectors missing");
  fd=$fopen(filename,"r");if(!fd)$fatal(1,"vectors open");
  scan=$fscanf(fd,"%d",cases);if(scan!=1||cases<1)$fatal(1,"case header");
  for(case_index=0;case_index<cases;case_index=case_index+1)begin
   scan=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h",file_bins,file_restart,file_tag,beats,
    expected_status,expected_received,expected_total,expected_previous,expected_num,expected_den,expected_q,expected_metric,expected_inexact);
   if(scan!=13)$fatal(1,"case format case=%0d fields=%0d",case_index,scan);
   command(file_bins,file_restart[0],TAG_W'(file_tag));
   for(row_index=0;row_index<beats;row_index=row_index+1)begin
    scan=$fscanf(fd,"%h %h %h",data,last,invalid);if(scan!=3)$fatal(1,"sample format");
    if(row_index%7==0)@(negedge clk);
    sample(data,last,invalid);
   end
   check_expected();
  end
  scan=$fscanf(fd,"%d",j);if(!((scan==0||scan==-1)&&$feof(fd)))$fatal(1,"trailing vector data");$fclose(fd);
  // Cancel in capture, both RAM responses, both per-bin multiplies, denominator
  // multiply, division, held result and flush. Each fresh sequence starts WARMUP.
  for(j=0;j<8;j=j+1)begin
   known_frame(MAX_BINS,1,1);
   command(MAX_BINS,0,TAG_W'(29));
   if(j==0)begin
    for(k=0;k<MAX_BINS/2;k=k+1)sample(32'd1,0,0);
   end else if(j==7)begin
    sample(32'd1,1,1);wait_phase(13);
   end else begin
    for(k=0;k<MAX_BINS;k=k+1)sample(32'd1,k==MAX_BINS-1,0);
    case(j)
     1:wait_phase(4);2:wait_phase(6);3:wait_phase(8);4:wait_phase(10);5:wait_phase(12);
     6:begin await_output();if(ref_bank!==old_bank)$fatal(1,"held result committed early");end
    endcase
   end
   reset_now();cancellations=cancellations+1;
   known_frame(1,0,1);known_frame(1,0,0);
  end
  // A real failed arithmetic response flushes helper state and invalidates
  // history; the next frame is WARMUP and its successor computes normally.
  known_frame(MAX_BINS,1,1);command(MAX_BINS,0,TAG_W'(31));
  for(k=0;k<MAX_BINS;k=k+1)sample(32'd1,k==MAX_BINS-1,0);
  wait_phase(12);waited=0;
  while(!divide_valid)begin
   @(negedge clk);waited=waited+1;if(waited>LIMIT)$fatal(1,"fault injection deadline");
  end
  inject_zero=1;await_output();inject_zero=0;
  expected_status=9;expected_received=C'(MAX_BINS);expected_total=0;expected_previous=0;
  expected_num=0;expected_den=0;expected_q=0;expected_metric=0;expected_inexact=0;check_expected();arith_errors=arith_errors+1;
  known_frame(MAX_BINS,0,1);known_frame(MAX_BINS,0,0);
  if(results!=cases+28 || holds!=5*results || resets!=9 || cancellations!=8 || arith_errors!=1)
   $fatal(1,"finite counter mismatch");
  if(MAX_BINS>1 && continuous==0)$fatal(1,"no consecutive input transfers exercised");
  $display("B48_SHAPE_SIM_PASS cases=%0d results=%0d holds=%0d resets=%0d cancellations=%0d arith_errors=%0d continuous=%0d",
   cases,results,holds,resets,cancellations,arith_errors,continuous);$finish;
 end
 initial begin #100000000;$fatal(1,"global watchdog case=%0d phase=%0d row=%0d",case_index,core_state,row_index);end
endmodule
