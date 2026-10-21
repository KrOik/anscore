
`timescale 1ns/1ps
module tb_dehaze_group;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,ce=1;
integer cycle=0;
always @(negedge clk) begin
  cycle=cycle+1;
  ce=((cycle%11)!=3 && (cycle%11)!=4);
end
wire mr=(cycle%7)!=2 && (cycle%7)!=3;
reg gc=0,gv=0,gs=0,ge=0;
reg [15:0] gw=0,gh=0,gp=0;reg [3:0] gr=0;reg [31:0] eps=0;
reg [7:0] gi=0;reg [15:0] gtag=0;
wire gcr,gsr,gmv,gms,gme,gmf,grv;wire [15:0] gq,gmt,grt;wire [3:0] gre;
img_dh_guided_frame #(.MAX_WIDTH(4),.MAX_HEIGHT(4),.MAX_RADIUS(2)) ug(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(gc),.cmd_ready(gcr),
 .cmd_width(gw),.cmd_height(gh),.cmd_radius(gr),.cmd_epsilon(eps),.cmd_tag(gtag),
 .s_guide(gi),.s_p(gp),.s_valid(gv),.s_sof(gs),.s_eol(ge),.s_ready(gsr),
 .m_q(gq),.m_valid(gmv),.m_sof(gms),.m_eol(gme),.m_eof(gmf),.m_ready(mr),.m_tag(gmt),
 .rsp_valid(grv),.rsp_ready(mr),.rsp_error(gre),.rsp_tag(grt),.busy());
reg dc=0,dv=0,ds=0,de=0,da=0,df=0;
reg [15:0] dw=0,dh=0,om=0,t0=0,dtag=0;
reg [3:0] dr=0,dgr=0;reg [31:0] deps=0;reg [23:0] ai=0,dp=0;
reg [9:0] perm=0;
wire dcr,dsr,dmv,dms,dme,dmf,drv;wire [23:0] dq,dair;
wire [15:0] dmt,drt;wire [3:0] dre;
img_dh_dehaze_frame #(.MAX_WIDTH(4),.MAX_HEIGHT(4),.MAX_RADIUS(2)) ud(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(dc),.cmd_ready(dcr),
 .cmd_width(dw),.cmd_height(dh),.cmd_dark_radius(dr),.cmd_auto_airlight(da),
 .cmd_airlight_rgb(ai),.cmd_airlight_permille(perm),.cmd_omega(om),.cmd_t0(t0),
 .cmd_guided_enable(df),.cmd_guided_radius(dgr),.cmd_guided_epsilon(deps),.cmd_tag(dtag),
 .s_data(dp),.s_valid(dv),.s_sof(ds),.s_eol(de),.s_ready(dsr),
 .m_data(dq),.m_valid(dmv),.m_sof(dms),.m_eol(dme),.m_eof(dmf),.m_ready(mr),.m_tag(dmt),
 .rsp_valid(drv),.rsp_ready(mr),.rsp_error(dre),.rsp_tag(drt),.rsp_airlight_rgb(dair),.busy());
reg [7:0] guides[0:31];reg [15:0] sources[0:31],gexpect[0:31];
reg [23:0] pixels[0:31],dexpect[0:31];
integer g_received=0,d_received=0,expect_count=0,expected_error=0;
integer g_cases=0,d_cases=0;
reg [23:0] expected_air;
reg [67:0] gpast,dpast;
reg ghold=0,dhold=0;
always @(posedge clk) begin
  if(rst_n) begin
    // A previously stalled beat survives both external backpressure and CE pauses.
    if(ghold && {gmv,gq,gms,gme,gmf,gmt} !== gpast) $fatal(1,"guided output changed while held");
    if(dhold && {dmv,dq,dms,dme,dmf,dmt} !== dpast) $fatal(1,"dehaze output changed while held");
    ghold<=gmv && !(ce && mr);dhold<=dmv && !(ce && mr);
    gpast<={gmv,gq,gms,gme,gmf,gmt};dpast<={dmv,dq,dms,dme,dmf,dmt};
    if(ce && gmv && mr) begin
      if(g_received>=expect_count || gq !== gexpect[g_received])
        $fatal(1,"guided mismatch case=%0d pixel=%0d got=%0d expected=%0d",g_cases,g_received,gq,gexpect[g_received]);
      if(gms !== (g_received==0) || gme !== ((g_received%gw)==gw-1) || gmf !== (g_received==expect_count-1) || gmt!==gtag)
        $fatal(1,"guided framing/tag");
      g_received=g_received+1;
    end
    if(ce && dmv && mr) begin
      if(d_received>=expect_count || dq !== dexpect[d_received])
        $fatal(1,"dehaze mismatch case=%0d pixel=%0d got=%06x expected=%06x",d_cases,d_received,dq,dexpect[d_received]);
      if(dms !== (d_received==0) || dme !== ((d_received%dw)==dw-1) || dmf !== (d_received==expect_count-1) || dmt!==dtag)
        $fatal(1,"dehaze framing/tag");
      d_received=d_received+1;
    end
  end
end
task run_guided;
input integer w,h,r,e,tag,err;
integer i;
begin
  @(negedge clk);g_cases=g_cases+1;gw=w;gh=h;gr=r;eps=e;gtag=tag;
  g_received=0;expect_count=(err==1)?0:w*h;expected_error=err;gc=1;
  @(posedge clk);while(!(ce && gcr)) @(posedge clk);
  @(negedge clk);gc=0;
  for(i=0;i<expect_count;i=i+1) begin
    gi=guides[i];gp=sources[i];gs=(i==0);ge=(i%w==w-1);gv=1;
    if(err==2 && i==0) gs=0;
    @(posedge clk);while(!(ce && gsr)) @(posedge clk);
    @(negedge clk);gv=0;
    if(i%2==0) @(negedge clk);
  end
  @(posedge clk);while(!(ce && grv && mr)) @(posedge clk);
  if(gre!==err || grt!==tag || g_received!=expect_count) $fatal(1,"guided response/count");
  @(negedge clk);
end
endtask
task run_dehaze;
input integer w,h,r,aut,a,pp,ww,tt,refine,rr,ee,tag,err,expected_a;
integer i;
begin
  @(negedge clk);d_cases=d_cases+1;dw=w;dh=h;dr=r;da=aut;ai=a;perm=pp;
  om=ww;t0=tt;df=refine;dgr=rr;deps=ee;dtag=tag;d_received=0;
  expect_count=(err==1)?0:w*h;expected_air=expected_a;dc=1;
  @(posedge clk);while(!(ce && dcr)) @(posedge clk);
  @(negedge clk);dc=0;
  for(i=0;i<expect_count;i=i+1) begin
    dp=pixels[i];ds=(i==0);de=(i%w==w-1);dv=1;
    if(err==2 && i==0) ds=0;
    @(posedge clk);while(!(ce && dsr)) @(posedge clk);
    @(negedge clk);dv=0;
    if(i%3==0) @(negedge clk);
  end
  @(posedge clk);while(!(ce && drv && mr)) @(posedge clk);
  if(dre!==err || drt!==tag || d_received!=expect_count) $fatal(1,"dehaze response/count");
  if(err!=1 && dair!==expected_air) $fatal(1,"automatic airlight got=%06x expected=%06x",dair,expected_air);
  @(negedge clk);
end
endtask
initial begin
  repeat(3) @(negedge clk);rst_n=1;
  guides[0]=8'd17;sources[0]=16'd31000;gexpect[0]=16'd28719;
guides[1]=8'd199;sources[1]=16'd300;gexpect[1]=16'd3350;
guides[2]=8'd32;sources[2]=16'd22000;gexpect[2]=16'd21801;
guides[3]=8'd240;sources[3]=16'd3200;gexpect[3]=16'd360;
guides[4]=8'd80;sources[4]=16'd19000;gexpect[4]=16'd18643;
guides[5]=8'd64;sources[5]=16'd12000;gexpect[5]=16'd18249;
guides[6]=8'd0;sources[6]=16'd32768;gexpect[6]=16'd30984;
guides[7]=8'd255;sources[7]=16'd0;gexpect[7]=16'd0;
guides[8]=8'd101;sources[8]=16'd16384;gexpect[8]=16'd14861;
run_guided(3,3,1,16,100,0);
guides[0]=8'd64;sources[0]=16'd31000;gexpect[0]=16'd16354;
guides[1]=8'd64;sources[1]=16'd300;gexpect[1]=16'd15490;
guides[2]=8'd64;sources[2]=16'd22000;gexpect[2]=16'd14627;
guides[3]=8'd64;sources[3]=16'd3200;gexpect[3]=16'd16411;
guides[4]=8'd64;sources[4]=16'd19000;gexpect[4]=16'd15183;
guides[5]=8'd64;sources[5]=16'd12000;gexpect[5]=16'd13955;
guides[6]=8'd64;sources[6]=16'd32768;gexpect[6]=16'd16469;
guides[7]=8'd64;sources[7]=16'd0;gexpect[7]=16'd14876;
guides[8]=8'd64;sources[8]=16'd16384;gexpect[8]=16'd13283;
run_guided(3,3,1,64,101,0);
guides[0]=8'd17;sources[0]=16'd31000;gexpect[0]=16'd31000;
guides[1]=8'd199;sources[1]=16'd300;gexpect[1]=16'd300;
guides[2]=8'd32;sources[2]=16'd22000;gexpect[2]=16'd22000;
guides[3]=8'd240;sources[3]=16'd3200;gexpect[3]=16'd3200;
guides[4]=8'd80;sources[4]=16'd19000;gexpect[4]=16'd19000;
guides[5]=8'd64;sources[5]=16'd12000;gexpect[5]=16'd12000;
guides[6]=8'd0;sources[6]=16'd32768;gexpect[6]=16'd32768;
guides[7]=8'd255;sources[7]=16'd0;gexpect[7]=16'd0;
guides[8]=8'd101;sources[8]=16'd16384;gexpect[8]=16'd16384;
run_guided(3,3,0,1,102,0);
guides[0]=8'd255;sources[0]=16'd32768;gexpect[0]=16'd32768;
run_guided(1,1,2,65535,103,0);
guides[0]=8'd17;sources[0]=16'd31000;gexpect[0]=16'd28719;
guides[1]=8'd199;sources[1]=16'd300;gexpect[1]=16'd3350;
guides[2]=8'd32;sources[2]=16'd22000;gexpect[2]=16'd21801;
guides[3]=8'd240;sources[3]=16'd3200;gexpect[3]=16'd360;
guides[4]=8'd80;sources[4]=16'd19000;gexpect[4]=16'd18643;
guides[5]=8'd64;sources[5]=16'd12000;gexpect[5]=16'd18249;
guides[6]=8'd0;sources[6]=16'd32768;gexpect[6]=16'd30984;
guides[7]=8'd255;sources[7]=16'd0;gexpect[7]=16'd0;
guides[8]=8'd101;sources[8]=16'd16384;gexpect[8]=16'd14861;
run_guided(3,3,1,16,104,2);
run_guided(0,3,1,16,105,1);
pixels[0]=24'h607080;dexpect[0]=24'h4e5d6c;
pixels[1]=24'h90a060;dexpect[1]=24'h869646;
pixels[2]=24'h8090a0;dexpect[2]=24'h738392;
pixels[3]=24'hd0d8e0;dexpect[3]=24'hd1d8de;
pixels[4]=24'h223344;dexpect[4]=24'h051525;
pixels[5]=24'ha0b0c0;dexpect[5]=24'h99a9b8;
pixels[6]=24'h778899;dexpect[6]=24'h69798a;
pixels[7]=24'hccddee;dexpect[7]=24'hccddee;
pixels[8]=24'h405060;dexpect[8]=24'h283746;
run_dehaze(3,3,1,0,13163760,1,29491,3277,0,1,64,200,0,13163760);
pixels[0]=24'h607080;dexpect[0]=24'h4d5d6d;
pixels[1]=24'h90a060;dexpect[1]=24'h869647;
pixels[2]=24'h8090a0;dexpect[2]=24'h738393;
pixels[3]=24'hd0d8e0;dexpect[3]=24'hd0d8de;
pixels[4]=24'h223344;dexpect[4]=24'h051627;
pixels[5]=24'ha0b0c0;dexpect[5]=24'h99a9b8;
pixels[6]=24'h778899;dexpect[6]=24'h697a8b;
pixels[7]=24'hccddee;dexpect[7]=24'hccddee;
pixels[8]=24'h405060;dexpect[8]=24'h283847;
run_dehaze(3,3,1,1,0,1,29491,3277,1,1,64,201,0,13426158);
pixels[0]=24'h607080;dexpect[0]=24'h132332;
pixels[1]=24'h90a060;dexpect[1]=24'h3b4900;
pixels[2]=24'h8090a0;dexpect[2]=24'h1f2e3c;
pixels[3]=24'hd0d8e0;dexpect[3]=24'he6bd93;
pixels[4]=24'h223344;dexpect[4]=24'h021324;
pixels[5]=24'ha0b0c0;dexpect[5]=24'h2c3946;
pixels[6]=24'h778899;dexpect[6]=24'h0d1e2f;
pixels[7]=24'hccddee;dexpect[7]=24'hccddee;
pixels[8]=24'h405060;dexpect[8]=24'h051424;
run_dehaze(3,3,0,1,0,400,32000,5000,1,1,16,202,0,13426158);
pixels[0]=24'h607080;dexpect[0]=24'h607080;
pixels[1]=24'h90a060;dexpect[1]=24'h90a060;
pixels[2]=24'h8090a0;dexpect[2]=24'h8090a0;
pixels[3]=24'hd0d8e0;dexpect[3]=24'hd0d8e0;
pixels[4]=24'h223344;dexpect[4]=24'h223344;
pixels[5]=24'ha0b0c0;dexpect[5]=24'ha0b0c0;
pixels[6]=24'h778899;dexpect[6]=24'h778899;
pixels[7]=24'hccddee;dexpect[7]=24'hccddee;
pixels[8]=24'h405060;dexpect[8]=24'h405060;
run_dehaze(3,3,1,1,0,1000,0,3277,0,0,1,203,0,13426158);
pixels[0]=24'h000000;dexpect[0]=24'h000000;
run_dehaze(1,1,2,1,0,1,29491,3277,1,2,1,204,0,65793);
pixels[0]=24'h607080;dexpect[0]=24'hb7d580;
pixels[1]=24'h90a060;dexpect[1]=24'hffff43;
pixels[2]=24'h8090a0;dexpect[2]=24'hf4ffbd;
pixels[3]=24'hd0d8e0;dexpect[3]=24'hffffff;
pixels[4]=24'h223344;dexpect[4]=24'h40600e;
pixels[5]=24'ha0b0c0;dexpect[5]=24'hfffffa;
pixels[6]=24'h778899;dexpect[6]=24'he3ffaf;
pixels[7]=24'hccddee;dexpect[7]=24'hffffff;
pixels[8]=24'h405060;dexpect[8]=24'h799843;
run_dehaze(3,3,1,0,128,1,29491,3277,0,1,64,205,2,65920);
run_dehaze(0,3,1,0,0,1,29491,3277,0,0,1,206,1,0);
  $display("PASS dehaze_group guided_cases=%0d dehaze_cases=%0d cycles=%0d",g_cases,d_cases,cycle);
  $finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
