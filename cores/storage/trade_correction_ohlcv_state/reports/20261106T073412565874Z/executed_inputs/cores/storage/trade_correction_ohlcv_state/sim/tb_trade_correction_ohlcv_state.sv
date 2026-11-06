// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_trade_correction_ohlcv_state;
 parameter integer N=7,T=8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cv=0,rr=0;wire cr,rv,busy,faulted;
 reg [3:0] op=0;reg [31:0] symbol=0,price=0,quantity=0;
 reg [63:0] match_id=0,seq_value=0;reg [T-1:0] tag=0;
 wire [3:0] ro,rs;wire [31:0] entries,rsymbol,rprice,rquantity,count,open_p,high_p,low_p,close_p;
 wire tv,active,sv;wire [63:0] rmatch,rsequence;wire [37:0] volume;wire [69:0] notional;wire [T-1:0] rtag;
 wire [535+T:0] response={ro,rs,entries,rsymbol,tv,active,rmatch,rsequence,rprice,rquantity,sv,count,volume,notional,open_p,high_p,low_p,close_p,faulted,rtag};
 reg [535+T:0] expected,future_expected,held;
 reg [31:0] future_symbol;
 integer accepted=0,checked=0,holds=0,preoffers=0,futures=0,resets=0,cancelled=0,watchdog=0;
 trade_correction_ohlcv_state #(.ENTRIES(N),.TAG_W(T)) dut(
  .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(op),.c_symbol(symbol),.c_match(match_id),.c_sequence(seq_value),
  .c_price(price),.c_quantity(quantity),.c_tag(tag),.r_valid(rv),.r_ready(rr),.r_op(ro),.r_status(rs),
  .r_entries(entries),.r_symbol(rsymbol),.r_trade_valid(tv),.r_active(active),.r_match(rmatch),.r_sequence(rsequence),
  .r_price(rprice),.r_quantity(rquantity),.r_stats_valid(sv),.r_count(count),.r_volume(volume),.r_notional(notional),
  .r_open(open_p),.r_high(high_p),.r_low(low_p),.r_close(close_p),.r_tag(rtag),.faulted(faulted),.busy(busy));
 task tick;begin @(posedge clk);#1;end endtask
 task reset_here;
  begin rst=1;cv=0;rr=0;tick();if(cr||rv||busy||faulted)$fatal(1,"reset gate");
   @(negedge clk);rst=0;tick();resets=resets+1;if(!cr||rv||busy||faulted)$fatal(1,"reset idle");end
 endtask
 task reset;begin @(negedge clk);reset_here();end endtask
 task transact;
  integer latency;
  begin
   @(negedge clk);cv=1;rr=0;if(!cr)$fatal(1,"admission");tick();
   @(negedge clk);op=4;symbol=future_symbol;match_id=64'hffffffffffffffff;seq_value=64'hffffffffffffffff;price=32'hffffffff;quantity=32'hffffffff;tag=0;
   latency=0;
   while(!rv)begin if(cr)$fatal(1,"early future admission");tick();preoffers=preoffers+1;latency=latency+1;if(latency>5*N+8)$fatal(1,"first valid budget");end
   if(response!==expected)$fatal(1,"response %0d got=%h want=%h",checked,response,expected);
   checked=checked+1;held=response;
   repeat(6)begin tick();holds=holds+1;preoffers=preoffers+1;if(!rv||cr||!busy||response!==held)$fatal(1,"held result");end
   @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"retire");
   @(negedge clk);rr=0;tick();futures=futures+1;
   @(negedge clk);cv=0;latency=0;
   while(!rv)begin tick();latency=latency+1;if(latency>5*N+8)$fatal(1,"future budget");end
   if(response!==future_expected)$fatal(1,"actual future QUERY got=%h want=%h",response,future_expected);
   checked=checked+1;held=response;
   repeat(6)begin tick();holds=holds+1;if(!rv||cr||!busy||response!==held)$fatal(1,"future hold");end
   @(negedge clk);rr=1;tick();if(rv||!cr)$fatal(1,"future retire");@(negedge clk);rr=0;
  end
 endtask
 task directed(input integer seed);
  begin
   op=seed?0:3;symbol=0;match_id=100;seq_value=1;price=100;quantity=1;tag=1;future_symbol=0;
   if(seed)begin
    expected={4'd0,4'd0,32'd1,32'd0,1'b1,1'b1,64'd100,64'd1,32'd100,32'd1,1'b1,32'd1,38'd1,70'd100,32'd100,32'd100,32'd100,32'd100,1'b0,{{(T-1){1'b0}},1'b1}};
    future_expected={4'd4,4'd0,32'd1,32'd0,2'b0,128'd0,64'd0,1'b1,32'd1,38'd1,70'd100,32'd100,32'd100,32'd100,32'd100,1'b0,{T{1'b0}}};
   end else begin
    expected={4'd3,4'd4,32'd0,32'd0,2'b0,128'd0,64'd0,1'b0,32'd0,38'd0,70'd0,128'd0,1'b0,{{(T-1){1'b0}},1'b1}};
    future_expected={4'd4,4'd0,32'd0,32'd0,2'b0,128'd0,64'd0,1'b1,32'd0,38'd0,70'd0,128'd0,1'b0,{T{1'b0}}};
   end
   transact();
  end
 endtask
 task reset_cut(input integer phase);
  integer wanted,steps;
  begin
   directed(1);
   @(negedge clk);op=2;symbol=0;match_id=100;seq_value=0;price=32'hffffffff;quantity=32'hffffffff;tag=0;cv=1;tick();
   @(negedge clk);cv=0;wanted=phase==0?1:phase==1?2:phase==2?5:phase==3?9:10;steps=0;
   while(dut.state!=wanted)begin @(negedge clk);steps=steps+1;if(steps>5*N+8)$fatal(1,"reset cut %0d unreachable",phase);end
   if(phase==4)begin held=response;repeat(3)begin tick();holds=holds+1;if(!rv||response!==held)$fatal(1,"cancelled held response");end end
   if(phase==4)@(negedge clk);
   reset_here();cancelled=cancelled+1;directed(0);
  end
 endtask
 integer fd,ret,kind,i;reg [2047:0] vector_file;
 initial begin
  if(!$value$plusargs("vectors=%s",vector_file))$fatal(1,"vectors missing");
  fd=$fopen(vector_file,"r");if(!fd)$fatal(1,"open");reset();
  while(!$feof(fd))begin ret=$fscanf(fd,"%d",kind);if(ret==1)begin
   if(kind==1)reset();else begin
    ret=$fscanf(fd,"%d %d %d %d %d %d %d %h %h %d\n",op,symbol,match_id,seq_value,price,quantity,tag,expected,future_expected,future_symbol);
    if(ret!=10)$fatal(1,"parse");transact();
   end
  end end
  $fclose(fd);for(i=0;i<5;i=i+1)reset_cut(i);
  $display("PASS trade_correction_ohlcv_state N=%0d T=%0d accepted=%0d checked=%0d holds=%0d preoffers=%0d futures=%0d resets=%0d cancelled=%0d",N,T,accepted,checked,holds,preoffers,futures,resets,cancelled);$finish;
 end
 always @(posedge clk)begin
  if(!rst&&cv&&cr)accepted=accepted+1;
  watchdog=watchdog+1;if(watchdog>500000)$fatal(1,"watchdog");
 end
endmodule
