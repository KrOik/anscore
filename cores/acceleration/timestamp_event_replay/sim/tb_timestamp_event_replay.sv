`timescale 1ns/1ps
module tb_timestamp_event_replay;
 parameter integer TIME_W=64,DATA_W=64,TAG_W=8;
 localparam integer MAX_ROWS=65536;
 reg clk=0;
 always #5 clk=~clk;
 reg rst=1,run_enable=0,abort_run=0,c_valid=0,s_valid=0,m_ready=0,d_ready=0;
 reg [31:0] c_count=0;
 reg [47:0] c_step_q16=0;
 reg [TAG_W-1:0] c_tag=0;
 reg [TIME_W-1:0] s_time=0;
 reg [DATA_W-1:0] s_data=0;
 wire c_ready,s_ready,m_valid,d_valid,active,epoch_flush;
 wire [TIME_W-1:0] m_time,d_anchor;
 wire [DATA_W-1:0] m_data;
 wire [TAG_W-1:0] m_tag,d_tag;
 wire [2:0] d_status;
 wire [31:0] d_received,d_emitted;
 wire [TIME_W+15:0] d_elapsed_q16;
 reg e_c_ready,e_s_ready,e_m_valid,e_d_valid,e_active,e_epoch_flush;
 reg [TIME_W-1:0] e_m_time,e_d_anchor;
 reg [DATA_W-1:0] e_m_data;
 reg [TAG_W-1:0] e_m_tag,e_d_tag;
 reg [2:0] e_d_status;
 reg [31:0] e_d_received,e_d_emitted;
 reg [TIME_W+15:0] e_d_elapsed;
 reg held_m=0,held_d=0;
 reg [TIME_W-1:0] hold_time,hold_anchor;
 reg [DATA_W-1:0] hold_data;
 reg [TAG_W-1:0] hold_m_tag,hold_d_tag;
 reg [2:0] hold_status;
 reg [31:0] hold_received,hold_emitted;
 reg [TIME_W+15:0] hold_elapsed;
 integer fd,scan,row,expected_rows,tail_char,takes=0,responses=0,held_cycles=0,flush_cycles=0;
 string vector_path;
 timestamp_event_replay #(.TIME_W(TIME_W),.DATA_W(DATA_W),.TAG_W(TAG_W)) dut(.*);
 task read_row;
  begin
   scan=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
    rst,run_enable,abort_run,c_valid,c_count,c_step_q16,c_tag,
    s_valid,s_time,s_data,m_ready,d_ready,
    e_c_ready,e_s_ready,e_m_valid,e_m_time,e_m_data,e_m_tag,
    e_d_valid,e_d_status,e_d_received,e_d_emitted,e_d_anchor,e_d_elapsed,e_d_tag,
    e_active,e_epoch_flush);
  end
 endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",vector_path))$fatal(1,"missing VECTORS");
  fd=$fopen(vector_path,"r");if(fd==0)$fatal(1,"cannot open vectors");
  scan=$fscanf(fd,"%d\n",expected_rows);
  if(scan!=1 || expected_rows<1 || expected_rows>MAX_ROWS)$fatal(1,"invalid finite row header");
  for(row=0;row<expected_rows;row=row+1)begin
   @(negedge clk);read_row();
   if(scan!=27)$fatal(1,"row %0d fields %0d, expected27",row,scan);
   #1;
   if(c_ready!==e_c_ready || s_ready!==e_s_ready || m_valid!==e_m_valid ||
      d_valid!==e_d_valid || active!==e_active || epoch_flush!==e_epoch_flush)
    $fatal(1,"control mismatch row%0d got=%b%b%b%b%b%b expected=%b%b%b%b%b%b",row,
     c_ready,s_ready,m_valid,d_valid,active,epoch_flush,
     e_c_ready,e_s_ready,e_m_valid,e_d_valid,e_active,e_epoch_flush);
   if(m_valid && {m_time,m_data,m_tag}!=={e_m_time,e_m_data,e_m_tag})
    $fatal(1,"output mismatch row%0d",row);
   if(d_valid && {d_status,d_received,d_emitted,d_anchor,d_elapsed_q16,d_tag}!==
      {e_d_status,e_d_received,e_d_emitted,e_d_anchor,e_d_elapsed,e_d_tag})
    $fatal(1,"completion mismatch row%0d status%0d expected%0d",row,d_status,e_d_status);
   if(held_m && !epoch_flush && (!m_valid || {m_time,m_data,m_tag}!=={hold_time,hold_data,hold_m_tag}))
    $fatal(1,"held output ownership row%0d",row);
   if(held_d && !rst && (!d_valid || {d_status,d_received,d_emitted,d_anchor,d_elapsed_q16,d_tag}!==
      {hold_status,hold_received,hold_emitted,hold_anchor,hold_elapsed,hold_d_tag}))
    $fatal(1,"held completion ownership row%0d",row);
   held_m=m_valid && !m_ready;held_d=d_valid && !d_ready;
   hold_time=m_time;hold_data=m_data;hold_m_tag=m_tag;
   hold_status=d_status;hold_received=d_received;hold_emitted=d_emitted;
   hold_anchor=d_anchor;hold_elapsed=d_elapsed_q16;hold_d_tag=d_tag;
   if(m_valid && m_ready)takes=takes+1;
   if(d_valid && d_ready)responses=responses+1;
   if(held_m)held_cycles=held_cycles+1;
   if(epoch_flush)flush_cycles=flush_cycles+1;
   @(posedge clk);#1;
  end
  // Exact rows are complete. Only ASCII whitespace may remain before EOF.
  tail_char=$fgetc(fd);
  while(tail_char!=-1)begin
   if(tail_char!=9 && tail_char!=10 && tail_char!=11 && tail_char!=12 && tail_char!=13 && tail_char!=32)
    $fatal(1,"extra vector row or nonwhite trailing byte%0d",tail_char);
   tail_char=$fgetc(fd);
  end
  $fclose(fd);
  if(takes==0 || responses==0 || held_cycles==0 || flush_cycles==0)$fatal(1,"empty planned coverage");
  $display("PASS timestamp_event_replay T%0d D%0d G%0d rows=%0d emitted=%0d responses=%0d held=%0d flush=%0d",
   TIME_W,DATA_W,TAG_W,expected_rows,takes,responses,held_cycles,flush_cycles);
  $finish;
 end
 initial begin #(MAX_ROWS*12+100);$fatal(1,"finite row timeout");end
endmodule
