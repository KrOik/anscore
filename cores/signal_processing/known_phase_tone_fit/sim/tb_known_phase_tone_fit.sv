// SPDX-License-Identifier: Apache-2.0
module tb_known_phase_tone_fit;
 parameter integer MAX_SAMPLES=256,TAG_W=8,USE_EXAMPLE=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,m_ready=0,s_last=0;
 reg [31:0] c_count=0;
 reg [TAG_W-1:0] c_tag=0;
 reg signed [15:0] s_sample=0;
 reg [23:0] s_phase=0;
 wire c_ready,s_ready,m_valid;
 wire [2:0] m_status;wire [31:0] m_requested;wire [8:0] m_count;
 wire [TAG_W-1:0] m_tag;
 wire signed [127:0] m_i_numerator,m_q_numerator;
 wire [111:0] m_denominator;
 wire signed [55:0] m_gram_a,m_gram_b,m_gram_d;
 generate if(USE_EXAMPLE)begin:g_example
  gated_tone_measure #(.MAX_SAMPLES(MAX_SAMPLES),.TAG_W(TAG_W)) dut(.*);
 end else begin:g_core
  known_phase_tone_fit #(.MAX_SAMPLES(MAX_SAMPLES),.TAG_W(TAG_W)) dut(.*);
 end endgenerate
 localparam integer BUS_W=580+TAG_W;
 wire [BUS_W-1:0] bus={m_status,m_requested,m_count,m_tag,m_i_numerator,m_q_numerator,
  m_denominator,m_gram_a,m_gram_b,m_gram_d};
 reg held=0;reg [BUS_W-1:0] held_bus;
 integer cycles=0,commands=0,accepted=0,results=0,holds=0,reset_edges=0;
 always @(posedge clk)begin
  if(rst)begin
   held<=0;reset_edges=reset_edges+1;
   if(c_ready ||s_ready ||m_valid)$fatal(1,"reset handshake visible");
  end else begin
   cycles=cycles+1;
   if(cycles>1000000)$fatal(1,"finite cycle watchdog");
   if(held &&(!m_valid ||bus!==held_bus))$fatal(1,"held result changed");
   held<=m_valid &&!m_ready;
   if(m_valid &&!m_ready)begin held_bus<=bus;holds=holds+1;end
   if(c_valid &&c_ready)commands=commands+1;
   if(s_valid &&s_ready)accepted=accepted+1;
   if(m_valid &&m_ready)results=results+1;
  end
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;
   repeat(3)@(negedge clk);
   rst=0;repeat(3)@(negedge clk);
   if(!c_ready ||s_ready ||m_valid)$fatal(1,"reset ownership/recovery");
  end
 endtask
 task command;
  input [31:0] count,tag;
  begin
   @(negedge clk);c_count=count;c_tag=tag[TAG_W-1:0];c_valid=1;
   @(posedge clk);while(!c_ready)@(posedge clk);
   @(negedge clk);c_valid=0;c_count=32'hffffffff;c_tag=~c_tag;
  end
 endtask
 task sample_beat;
  input [15:0] value;input [23:0] reference;input last;
  begin
   repeat((accepted+reference[1:0])%3)@(negedge clk);
   @(negedge clk);s_sample=value;s_phase=reference;s_last=last;s_valid=1;
   @(posedge clk);while(!s_ready)@(posedge clk);
   @(negedge clk);s_valid=0;s_sample=16'h5a5a;s_phase=24'hfedcba;s_last=~last;
  end
 endtask
 task cancel_fixture;
  input integer location;
  begin
   command(3,32'hcafe1234);
   if(location!=0)begin
    sample_beat(16'h8000,0,0);
    if(location==1)repeat(5)@(negedge clk);
    else if(location==2)repeat(40)@(negedge clk);
    else begin
     sample_beat(16'h7fff,24'h400000,0);
     sample_beat(16'hffff,24'h800000,1);
     if(location==3)repeat(450)@(negedge clk);
     else begin @(negedge clk);while(!m_valid)@(negedge clk);end
    end
   end
   reset_core();
   repeat(8)begin @(negedge clk);if(m_valid)$fatal(1,"cancelled result escaped");end
  end
 endtask
 integer fd,rc,k,case_count=0,ch;
 reg [1023:0] vector_path;
 reg [31:0] requested,sent,tag,expected_status,expected_count;
 reg [127:0] expected_i,expected_q;
 reg [111:0] expected_den;
 reg [55:0] expected_a,expected_b,expected_d;
 reg [15:0] vector_sample;reg [23:0] vector_phase;reg [31:0] vector_last;
 initial begin
  reset_core();
  for(k=0;k<5;k=k+1)cancel_fixture(k);
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing vector file");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"cannot open vectors");
  rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h\n",
   requested,sent,tag,expected_status,expected_count,expected_i,expected_q,
   expected_den,expected_a,expected_b,expected_d);
  while(rc==11)begin
   command(requested,tag);
   for(k=0;k<sent;k=k+1)begin
    rc=$fscanf(fd,"%h %h %h\n",vector_sample,vector_phase,vector_last);
    if(rc!=3)$fatal(1,"truncated sample vector");
    sample_beat(vector_sample,vector_phase,vector_last[0]);
   end
   @(negedge clk);while(!m_valid)@(negedge clk);
   if(m_status!==expected_status[2:0] ||m_requested!==requested ||
      m_count!==expected_count[8:0] ||m_tag!==tag[TAG_W-1:0] ||
      m_i_numerator!==expected_i ||m_q_numerator!==expected_q ||
      m_denominator!==expected_den ||m_gram_a!==expected_a ||
      m_gram_b!==expected_b ||m_gram_d!==expected_d)
    $fatal(1,"case %0d numeric/status mismatch status=%0d/%0d count=%0d/%0d I=%h/%h Q=%h/%h D=%h/%h",
     case_count,m_status,expected_status,m_count,expected_count,m_i_numerator,expected_i,
     m_q_numerator,expected_q,m_denominator,expected_den);
   // Probe both new ownership channels while a held result is pending.
   c_valid=1;c_count=3;s_valid=1;s_sample=0;s_phase=0;s_last=1;
   repeat(4)begin @(negedge clk);if(c_ready ||s_ready)$fatal(1,"held result accepted new work");end
   c_valid=0;s_valid=0;m_ready=1;
   @(posedge clk);if(!m_valid)$fatal(1,"result vanished before retirement");
   @(negedge clk);m_ready=0;case_count=case_count+1;
   rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h\n",
    requested,sent,tag,expected_status,expected_count,expected_i,expected_q,
    expected_den,expected_a,expected_b,expected_d);
  end
  if(rc>0)$fatal(1,"partial vector header");
  // Do not assume a particular fscanf return at EOF; inspect trailing bytes.
  ch=$fgetc(fd);
  while(ch==9 ||ch==10 ||ch==13 ||ch==32)ch=$fgetc(fd);
  if(ch>=0)$fatal(1,"unexpected trailing vector content");
  $fclose(fd);
  if(case_count<11 ||holds<4*case_count ||results!=case_count ||commands!=case_count+5)
   $fatal(1,"vacuous finite coverage or orphan transaction");
  $display("KNOWN_PHASE_TONE_FIT_PASS cases=%0d commands=%0d samples=%0d results=%0d holds=%0d reset_edges=%0d cycles=%0d example=%0d",
   case_count,commands,accepted,results,holds,reset_edges,cycles,USE_EXAMPLE);
  $finish;
 end
endmodule
