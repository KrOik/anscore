`timescale 1ns/1ns
module tb_int4_squeeze_excite_frame;
 parameter MC=9,MH=3,MP=7,TW=8,EX=0;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cv=0,bank=0,crr=0,cmdv=0,sv=0,sl=0,mr=0,rr=0;
 reg [1:0] op=0;
 reg [15:0] row=0,wordno=0,scale=0,pixels=0,channels=0,hidden=0;
 reg [31:0] weights=0;
 reg signed [31:0] bias=0;
 reg [4:0] shift=0;
 reg signed [7:0] zero=0,sd=0;
 reg [TW-1:0] tag=0;
 wire cr,crv,cmdr,sr,mv,ml,mi,meanix,pc,pi,gi,gc,rv,busy,bootfault;
 wire [1:0] ce,rs,rc;
 wire [2:0] re;
 wire signed [7:0] md;
 wire [15:0] mx,my;
 wire [8:0] mg;
 wire [TW-1:0] mt,rt;
 wire [23:0] ni,no;
 wire [4:0] phase;
 generate if(EX==0)begin:core_profile
  assign bootfault=0;
  assign phase=dut.state;
  int4_squeeze_excite_frame #(.MAX_CHANNELS(MC),.MAX_HIDDEN(MH),.MAX_PIXELS(MP),.TAG_W(TW)) dut(
   .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cr),.c_bank(bank),.c_op(op),.c_row(row),.c_word(wordno),
   .c_weights(weights),.c_bias(bias),.c_scale(scale),.c_shift(shift),.c_zero(zero),
   .c_rsp_valid(crv),.c_rsp_ready(crr),.c_error(ce),
   .cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_pixels(pixels),.cmd_channels(channels),.cmd_hidden(hidden),.cmd_tag(tag),
   .s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
   .m_valid(mv),.m_ready(mr),.m_data(md),.m_pixel(mx),.m_channel(my),.m_gate(mg),.m_last(ml),.m_tag(mt),
   .m_inexact(mi),.m_mean_inexact(meanix),.m_projection_clip(pc),.m_projection_inexact(pi),
   .m_gate_inexact(gi),.m_gate_clamped(gc),
   .rsp_valid(rv),.rsp_ready(rr),.rsp_error(re),.rsp_stage(rs),.rsp_child_error(rc),
   .rsp_inputs(ni),.rsp_outputs(no),.rsp_tag(rt),.busy(busy));
 end else begin:example_profile
  assign cr=0;assign crv=0;assign ce=0;
  assign phase=dut.core.state;
  rgb_channel_excitation #(.MAX_PIXELS(MP),.TAG_W(TW)) dut(
   .clk(clk),.rst(rst),.cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_pixels(pixels),.cmd_tag(tag),
   .s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
   .m_valid(mv),.m_ready(mr),.m_data(md),.m_pixel(mx),.m_channel(my),.m_gate(mg),.m_last(ml),.m_tag(mt),
   .m_inexact(mi),.m_mean_inexact(meanix),.m_projection_clip(pc),.m_projection_inexact(pi),
   .m_gate_inexact(gi),.m_gate_clamped(gc),
   .rsp_valid(rv),.rsp_ready(rr),.rsp_error(re),.rsp_stage(rs),.rsp_child_error(rc),
   .rsp_inputs(ni),.rsp_outputs(no),.rsp_tag(rt),.boot_fault(bootfault),.busy(busy));
 end endgenerate
 integer fd,n_events,event_index,kind,scanned,i,j,waits,cycles=0;
 integer a,b,c,d,e,f,g,h,k,l,target,ns,ne,err,stage,child,fi0,fi1,fi2,fi3,fi4;
 integer vals[0:262143],lasts[0:262143],expected[0:262143],gates[0:262143],fractions[0:262143];
 integer frames=0,outputs=0,configs=0,resets=0,holds=0,rsp_holds=0,cfg_holds=0;
 integer fractional=0,zero_gates=0,unity_gates=0,half_gates=0;
 reg [2047:0] fixture;
 reg [255:0] held;
 always @(posedge clk)begin
  cycles<=cycles+1;
  if(cycles>4000000)$fatal(1,"watchdog cycles");
  if(bootfault)$fatal(1,"boot fault");
 end
 task reset_core;
 begin
  @(negedge clk);rst=1;cv=0;crr=0;cmdv=0;sv=0;mr=0;rr=0;
  #1;if(cr || crv || cmdr || sr || mv || rv)$fatal(1,"reset transfer gate");
  repeat(3)@(negedge clk);
  rst=0;resets=resets+1;
 end endtask
 task wait_bound;
 begin waits=waits+1;if(waits>500000)$fatal(1,"bounded wait phase=%0d event=%0d",phase,event_index);end
 endtask
 task send_command(input integer p,ch,hd,t);
 begin
  @(negedge clk);pixels=p;channels=ch;hidden=hd;tag=t;cmdv=1;waits=0;
  while(!cmdr)begin wait_bound();@(negedge clk);end
  @(negedge clk);cmdv=0;pixels=16'hffff;channels=16'hffff;hidden=16'hffff;tag=~t;
 end endtask
 task send_samples(input integer count);
 integer z;
 begin
  for(z=0;z<count;z=z+1)begin
   if((z%3)==0)begin @(negedge clk);sv=0;end
   @(negedge clk);sd=vals[z];sl=lasts[z];sv=1;waits=0;
   while(!sr)begin wait_bound();if(rv)$fatal(1,"unexpected early response");@(negedge clk);end
   @(negedge clk);sv=0;sd=8'h55;sl=0;
  end
 end endtask
 task configure(input integer bn,co,r,w,wt,bs,sc,sh,ze,er);
 begin
  @(negedge clk);bank=bn;op=co;row=r;wordno=w;weights=wt;bias=bs;scale=sc;shift=sh;zero=ze;cv=1;crr=0;waits=0;
  while(!cr)begin wait_bound();@(negedge clk);end
  @(negedge clk);cv=0;waits=0;
  while(!crv)begin wait_bound();@(negedge clk);end
  if(ce!==er[1:0])$fatal(1,"config mismatch got=%0d expected=%0d event=%0d",ce,er,event_index);
  held={ce};cmdv=1;pixels=1;channels=1;hidden=1;
  repeat(2)begin @(negedge clk);if(!crv || held!=={254'd0,ce} || cr || cmdr)$fatal(1,"held configuration reply");cfg_holds=cfg_holds+1;end
  cmdv=0;crr=1;@(negedge clk);crr=0;configs=configs+1;
 end endtask
 task collect(input integer p,ch,t,count,er,st,cc);
 integer z;
 begin
  for(z=0;z<count;z=z+1)begin
   waits=0;while(!mv)begin wait_bound();if(rv)$fatal(1,"premature frame response");@(negedge clk);end
   if($signed(md)!==expected[z] || mg!==gates[z][8:0] || mi!==fractions[z][0] || mx!==((z/ch)&65535) ||
       my!==((z%ch)&65535) || mt!==t[TW-1:0] || ml!==(z==count-1) ||
       {meanix,pc,pi,gi,gc}!=={fi0[0],fi1[0],fi2[0],fi3[0],fi4[0]})
    $fatal(1,"output mismatch event=%0d z=%0d data=%0d/%0d gate=%0d/%0d flags=%b expected=%b",event_index,z,$signed(md),expected[z],mg,gates[z],{meanix,pc,pi,gi,gc},{fi0[0],fi1[0],fi2[0],fi3[0],fi4[0]});
   held={md,mx,my,mg,mt,ml,mi,meanix,pc,pi,gi,gc};
   cmdv=1;pixels=1;channels=1;hidden=1;tag=0;
   if(!EX)begin cv=1;bank=0;op=3;row=0;wordno=0;end
   repeat(2)begin @(negedge clk);if(!mv || held!=={md,mx,my,mg,mt,ml,mi,meanix,pc,pi,gi,gc} || cr || cmdr)$fatal(1,"held output ownership");holds=holds+1;end
   cmdv=0;mr=1;@(negedge clk);mr=0;outputs=outputs+1;
   fractional=fractional+mi;zero_gates=zero_gates+(gates[z]==0);unity_gates=unity_gates+(gates[z]==256);half_gates=half_gates+(gates[z]==128);
  end
  waits=0;while(!rv)begin wait_bound();if(mv)$fatal(1,"extra output");@(negedge clk);end
  if(re!==er[2:0] || rs!==st[1:0] || rc!==cc[1:0] || ni!==ns[23:0] || no!==count[23:0] || rt!==t[TW-1:0])
   $fatal(1,"response mismatch event=%0d e=%0d/%0d stage=%0d/%0d child=%0d/%0d in=%0d/%0d out=%0d/%0d",event_index,re,er,rs,st,rc,cc,ni,ns,no,count);
  held={re,rs,rc,ni,no,rt};
  repeat(3)begin @(negedge clk);if(!rv || held!=={re,rs,rc,ni,no,rt} || cr || cmdr || sr)$fatal(1,"held completion");rsp_holds=rsp_holds+1;end
  rr=1;@(negedge clk);rr=0;
  if(cv)begin
   waits=0;while(!cr)begin wait_bound();@(negedge clk);end
   @(negedge clk);cv=0;waits=0;
   while(!crv)begin wait_bound();@(negedge clk);end
   if(ce!==2)$fatal(1,"future configuration lost");crr=1;@(negedge clk);crr=0;configs=configs+1;
  end
  frames=frames+1;
 end endtask
 initial begin
  if(!$value$plusargs("VECTORS=%s",fixture))$fatal(1,"missing fixture");
  fd=$fopen(fixture,"r");if(!fd)$fatal(1,"open fixture");
  scanned=$fscanf(fd,"%d",n_events);if(scanned!=1)$fatal(1,"fixture header");
  for(event_index=0;event_index<n_events;event_index=event_index+1)begin
   scanned=$fscanf(fd,"%d",kind);if(scanned!=1)$fatal(1,"event header");
   case(kind)
    0:reset_core();
    1:begin
     scanned=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",a,b,c,d,e,f,g,h,k,l);
     if(scanned!=10 || EX)$fatal(1,"config fixture");configure(a,b,c,d,e,f,g,h,k,l);
    end
    2:begin
     scanned=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d",a,b,c,d,ns,ne,err,stage,child,fi0,fi1,fi2,fi3,fi4);
     if(scanned!=14 || ns>262144 || ne>262144)$fatal(1,"frame fixture");
     for(i=0;i<ns;i=i+1)begin scanned=$fscanf(fd,"%d %d",vals[i],lasts[i]);if(scanned!=2)$fatal(1,"sample fixture");end
     for(i=0;i<ne;i=i+1)begin scanned=$fscanf(fd,"%d %d %d",expected[i],gates[i],fractions[i]);if(scanned!=3)$fatal(1,"oracle fixture");end
     send_command(a,b,c,d);send_samples(ns);collect(a,b,d,ne,err,stage,child);
    end
    3:begin
     scanned=$fscanf(fd,"%d %d %d %d %d %d",target,a,b,c,d,ns);if(scanned!=6)$fatal(1,"cancel fixture");
     for(i=0;i<ns;i=i+1)begin scanned=$fscanf(fd,"%d %d",vals[i],lasts[i]);if(scanned!=2)$fatal(1,"cancel samples");end
     send_command(a,b,c,d);
     if(target==5)begin
      if(ns>1)send_samples(1);
     end else send_samples(ns);
     if(target==21)mr=1;
     waits=0;while(phase!=target)begin wait_bound();@(negedge clk);end
     reset_core();
    end
    4:begin
     @(negedge clk);cv=1;bank=0;op=0;row=0;wordno=0;weights=0;waits=0;
     while(!cr)begin wait_bound();@(negedge clk);end
     @(negedge clk);cv=0;waits=0;
     while(!crv)begin wait_bound();@(negedge clk);end
     reset_core();
    end
    default:$fatal(1,"unknown event");
   endcase
  end
  scanned=$fscanf(fd,"%d",i);
  if(!((scanned==-1 || scanned==0) && $feof(fd)))$fatal(1,"fixture suffix rc=%0d",scanned);
  $fclose(fd);
  $display("PASS SE MC=%0d MH=%0d MP=%0d TW=%0d EX=%0d frames=%0d outputs=%0d configs=%0d resets=%0d holds=%0d rsp_holds=%0d cfg_holds=%0d fractional=%0d zero_gates=%0d unity_gates=%0d half_gates=%0d",MC,MH,MP,TW,EX,frames,outputs,configs,resets,holds,rsp_holds,cfg_holds,fractional,zero_gates,unity_gates,half_gates);
  $finish;
 end
endmodule
