`timescale 1ns/1ps
module tb_position_limit_reservations;
 parameter A=3,K=5,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,c_valid=0,r_ready=0;
 wire c_ready,r_valid,busy,faulted;
 reg [2:0] c_op=0;reg [31:0] c_context=0,c_quantity=0;
 reg [63:0] c_ticket=0;reg c_buy=0;
 reg signed [63:0] c_position=0,c_min_position=0,c_max_position=0;
 reg [T-1:0] c_tag=0;
 wire [2:0] r_op;wire [3:0] r_status;wire [31:0] r_context,r_remaining;
 wire [63:0] r_ticket;wire r_buy;
 wire signed [63:0] r_position,r_min_position,r_max_position;
 wire [37:0] r_buy_open,r_sell_open;wire [31:0] r_live;wire [T-1:0] r_tag;
 position_limit_reservations #(.CONTEXTS(A),.TICKETS(K),.TAG_W(T)) dut(.*);
 wire [436+T:0] payload={r_op,r_status,r_context,r_ticket,r_buy,r_remaining,r_position,r_min_position,r_max_position,r_buy_open,r_sell_open,r_live,r_tag,faulted};
 wire [323+T:0] source_payload={c_op,c_context,c_ticket,c_buy,c_quantity,c_position,c_min_position,c_max_position,c_tag};
 reg [436+T:0] expected_payload,held;
 reg [323+T:0] source_held;
 reg was_blocked=0,have=0,offered=0;
 integer fd,rv,marker,phase,op,side,i,j,na,nt,matched,total,waited;
 reg [31:0] aa,qty;
 reg [63:0] tk;reg signed [63:0] pos,lower,upper;
 integer contexts[0:A-1],seen_a[0:A-1],ticket_contexts[0:K-1],ticket_sides[0:K-1],seen_t[0:K-1];
 reg signed [63:0] positions[0:A-1],lowers[0:A-1],uppers[0:A-1];
 reg [37:0] buys[0:A-1],sells[0:A-1];
 reg [63:0] tickets[0:K-1];reg [31:0] quantities[0:K-1];reg [103:0] row;
 reg [T-1:0] tag;
 integer cycles=0,commands=0,holds=0,preoffers=0,future_queries=0,resets=0;
 string vectors;
 always @(negedge clk)begin cycles=cycles+1;if(cycles>1000000)$fatal(1,"cycle watchdog");end
 always @(posedge clk)if(rst_n)begin
  if(was_blocked&&(!c_valid||source_payload!==source_held))$fatal(1,"blocked source changed");
  was_blocked=c_valid&&!c_ready;source_held=source_payload;
 end
 task reset_core;
  begin
   rst_n=0;c_valid=0;r_ready=0;offered=0;was_blocked=0;
   #1;if(c_ready||r_valid||busy)$fatal(1,"reset masking");
   repeat(2)@(posedge clk);@(negedge clk);rst_n=1;resets=resets+1;
   @(posedge clk);if(!c_ready||r_valid||faulted||dut.live!=0||dut.configured!=0||dut.count!=0)$fatal(1,"reset epoch");
  end
 endtask
 task load_record;
  begin
   rv=$fscanf(fd,"%d",marker);have=rv==1;
   if(have)begin
    if(marker==1)begin rv=$fscanf(fd,"%d",phase);if(rv!=1)$fatal(1,"reset record");end
    else if(marker!=0)$fatal(1,"marker");
    rv=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",op,aa,tk,side,qty,pos,lower,upper,tag);if(rv!=9)$fatal(1,"command record");
    if(marker==0)begin
     rv=$fscanf(fd,"%d %d %d",expected_payload,na,nt);if(rv!=3||na>A||nt>K)$fatal(1,"expectation record");
     for(j=0;j<na;j=j+1)begin rv=$fscanf(fd,"%d %d %d %d %d %d",contexts[j],positions[j],lowers[j],uppers[j],buys[j],sells[j]);if(rv!=6)$fatal(1,"context record");end
     for(j=0;j<nt;j=j+1)begin rv=$fscanf(fd,"%d %d %d %d",tickets[j],ticket_contexts[j],ticket_sides[j],quantities[j]);if(rv!=4)$fatal(1,"ticket record");end
    end
   end
  end
 endtask
 task offer_current;
  begin
   @(negedge clk);c_valid=1;c_op=op;c_context=aa;c_ticket=tk;c_buy=side;c_quantity=qty;
   c_position=pos;c_min_position=lower;c_max_position=upper;c_tag=tag;offered=1;
  end
 endtask
 task accept_current;
  begin
   if(!offered)offer_current();waited=0;
   do begin @(posedge clk);waited=waited+1;if(waited>3)$fatal(1,"admission bound");end while(!c_ready);
   @(negedge clk);c_valid=0;offered=0;
  end
 endtask
 task check_store;
  begin
   total=0;for(j=0;j<na;j=j+1)seen_a[j]=0;
   for(i=0;i<A;i=i+1)if(dut.configured[i])begin
    total=total+1;matched=0;
    for(j=0;j<na;j=j+1)if(contexts[j]==i)begin
     if(dut.context_ram.mem[i]!=={4'd0,positions[j],lowers[j],uppers[j],buys[j],sells[j]})$fatal(1,"stored context %0d command %0d",i,commands);
     seen_a[j]=seen_a[j]+1;matched=matched+1;
    end
    if(matched!=1)$fatal(1,"unexpected context");
   end
   if(total!=na)$fatal(1,"configured count");
   for(j=0;j<na;j=j+1)if(seen_a[j]!=1)$fatal(1,"missing context");
   total=0;for(j=0;j<nt;j=j+1)seen_t[j]=0;
   for(i=0;i<K;i=i+1)if(dut.live[i])begin
    total=total+1;row=dut.ticket_ram.mem[i];matched=0;
    for(j=0;j<nt;j=j+1)if(tickets[j]==row[63:0])begin
     if(row!=={3'd0,ticket_contexts[j][3:0],ticket_sides[j][0],quantities[j],tickets[j]})$fatal(1,"stored ticket value");
     seen_t[j]=seen_t[j]+1;matched=matched+1;
    end
    if(matched!=1)$fatal(1,"unexpected ticket");
   end
   if(total!=nt||dut.count!=nt||r_live!=nt)$fatal(1,"ticket count");
   for(j=0;j<nt;j=j+1)if(seen_t[j]!=1)$fatal(1,"missing/duplicate ticket");
  end
 endtask
 initial begin
  if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"vectors required");fd=$fopen(vectors,"r");if(!fd)$fatal(1,"file missing");
  reset_core();load_record();
  while(have)begin
   accept_current();waited=0;
   if(marker==1)begin
    while(!((phase==0&&dut.state==2)||(phase==1&&dut.state==4)||(phase==2&&dut.state==7)||
            (phase==3&&dut.state==9)||(phase==4&&r_valid)))begin
     @(negedge clk);waited=waited+1;if(waited>2*K+16)$fatal(1,"reset phase not reached %0d",phase);
    end
    if(phase==4)repeat(3)@(negedge clk);
    reset_core();load_record();
   end else begin
    while(!r_valid)begin @(posedge clk);waited=waited+1;if(waited>2*K+16)$fatal(1,"service bound");end
    if(payload!==expected_payload)$fatal(1,"response %0d op%0d status%0d got%h expected%h",commands,r_op,r_status,payload,expected_payload);
    check_store();held=payload;
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready||!busy)$fatal(1,"held response");holds=holds+1;end
    commands=commands+1;load_record();if(have&&marker==0)begin offer_current();preoffers=preoffers+1;if(op==4)future_queries=future_queries+1;end
    repeat(3)begin @(posedge clk);if(!r_valid||payload!==held||c_ready)$fatal(1,"future offer corrupted response");holds=holds+1;end
    @(negedge clk);r_ready=1;@(posedge clk);@(negedge clk);r_ready=0;
   end
  end
  repeat(5)@(posedge clk);if(r_valid)$fatal(1,"trailing response");$fclose(fd);
  if(future_queries<180)$fatal(1,"missing actual future GET_CONTEXT");
  $display("PASS position_limit_reservations A=%0d K=%0d T=%0d commands=%0d holds=%0d preoffers=%0d future_queries=%0d resets=%0d cycles=%0d",A,K,T,commands,holds,preoffers,future_queries,resets,cycles);$finish;
 end
endmodule
