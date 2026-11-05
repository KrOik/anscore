// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_ram_ordered_dictionary;
 parameter integer CAPACITY=32,K_W=32,V_W=32;
 localparam integer CW=(CAPACITY<2)?1:$clog2(CAPACITY+1);
 reg clk=0,rst_n=0,s_valid=0,m_ready=0;
 reg [2:0] s_op=0;
 reg [K_W-1:0] s_key=0,s_hi=0;
 reg [V_W-1:0] s_value=0;
 wire s_ready,m_valid,m_found;
 wire [1:0] m_kind;wire [2:0] m_status;
 wire [K_W-1:0] m_key;wire [V_W-1:0] m_value;wire [CW-1:0] m_count;
 ram_ordered_dictionary #(.CAPACITY(CAPACITY),.K_W(K_W),.V_W(V_W)) dut(
 .clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),.s_op(s_op),
 .s_key(s_key),.s_value(s_value),.s_hi(s_hi),.m_valid(m_valid),.m_ready(m_ready),
 .m_kind(m_kind),.m_status(m_status),.m_found(m_found),.m_key(m_key),
 .m_value(m_value),.m_count(m_count));
 always #5 clk=~clk;
 integer cycle=0,stall=0,force_hold=0,total_records=0,total_commands=0;
 reg held_out=0,held_in=0;
 localparam integer OW=2+3+1+K_W+V_W+CW,IW=3+2*K_W+V_W;
 reg [OW-1:0] old_out;reg [IW-1:0] old_in;
 wire [OW-1:0] packed_out={m_kind,m_status,m_found,m_key,m_value,m_count};
 wire [IW-1:0] packed_in={s_op,s_key,s_value,s_hi};
 always @(negedge clk) m_ready=rst_n && !force_hold &&
     (!stall || ((cycle%9)!=2 && (cycle%9)!=3 && (cycle%9)!=4));
 always @(posedge clk) begin
  cycle=cycle+1;
  if(cycle>1000000)$fatal(1,"fixed cycle watchdog");
  if(!rst_n) begin
   if(s_ready || m_valid)$fatal(1,"reset transfer gate");
   held_out=0;held_in=0;
  end else begin
   if(held_out && (!m_valid || packed_out!==old_out))$fatal(1,"held output changed");
   if(held_in && (!s_valid || packed_in!==old_in))$fatal(1,"held input changed");
   held_out=m_valid&&!m_ready;old_out=packed_out;
   held_in=s_valid&&!s_ready;old_in=packed_in;
  end
 end
 string profile,mode;
 integer op_in,nresponses,ekind[0:32],estatus[0:32],efound[0:32],ecount[0:32];
 reg [31:0] key_in,value_in,hi_in,ekey[0:32],evalue[0:32];
 task load_command(input integer fd);
  integer rc,i,tk,ts,tf,tc;reg [31:0] tx,tv;
  begin
   rc=$fscanf(fd,"%d %d %d %d %d",op_in,key_in,value_in,hi_in,nresponses);
   if(rc!=5 || nresponses<1 || nresponses>CAPACITY+1)$fatal(1,"command fixture");
   for(i=0;i<nresponses;i=i+1) begin
    rc=$fscanf(fd,"%d %d %d %d %d %d",tk,ts,tf,tx,tv,tc);
    if(rc!=6)$fatal(1,"response fixture");
    ekind[i]=tk;estatus[i]=ts;efound[i]=tf;ekey[i]=tx;evalue[i]=tv;ecount[i]=tc;
   end
  end
 endtask
 task issue(input integer op,input reg [31:0] key,value,high);
  integer done;
  begin
   @(negedge clk);s_op=3'(op);s_key=K_W'(key);s_value=V_W'(value);s_hi=K_W'(high);s_valid=1;done=0;
   while(!done)begin @(posedge clk);if(s_ready)done=1;#1;end
   @(negedge clk);s_valid=0;
  end
 endtask
 task drain_loaded(input integer ordinal);
  integer i,done,waited;
  begin
   for(i=0;i<nresponses;i=i+1)begin
    done=0;waited=0;
    while(!done)begin
     @(posedge clk);waited=waited+1;
     if(waited>10000)$fatal(1,"response watchdog");
     if(m_valid && m_ready)begin
      if({m_kind,m_status,m_found,m_key,m_value,m_count} !==
         {2'(ekind[i]),3'(estatus[i]),1'(efound[i]),K_W'(ekey[i]),V_W'(evalue[i]),CW'(ecount[i])})
       $fatal(1,"response mismatch command=%0d response=%0d",ordinal,i);
      $display("REC %s %0d %0d %0d %0d %0d %0d %0d %0d",profile,ordinal,i,
       m_kind,m_status,m_found,$unsigned(m_key),$unsigned(m_value),m_count);
      total_records=total_records+1;done=1;
     end
     #1;
    end
   end
   @(negedge clk);
   if(m_valid)$fatal(1,"stale response after complete command");
   total_commands=total_commands+1;
  end
 endtask
 task run_loaded(input integer ordinal,input integer already_issued);
  begin
   $display("CMD %s %0d %0d %0d %0d %0d %0d",profile,ordinal,op_in,
            $unsigned(key_in),$unsigned(value_in),$unsigned(hi_in),nresponses);
   if(!already_issued)issue(op_in,key_in,value_in,hi_in);
   drain_loaded(ordinal);
  end
 endtask
 task silent_put(input integer key);
  integer done;
  begin
   issue(1,key,1,0);done=0;
   while(!done)begin
    @(posedge clk);
    if(m_valid&&m_ready)begin
     if(m_kind!=0 || m_status!=0)$fatal(1,"preload put");done=1;
    end
    #1;
   end
   @(negedge clk);
  end
 endtask
 function automatic integer predicate(input string name);
  begin
   if(name=="search_wait")predicate=(dut.impl.state==3);
   else if(name=="bound_wait")predicate=(dut.impl.state==6);
   else if(name=="insert_shift_read")predicate=(dut.impl.state==9 && dut.impl.op==1);
   else if(name=="insert_shift_write")predicate=(dut.impl.state==11 && dut.impl.op==1);
   else if(name=="delete_shift_write")predicate=(dut.impl.state==11 && dut.impl.op==2);
   else if(name=="final_write")predicate=(dut.impl.state==13);
   else if(name=="response_held")predicate=(m_valid&&!m_ready&&m_kind==0);
   else if(name=="range_row_held" || name=="next_offer")predicate=(m_valid&&!m_ready&&m_kind==1);
   else if(name=="range_end_held")predicate=(m_valid&&!m_ready&&m_kind==2);
   else predicate=0;
  end
 endfunction
 task reset_job(input integer ordinal,input string target);
  integer fd,count,rc,i,guard,done;reg [31:0] maximum,vmaximum;
  begin
   // Each named job begins from an empty logical store.
   @(negedge clk);rst_n=0;s_valid=0;force_hold=0;
   repeat(3)@(posedge clk);
   @(negedge clk);rst_n=1;
   silent_put(1);
   if(CAPACITY>1)begin silent_put(3);silent_put(5);end
   force_hold=1;maximum=32'hffffffff>>(32-K_W);vmaximum=32'hffffffff>>(32-V_W);
   if(target=="insert_shift_read" || target=="insert_shift_write")issue(1,0,0,0);
   else if(target=="delete_shift_write")issue(2,1,0,0);
   else if(target=="final_write")issue(1,1,0,0);
   else if(target=="range_end_held")issue(4,0,0,0);
   else if(target=="range_row_held" || target=="next_offer")issue(4,0,0,maximum);
   else issue(0,1,0,0);
   guard=0;
   while(!predicate(target))begin @(negedge clk);guard=guard+1;if(guard>10000)$fatal(1,"reset predicate absent");end
   $display("PROBE %s %0d %s %0d %0d %0d %0d %0d %0d",profile,ordinal,target,
            dut.impl.state,dut.impl.op,dut.impl.count,m_valid,m_kind,s_ready);
   if(target=="next_offer")begin
    @(negedge clk);s_valid=1;s_op=1;s_key=0;s_value=V_W'(vmaximum);s_hi=0;
    repeat(3)begin @(posedge clk);if(s_ready || !m_valid || m_ready)$fatal(1,"queued offer transfer");#1;end
    $display("OFFER %s %0d 0 %0d",profile,ordinal,$unsigned(s_value));
    @(negedge clk);
   end
   if(!predicate(target))$fatal(1,"reset predicate moved");
   rst_n=0;
   if(target!="next_offer")begin s_valid=1;s_op=1;s_key=K_W'(maximum);s_value=V_W'(vmaximum);s_hi=0;end
   for(i=0;i<3;i=i+1)begin
    @(posedge clk);if(s_ready || m_valid || !s_valid)$fatal(1,"reset high transfer");
    $display("RESETEDGE %s %0d %0d 0 0",profile,ordinal,i);#1;
   end
   fd=$fopen($sformatf("prepared/fixtures/%s/reset_%s.txt",profile,target),"r");
   if(!fd)$fatal(1,"missing reset fixture");
   rc=$fscanf(fd,"%d",count);if(rc!=1)$fatal(1,"reset count");
   load_command(fd);
   @(negedge clk);rst_n=1;force_hold=0;
   if(target=="next_offer")begin
    done=0;
    while(!done)begin @(posedge clk);if(s_ready)done=1;#1;end
    $display("NEXTHANDSHAKE %s %0d",profile,ordinal);
    @(negedge clk);s_valid=0;
    run_loaded(0,1);
   end else begin s_valid=0;run_loaded(0,0);end
   for(i=1;i<count;i=i+1)begin load_command(fd);run_loaded(i,0);end
   $fclose(fd);$display("RESETDONE %s %0d %s",profile,ordinal,target);
  end
 endtask
 integer fd,ncmd,rc,i,probes;
 string names[0:9];
 initial begin
  if(!$value$plusargs("PROFILE=%s",profile) || !$value$plusargs("MODE=%s",mode))$fatal(1,"profile/mode required");
  rc=$value$plusargs("STALL=%d",stall);
  repeat(3)@(posedge clk);
  @(negedge clk);rst_n=1;
  if(mode=="main")begin
   fd=$fopen($sformatf("prepared/fixtures/%s/main.txt",profile),"r");if(!fd)$fatal(1,"main fixture");
   rc=$fscanf(fd,"%d",ncmd);if(rc!=1)$fatal(1,"main count");
   for(i=0;i<ncmd;i=i+1)begin
    load_command(fd);if(stall && i%4==2)repeat(2)@(negedge clk);run_loaded(i,0);
   end
   $fclose(fd);
   $display("PASS MAIN profile=%s stall=%0d commands=%0d records=%0d",profile,stall,total_commands,total_records);
  end else if(mode=="reset")begin
   names[0]="search_wait";names[1]="bound_wait";
   if(CAPACITY==1)begin probes=7;names[2]="final_write";names[3]="response_held";
    names[4]="range_row_held";names[5]="range_end_held";names[6]="next_offer";end
   else begin probes=10;names[2]="insert_shift_read";names[3]="insert_shift_write";names[4]="delete_shift_write";
    names[5]="final_write";names[6]="response_held";names[7]="range_row_held";names[8]="range_end_held";names[9]="next_offer";end
   for(i=0;i<probes;i=i+1)reset_job(i,names[i]);
   $display("PASS RESET profile=%s probes=%0d commands=%0d records=%0d",profile,probes,total_commands,total_records);
  end else $fatal(1,"unknown mode");
  $finish;
 end
endmodule
