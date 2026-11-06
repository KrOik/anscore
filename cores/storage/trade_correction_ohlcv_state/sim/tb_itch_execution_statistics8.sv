// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_itch_execution_statistics8;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cv=0,ev=0,rr=0;wire cr,er,rv,configured,faulted,busy;
 reg [3:0] cop=0;reg [15:0] cl=42,el=42;
 reg [63:0] cs=64'h5445535420202020,co=0,cm=0,eo=0,en=0,es=64'h5445535420202020,eseq=0,em=0;
 reg [31:0] cp=0,cq=0,ep=0,eq=0;reg [7:0] ct=0,et=0,kind=0;reg sell=0,printable=1;
 wire admin,isolated,oldv,newv,tv,active,sv;
 wire [7:0] ro,rt;wire [1:0] ws;wire [3:0] os,ts,it,io;
 wire [63:0] request_order,event_sequence,match_id,seq_value;
 wire [31:0] order_count,removed,oldprice,oldqty,newprice,newqty,entries,symbol,price,quantity,count,open_p,high_p,low_p,close_p;
 wire [37:0] volume;wire [69:0] notional;
 wire [886:0] payload={admin,ro,ws,os,ts,isolated,it,io,request_order,event_sequence,order_count,removed,oldv,newv,oldprice,oldqty,newprice,newqty,
  entries,symbol,tv,active,match_id,seq_value,price,quantity,sv,count,volume,notional,open_p,high_p,low_p,close_p,rt,configured,faulted};
 reg [886:0] held;
 itch_execution_statistics8 dut(
  .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(cop),.c_locate(cl),.c_stock(cs),.c_order(co),.c_match(cm),.c_price(cp),.c_quantity(cq),.c_tag(ct),
  .e_valid(ev),.e_ready(er),.e_type(kind),.e_locate(el),.e_order(eo),.e_new_order(en),.e_stock(es),.e_sequence(eseq),.e_match(em),
  .e_sell(sell),.e_printable(printable),.e_price(ep),.e_quantity(eq),.e_tag(et),
  .r_valid(rv),.r_ready(rr),.r_admin(admin),.r_op(ro),.r_wrapper_status(ws),.r_order_status(os),.r_trade_status(ts),
  .r_isolated(isolated),.r_isolation_trade_status(it),.r_isolation_order_status(io),.r_request_order(request_order),.r_event_sequence(event_sequence),
  .r_order_count(order_count),.r_removed(removed),.r_old_valid(oldv),.r_new_valid(newv),.r_old_price(oldprice),.r_old_quantity(oldqty),.r_new_price(newprice),.r_new_quantity(newqty),
  .r_entries(entries),.r_symbol(symbol),.r_trade_valid(tv),.r_active(active),.r_match(match_id),.r_sequence(seq_value),.r_price(price),.r_quantity(quantity),
  .r_stats_valid(sv),.r_count(count),.r_volume(volume),.r_notional(notional),.r_open(open_p),.r_high(high_p),.r_low(low_p),.r_close(close_p),
  .r_tag(rt),.configured(configured),.faulted(faulted),.busy(busy));
 integer accepted=0,checked=0,futures=0,holds=0,blocked=0,resets=0,cancelled=0,event_results=0,trade_adds=0,isolated_results=0,serial=0,watchdog=0;
 integer sn=0,se=0;reg [37:0] svol=0;reg [69:0] snot=0;reg [31:0] sop=0,shi=0,slo=0,scl=0;reg sfault=0,scfg=0;
 reg xa;reg [7:0] xo,xt;reg [63:0] xorder,xseq;
 reg xold=0,xnew=0,xtv=0,xactive=0;
 reg [31:0] xop=0,xoq=0,xnp=0,xnq=0,xremoved=0,xoc=0,xtp=0,xtq=0;
 reg [63:0] xtid=0,xtseq=0;
 task tick;begin @(posedge clk);#1;end endtask
 task wait_result;
  integer k;begin k=0;while(!rv)begin tick();k=k+1;if(k>500)$fatal(1,"example result deadline");end end
 endtask
 task snapshot(input integer retained,trades,input [37:0] vol,input [69:0] notion,input [31:0] o,h,l,c,input f,cfg);
  begin se=retained;sn=trades;svol=vol;snot=notion;sop=o;shi=h;slo=l;scl=c;sfault=f;scfg=cfg;end
 endtask
 task defaults;
  begin xold=0;xnew=0;xop=0;xoq=0;xnp=0;xnq=0;xremoved=0;xoc=0;xtv=0;xactive=0;xtid=0;xtseq=0;xtp=0;xtq=0;end
 endtask
 task launch_admin(input [3:0] operation,input [63:0] key,input [31:0] p,q);
  begin
   @(negedge clk);defaults();cop=operation;cm=key;cp=p;cq=q;co=100;serial=serial+1;ct=serial;
   xa=1;xo={4'd0,operation};xt=ct;xorder=co;xseq=0;cv=1;ev=0;rr=0;
   if(!cr)$fatal(1,"admin admission");tick();@(negedge clk);cv=0;
  end
 endtask
 task launch_event(input [7:0] operation,input [63:0] order_ref,match_ref,audit_seq,input [31:0] p,q,input print);
  begin
   @(negedge clk);defaults();kind=operation;eo=order_ref;em=match_ref;eseq=audit_seq;ep=p;eq=q;printable=print;serial=serial+1;et=serial;
   xa=0;xo=operation;xt=et;xorder=eo;xseq=eseq;ev=1;cv=0;rr=0;
   if(!er)$fatal(1,"event admission");tick();@(negedge clk);ev=0;
  end
 endtask
 task book(input ov,nv,input [31:0] op,oq,np,nq,cut,oc);
  begin xold=ov;xnew=nv;xop=op;xoq=oq;xnp=np;xnq=nq;xremoved=cut;xoc=oc;end
 endtask
 task trade(input enabled,input [63:0] id,seq,input [31:0] p,q);
  begin xtv=1;xactive=enabled;xtid=id;xtseq=seq;xtp=p;xtq=q;end
 endtask
 task summary_check;
  begin if(!sv||symbol!==32'd42||count!==sn||volume!==svol||notional!==snot||open_p!==sop||high_p!==shi||low_p!==slo||close_p!==scl)
   $fatal(1,"summary got n%0d v%0d p%0d OHLC %0d/%0d/%0d/%0d want n%0d v%0d p%0d %0d/%0d/%0d/%0d",count,volume,notional,open_p,high_p,low_p,close_p,sn,svol,snot,sop,shi,slo,scl);end
 endtask
 task finish(input [1:0] ew,input [3:0] eorder,etrade,input iso,stats);
  begin
   wait_result();
   if(admin!==xa||ro!==xo||rt!==xt||request_order!==xorder||event_sequence!==xseq||ws!==ew||os!==eorder||ts!==etrade||isolated!==iso||it!==0||io!==0||configured!==scfg||faulted!==sfault)
    $fatal(1,"identity/status op%0d got ws%0d os%0d ts%0d iso%b cfg%b fault%b",xo,ws,os,ts,isolated,configured,faulted);
   if(oldv!==xold||newv!==xnew||oldprice!==xop||oldqty!==xoq||newprice!==xnp||newqty!==xnq||removed!==xremoved||order_count!==xoc)$fatal(1,"actual order result");
   if(tv!==xtv||active!==xactive||match_id!==xtid||seq_value!==xtseq||price!==xtp||quantity!==xtq)$fatal(1,"retained trade record");
   if(sv!==stats)$fatal(1,"stats presence");if(stats)summary_check();
   if((stats||xtv||etrade!=0)&&entries!==se)$fatal(1,"retained entries");
   if(!stats&&(count!==0||volume!==0||notional!==0||open_p!==0||high_p!==0||low_p!==0||close_p!==0))$fatal(1,"non-summary canonical zeros");
   checked=checked+1;event_results=event_results+!xa;trade_adds=trade_adds+(!xa&&xtv&&xactive);isolated_results=isolated_results+iso;
   held=payload;
   @(negedge clk);cop=3;cm=64'hffffffffffffffff;cp=32'hffffffff;cq=32'hffffffff;co=0;ct=0;cv=1;
   repeat(6)begin tick();holds=holds+1;blocked=blocked+1;if(!rv||cr||er||!busy||payload!==held)$fatal(1,"held response/future ownership");end
   @(negedge clk);rr=1;tick();if(rv)$fatal(1,"retirement");
   @(negedge clk);rr=0;tick();futures=futures+1;
   @(negedge clk);cv=0;wait_result();
   if(!admin||ro!=3||rt!=0||request_order!=0||event_sequence!=0||os!=0||isolated||configured!==scfg||faulted!==sfault)$fatal(1,"future identity");
   if(!scfg)begin if(ws!=1||ts!=0||sv)$fatal(1,"future unconfigured");end
   else if(sfault)begin if(ws!=0||ts!=6||sv||entries!==se)$fatal(1,"future invalid epoch");end
   else begin if(ws!=0||ts!=0||entries!==se)$fatal(1,"future state");summary_check();end
   checked=checked+1;held=payload;
   repeat(6)begin tick();holds=holds+1;if(!rv||cr||er||payload!==held)$fatal(1,"future held");end
   @(negedge clk);rr=1;tick();@(negedge clk);rr=0;
  end
 endtask
 task reset_now;
  integer k;
  begin
   rst=1;cv=0;ev=0;rr=0;tick();if(cr||er||rv||busy||configured||faulted)$fatal(1,"reset gating");
   @(negedge clk);rst=0;resets=resets+1;k=0;
   while(!cr)begin tick();k=k+1;if(k>20)$fatal(1,"hash initialization deadline");end
   snapshot(0,0,0,0,0,0,0,0,0,0);
  end
 endtask
 task config_clean;
  begin launch_admin(0,0,0,0);snapshot(0,0,0,0,0,0,0,0,0,1);finish(0,0,0,0,0);end
 endtask
 task reset_cut(input integer phase);
  integer steps;
  begin
   if(phase==2||phase==3)begin launch_event("A",900,0,0,100,1,1);book(0,1,0,0,100,1,0,1);finish(0,0,0,0,0);end
   if(phase==0)launch_admin(0,0,0,0);
   else if(phase==1)launch_event("A",900,0,0,100,1,1);
   else if(phase==4)launch_admin(3,0,0,0);
   else launch_event("E",900,900,900,0,1,1);
   steps=0;
   while(!((phase==0&&dut.phase==1&&dut.state==3)||
           (phase==1&&dut.phase==6&&dut.orders.sides[0].orders.state==4)||
           (phase==2&&dut.phase==7&&dut.trades.state==5)||
           (phase==3&&dut.phase==7&&dut.trades.state==9)||
           (phase==4&&rv)))begin
    @(negedge clk);steps=steps+1;if(steps>500)$fatal(1,"missing actual reset cut %0d",phase);
   end
   if(phase==4)begin held=payload;repeat(3)begin tick();holds=holds+1;if(!rv||payload!==held)$fatal(1,"cancelled held result");end @(negedge clk);end
   reset_now();cancelled=cancelled+1;config_clean();
  end
 endtask
 integer i;
 initial begin
  @(negedge clk);reset_now();
  launch_admin(3,0,0,0);finish(1,0,0,0,0);
  config_clean();
  launch_event("A",100,0,1,100,10,1);book(0,1,0,0,100,10,0,1);finish(0,0,0,0,0);
  launch_event("E",100,1000,2,0,4,1);book(1,1,100,10,100,6,4,1);trade(1,1000,2,100,4);snapshot(1,1,4,400,100,100,100,100,0,1);finish(0,0,0,0,1);
  launch_event("C",100,1001,3,140,2,0);book(1,1,100,6,100,4,2,1);finish(0,0,0,0,0);
  launch_event("C",100,1002,4,90,2,1);book(1,1,100,4,100,2,2,1);trade(1,1002,4,90,2);snapshot(2,2,6,580,100,100,90,90,0,1);finish(0,0,0,0,1);
  launch_admin(6,0,0,0);book(1,1,100,2,100,2,0,1);finish(0,0,0,0,0);
  launch_admin(5,1000,110,3);trade(1,1000,2,110,3);snapshot(2,2,5,510,110,110,90,90,0,1);finish(0,0,0,0,1);
  launch_admin(4,1000,0,0);trade(0,1000,2,110,3);snapshot(2,1,2,180,90,90,90,90,0,1);finish(0,0,0,0,1);
  launch_admin(2,1000,0,0);trade(0,1000,2,110,3);finish(0,0,0,0,0);
  launch_admin(5,1000,1,1);finish(0,0,5,0,0);
  launch_admin(4,64'hffffffffffffffff,0,0);finish(0,0,4,0,0);
  launch_event("E",100,1000,5,0,1,1);book(1,1,100,2,100,1,1,1);sfault=1;finish(0,0,2,1,0);
  launch_admin(6,0,0,0);xoc=1;finish(0,3,0,0,0);
  config_clean();
  launch_event("A",200,0,6,100,9,1);book(0,1,0,0,100,9,0,1);finish(0,0,0,0,0);
  for(i=0;i<8;i=i+1)begin
   launch_event("E",200,i,10+i,0,1,1);book(1,1,100,9-i,100,8-i,1,1);trade(1,i,10+i,100,1);
   snapshot(i+1,i+1,i+1,100*(i+1),100,100,100,100,0,1);finish(0,0,0,0,1);
  end
  launch_event("E",200,99,18,0,1,1);book(1,0,100,1,0,0,1,0);sfault=1;finish(0,0,3,1,0);
  launch_admin(1,0,0,0);snapshot(0,0,0,0,0,0,0,0,0,1);finish(0,0,0,0,0);
  launch_admin(4,0,0,0);finish(0,0,4,0,0);
  launch_event("A",300,0,20,32'hffffffff,32'hffffffff,1);book(0,1,0,0,32'hffffffff,32'hffffffff,0,1);finish(0,0,0,0,0);
  launch_event("E",300,64'hffffffffffffffff,64'hffffffffffffffff,0,32'hffffffff,1);
  book(1,0,32'hffffffff,32'hffffffff,0,0,32'hffffffff,0);trade(1,64'hffffffffffffffff,64'hffffffffffffffff,32'hffffffff,32'hffffffff);
  snapshot(1,1,38'd4294967295,70'd18446744065119617025,32'hffffffff,32'hffffffff,32'hffffffff,32'hffffffff,0,1);finish(0,0,0,0,1);
  launch_admin(4,64'hffffffffffffffff,0,0);trade(0,64'hffffffffffffffff,64'hffffffffffffffff,32'hffffffff,32'hffffffff);snapshot(1,0,0,0,0,0,0,0,0,1);finish(0,0,0,0,1);
  launch_event("A",400,0,21,0,1,1);book(0,1,0,0,0,1,0,1);finish(0,0,0,0,0);
  launch_event("E",400,0,0,0,1,1);book(1,0,0,1,0,0,1,0);trade(1,0,0,0,1);snapshot(2,1,1,0,0,0,0,0,0,1);finish(0,0,0,0,1);
  launch_admin(3,0,0,0);finish(0,0,0,0,1);
  launch_admin(7,0,0,0);sfault=1;finish(0,0,0,1,0);
  config_clean();
  for(i=0;i<5;i=i+1)reset_cut(i);
  $display("PASS itch_execution_statistics8 accepted=%0d checked=%0d futures=%0d holds=%0d blocked=%0d resets=%0d cancelled=%0d event_results=%0d trade_adds=%0d isolated_results=%0d",accepted,checked,futures,holds,blocked,resets,cancelled,event_results,trade_adds,isolated_results);$finish;
 end
 always @(posedge clk)begin
  if(!rst&&((cv&&cr)||(ev&&er)))accepted=accepted+1;
  watchdog=watchdog+1;if(watchdog>100000)$fatal(1,"example watchdog");
 end
endmodule
