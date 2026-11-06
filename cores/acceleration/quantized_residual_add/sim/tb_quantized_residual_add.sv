// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_quantized_residual_add;
 parameter C=3,P=17,T=8,EX=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1;
 reg cv=0;wire cr;reg [1:0] cop=0;reg [15:0] cc=0,sa=0,sb=0;
 reg [4:0] sh=0;reg [7:0] za=0,zb=0;reg signed [7:0] zo=0,lo=-128,hi=127;
 wire cvalid;reg cready=0;wire [1:0] cerr;
 reg cmdv=0;wire cmdr;reg [15:0] np=0,nc=0;reg [T-1:0] tag=0;
 reg av=0,bv=0,al=0,bl=0;reg [7:0] ad=0,bd=0;wire ar,br;
 wire mv;reg mr=0;wire signed [7:0] md;wire [15:0] mp,mc;wire ml,mclip,mix;
 wire [T-1:0] mt,rt;wire rv;reg rr=0;wire [1:0] re;wire [31:0] ro;
 wire ba,bb,busy;
 generate if(EX==0)begin:core_case
  quantized_residual_add #(.MAX_CHANNELS(C),.MAX_PIXELS(P),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_op(cop),.c_channel(cc),
   .c_scale_a(sa),.c_scale_b(sb),.c_shift(sh),.c_zero_a(za),.c_zero_b(zb),.c_zero_out(zo),.c_min(lo),.c_max(hi),
   .c_rsp_valid(cvalid),.c_rsp_ready(cready),.c_error(cerr),
   .cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_pixels(np),.cmd_channels(nc),.cmd_tag(tag),
   .a_valid(av),.a_ready(ar),.a_data(ad),.a_last(al),.b_valid(bv),.b_ready(br),.b_data(bd),.b_last(bl),
   .m_valid(mv),.m_ready(mr),.m_data(md),.m_pixel(mp),.m_channel(mc),.m_last(ml),.m_tag(mt),.m_clip(mclip),.m_inexact(mix),
   .rsp_valid(rv),.rsp_ready(rr),.rsp_error(re),.rsp_outputs(ro),.rsp_tag(rt),.rsp_bad_a(ba),.rsp_bad_b(bb),.busy(busy));
 end else begin:example_case
  signed8_residual #(.MAX_PIXELS(P),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_pixels(np),.cmd_tag(tag),
   .a_valid(av),.a_ready(ar),.a_data(ad),.a_last(al),.b_valid(bv),.b_ready(br),.b_data(bd),.b_last(bl),
   .m_valid(mv),.m_ready(mr),.m_data(md),.m_pixel(mp),.m_last(ml),.m_tag(mt),.m_clip(mclip),.m_inexact(mix),
   .rsp_valid(rv),.rsp_ready(rr),.rsp_error(re),.rsp_outputs(ro),.rsp_tag(rt));
  assign mc=0;assign cr=0;assign cvalid=0;assign cerr=0;assign ba=0;assign bb=0;assign busy=0;
 end endgenerate
 integer cycles=0,outputs=0,configs=0,frames=0,pairs=0,resets=0,holds=0,latencies=0,iis=0,clips=0,inexacts=0;
 reg old_m=0,old_r=0,old_c=0;
 reg [8+16+16+1+T+2-1:0] held_m;
 reg [2+32+T+2-1:0] held_r;
 reg [1:0] held_c;
 always @(posedge clk)begin
  cycles=cycles+1;
  if(rst)begin old_m=0;old_r=0;old_c=0;end
  else begin
   if(old_m && (!mv || {md,mp,mc,ml,mt,mclip,mix}!==held_m))$fatal(1,"output changed while held");
   if(old_r && (!rv || {re,ro,rt,ba,bb}!==held_r))$fatal(1,"completion changed while held");
   if(old_c && (!cvalid || cerr!==held_c))$fatal(1,"config changed while held");
   old_m=mv&&!mr;old_r=rv&&!rr;old_c=cvalid&&!cready;
   held_m={md,mp,mc,ml,mt,mclip,mix};held_r={re,ro,rt,ba,bb};held_c=cerr;
   if(old_m || old_r || old_c)holds=holds+1;
   if(mv && rv)$fatal(1,"completion before final output retirement");
   if((mv||rv||cvalid) && cmdr)$fatal(1,"ownership escaped while response pending");
   if((mv||rv) && (ar||br||cr))$fatal(1,"data/config accepted while output or completion held");
  end
 end
 task reset_core;
  begin
   @(negedge clk);rst=1;cv=0;cmdv=0;av=0;bv=0;mr=0;rr=0;cready=0;
   #1;if(cr||cmdr||ar||br||mv||rv||cvalid)$fatal(1,"reset did not gate public handshakes");
   repeat(3)@(negedge clk);rst=0;resets=resets+1;
   repeat(3)@(negedge clk);
   if(mv||rv||cvalid)$fatal(1,"cancelled result leaked after reset");
  end
 endtask
 task configure(input integer op,ch,xsa,xsb,xsh,xza,xzb,xzo,xlo,xhi,expected);
  begin
   @(negedge clk);cv=1;cop=op;cc=ch;sa=xsa;sb=xsb;sh=xsh;za=xza;zb=xzb;zo=xzo;lo=xlo;hi=xhi;cready=0;
   cmdv=1;np=0;nc=0;#1;if(cmdr)$fatal(1,"configuration priority failed");
   do @(posedge clk);while(!cr);
   @(negedge clk);cv=0;cmdv=0;
   while(!cvalid)@(negedge clk);
   if(cerr!==expected[1:0])$fatal(1,"config error %0d expected%0d",cerr,expected);
   repeat(3)@(negedge clk);
   cready=1;@(posedge clk);@(negedge clk);cready=0;configs=configs+1;
  end
 endtask
 task command(input integer pix,ch,tg);
  begin
   @(negedge clk);np=pix;nc=ch;tag=tg;cmdv=1;rr=0;
   do @(posedge clk);while(!cmdr);
   @(negedge clk);cmdv=0;
  end
 endtask
 integer later_edge;
 task send_pair(input integer a,b,la,lb,ordinal,mode);
  integer senta,sentb,gapa,gapb,steps;
  begin
   senta=0;sentb=0;steps=0;gapa=mode==1?0:(ordinal%4);gapb=mode==1?0:((ordinal*3+1)%5);
   ad=a;bd=b;al=la;bl=lb;
   while(!senta || !sentb)begin
    @(negedge clk);av=!senta && steps>=gapa;bv=!sentb && steps>=gapb;
    @(posedge clk);
    if(av&&ar)begin senta=1;later_edge=$time/10;end
    if(bv&&br)begin sentb=1;later_edge=$time/10;end
    steps=steps+1;
   end
   @(negedge clk);av=0;bv=0;pairs=pairs+1;
  end
 endtask
 task completion(input integer er,no,xba,xbb,tg);
  begin
   while(!rv)@(negedge clk);
   if(re!==er[1:0] || ro!==no || rt!==tg[T-1:0] || (EX==0 && {ba,bb}!=={xba[0],xbb[0]}))
    $fatal(1,"completion got e%0d n%0d a%0d b%0d tag%0d expected e%0d n%0d a%0d b%0d tag%0d",re,ro,ba,bb,rt,er,no,xba,xbb,tg);
   repeat(3)@(negedge clk);rr=1;@(posedge clk);@(negedge clk);rr=0;
  end
 endtask
 // Cancellation of config, one-sided joins, products, quantizer, data and DONE.
 task cancel_case(input integer kind);
  begin
   reset_core();
   if(kind==0 && EX==0)begin
    @(negedge clk);cv=1;cop=0;cc=0;sa=1;sb=1;sh=0;za=128;zb=128;zo=0;lo=-128;hi=127;
    do @(posedge clk);while(!cr);
    @(negedge clk);cv=0;while(!cvalid)@(negedge clk);
   end else begin
    if(EX==0)configure(0,0,1,1,0,128,128,0,-128,127,0);
    command(1,1,0);
    while(!ar || !br)@(negedge clk);
    if(kind==1)begin av=1;ad=129;al=1;@(posedge clk);@(negedge clk);av=0;repeat(3)@(negedge clk);end
    else if(kind==2)begin bv=1;bd=127;bl=1;@(posedge clk);@(negedge clk);bv=0;repeat(3)@(negedge clk);end
    else begin
     send_pair(EX==0?129:1,EX==0?127:-1,1,1,0,1);
     if(kind==3)repeat(3)@(negedge clk);
     else if(kind==4)repeat(7)@(negedge clk);
     else begin
      while(!mv)@(negedge clk);repeat(3)@(negedge clk);
      if(kind==6)begin mr=1;@(posedge clk);@(negedge clk);mr=0;while(!rv)@(negedge clk);repeat(3)@(negedge clk);end
     end
    end
   end
   reset_core();
  end
 endtask
 string path,op;integer fd,rc;
 integer x0,x1,x2,x3,x4,x5,x6,x7,x8,x9,x10;
 integer pix,ch,tg,er,no,xba,xbb,nrows,mode,i,j;
 integer aa,bbv,la,lb,ey,ec,ei,previous_edge;
 initial begin
  if(!$value$plusargs("vectors=%s",path))$fatal(1,"missing vectors");
  fd=$fopen(path,"r");if(!fd)$fatal(1,"open vectors");reset_core();
  while(!$feof(fd))begin
   rc=$fscanf(fd,"%s",op);
   if(rc==1)begin
    if(op=="C")begin
     rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",x0,x1,x2,x3,x4,x5,x6,x7,x8,x9,x10);
     if(rc!=11 || EX!=0)$fatal(1,"bad config vector");
     configure(x0,x1,x2,x3,x4,x5,x6,x7,x8,x9,x10);
    end else if(op=="R")begin rc=$fscanf(fd,"%d",x0);if(rc!=1)$fatal(1,"bad reset");cancel_case(x0);end
    else if(op=="F")begin
     rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",pix,ch,tg,er,no,xba,xbb,nrows,mode);
     if(rc!=9)$fatal(1,"bad frame vector");
     mr=mode==1;command(pix,ch,tg);previous_edge=-1;frames=frames+1;
     for(i=0;i<nrows;i=i+1)begin
      rc=$fscanf(fd,"%s %d %d %d %d %d %d %d",op,aa,bbv,la,lb,ey,ec,ei);
      if(rc!=8 || op!="S")$fatal(1,"bad sample vector");
      send_pair(aa,bbv,la,lb,i,mode);
      if(i<no)begin
       if(mode==1)begin
        do @(posedge clk);while(!mv);
        if($time/10-later_edge!=10)$fatal(1,"pair latency %0d expected10",$time/10-later_edge);
        latencies=latencies+1;
        if(previous_edge>=0)begin
         if($time/10-previous_edge!=11)$fatal(1,"pair II %0d expected11",$time/10-previous_edge);
         iis=iis+1;
        end
        previous_edge=$time/10;
       end else begin
        while(!mv)@(negedge clk);repeat(2+i%3)@(negedge clk);
       end
       if($signed(md)!=ey || mp!==i/ch || mc!==i%ch || ml!==(i==pix*ch-1) || mt!==tg[T-1:0] || mclip!==ec[0] || mix!==ei[0])
        $fatal(1,"numeric i%0d got y%0d p%0d c%0d l%0d clip%0d ix%0d expected y%0d clip%0d ix%0d",i,$signed(md),mp,mc,ml,mclip,mix,ey,ec,ei);
       if(mode==0)begin mr=1;@(posedge clk);end
       outputs=outputs+1;clips=clips+ec;inexacts=inexacts+ei;
       // Mode1 retains ready and starts the next pair at the immediate next edge.
       if(mode==0)begin @(negedge clk);mr=0;end
      end
     end
     completion(er,no,xba,xbb,tg);mr=0;
    end else $fatal(1,"unknown vector directive %s",op);
   end
  end
  $fclose(fd);repeat(5)@(negedge clk);if(mv||rv||cvalid)$fatal(1,"extra response");
  $display("PASS quantized_residual_add C=%0d P=%0d T=%0d EX=%0d outputs=%0d configs=%0d frames=%0d pairs=%0d resets=%0d holds=%0d latencies=%0d iis=%0d clips=%0d inexact=%0d",C,P,T,EX,outputs,configs,frames,pairs,resets,holds,latencies,iis,clips,inexacts);
  $finish;
 end
 initial begin #100000000;$fatal(1,"finite TB watchdog");end
endmodule
