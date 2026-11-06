`timescale 1ns/1ps
module tb_pretrade_credit_ledger;
 parameter A=5,K=7,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,c_valid=0,r_ready=0;
 wire c_ready,r_valid,busy,faulted;
 reg [2:0] c_op=0;reg [15:0] c_account=0;
 reg [63:0] c_ticket=0,c_amount=0,c_limit=0;
 reg [T-1:0] c_tag=0;
 wire [2:0] r_op;wire [3:0] r_status;wire [15:0] r_account;
 wire [63:0] r_ticket,r_amount,r_limit,r_used,r_available;
 wire [31:0] r_live;wire [T-1:0] r_tag;
 pretrade_credit_ledger #(.ACCOUNTS(A),.TICKETS(K),.TAG_W(T)) dut(.*);
 wire [375+T:0] payload={r_op,r_status,r_account,r_ticket,r_amount,r_limit,r_used,r_available,r_live,r_tag,faulted};
 wire [210+T:0] source_payload={c_op,c_account,c_ticket,c_amount,c_limit,c_tag};
 reg [375+T:0] expected_payload,held;
 reg [210+T:0] source_held;
 reg was_blocked=0,have=0,offered=0;
 integer fd,rv,marker,phase,op,aa,i,j,na,nt,matched,total;
 integer accts[0:A-1],seen_a[0:A-1],ticket_a[0:K-1],seen_t[0:K-1];
 reg [63:0] tk,am,lim,limits[0:A-1],useds[0:A-1],tickets[0:K-1],amounts[0:K-1];
 reg [T-1:0] tag;reg [135:0] row;
 integer cycles=0,commands=0,holds=0,preoffers=0,resets=0;
 string vectors;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"cycle watchdog");end
 always @(posedge clk)if(rst_n)begin
  if(was_blocked && (!c_valid || source_payload!==source_held))$fatal(1,"blocked source changed");
  was_blocked=c_valid&&!c_ready;source_held=source_payload;
 end
 task reset_core;
  begin
   rst_n=0;c_valid=0;r_ready=0;offered=0;was_blocked=0;
   #1;if(c_ready || r_valid)$fatal(1,"reset masking");
   repeat(2)@(posedge clk);@(negedge clk);rst_n=1;resets=resets+1;
   @(posedge clk);if(!c_ready || r_valid || faulted || dut.live!=0 || dut.configured!=0 || dut.count!=0)$fatal(1,"reset epoch");
  end
 endtask
 task load_record;
  begin
   rv=$fscanf(fd,"%d",marker);have=rv==1;
   if(have)begin
    if(marker==1)begin rv=$fscanf(fd,"%d",phase);if(rv!=1)$fatal(1,"reset record");end
    else if(marker!=0)$fatal(1,"marker");
    rv=$fscanf(fd,"%d %d %d %d %d %d",op,aa,tk,am,lim,tag);if(rv!=6)$fatal(1,"command record");
    if(marker==0)begin
     rv=$fscanf(fd,"%d %d %d",expected_payload,na,nt);if(rv!=3 || na>A || nt>K)$fatal(1,"expectation record");
     for(j=0;j<na;j=j+1)begin rv=$fscanf(fd,"%d %d %d",accts[j],limits[j],useds[j]);if(rv!=3)$fatal(1,"account record");end
     for(j=0;j<nt;j=j+1)begin rv=$fscanf(fd,"%d %d %d",tickets[j],ticket_a[j],amounts[j]);if(rv!=3)$fatal(1,"ticket record");end
    end
   end
  end
 endtask
 task offer_current;
  begin
   @(negedge clk);c_valid=1;c_op=op;c_account=aa;c_ticket=tk;c_amount=am;c_limit=lim;c_tag=tag;offered=1;
  end
 endtask
 task accept_current;
  begin
   if(!offered)offer_current();do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;offered=0;
  end
 endtask
 task check_store;
  begin
   total=0;for(j=0;j<na;j=j+1)seen_a[j]=0;
   for(i=0;i<A;i=i+1)if(dut.configured[i])begin
    total=total+1;matched=0;
    for(j=0;j<na;j=j+1)if(accts[j]==i)begin
     if(dut.account_ram.mem[i]!=={limits[j],useds[j]})$fatal(1,"stored account %0d",i);
     seen_a[j]=seen_a[j]+1;matched=matched+1;
    end
    if(matched!=1)$fatal(1,"unexpected account");
   end
   if(total!=na)$fatal(1,"configured count");
   for(j=0;j<na;j=j+1)if(seen_a[j]!=1)$fatal(1,"missing account");
   total=0;for(j=0;j<nt;j=j+1)seen_t[j]=0;
   for(i=0;i<K;i=i+1)if(dut.live[i])begin
    total=total+1;row=dut.ticket_ram.mem[i];matched=0;
    for(j=0;j<nt;j=j+1)if(tickets[j]==row[63:0])begin
     if(row[135:128]!==ticket_a[j] || row[127:64]!==amounts[j])$fatal(1,"stored ticket value");
     seen_t[j]=seen_t[j]+1;matched=matched+1;
    end
    if(matched!=1)$fatal(1,"unexpected ticket");
   end
   if(total!=nt || dut.count!=nt || r_live!=nt)$fatal(1,"ticket count");
   for(j=0;j<nt;j=j+1)if(seen_t[j]!=1)$fatal(1,"missing/duplicate ticket");
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");
  reset_core();load_record();
  while(have)begin
   accept_current();
   if(marker==1)begin
    if(phase==0)begin while(dut.state!=2)@(negedge clk);end
    else if(phase==1)begin while(dut.state!=8)@(negedge clk);end
    else if(phase==2 || phase==4)begin while(dut.state!=10)@(negedge clk);end
    else begin while(!r_valid)@(negedge clk);repeat(3)@(negedge clk);end
    reset_core();load_record();
   end else begin
    while(!r_valid)@(posedge clk);
    if(payload!==expected_payload)$fatal(1,"response %0d op%0d status%0d got%h expected%h",commands,r_op,r_status,payload,expected_payload);
    check_store();held=payload;
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready||!busy)$fatal(1,"held response");holds=holds+1;end
    commands=commands+1;load_record();if(have && marker==0)begin offer_current();preoffers=preoffers+1;end
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready)$fatal(1,"future offer corrupted response");holds=holds+1;end
    @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
   end
  end
  repeat(5)@(posedge clk);if(r_valid)$fatal(1,"trailing response");
  $display("PASS pretrade_credit_ledger A=%0d K=%0d T=%0d commands=%0d holds=%0d preoffers=%0d resets=%0d cycles=%0d",A,K,T,commands,holds,preoffers,resets,cycles);$finish;
 end
endmodule
