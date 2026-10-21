`timescale 1ns/1ps
module tb_virtual_raw_source;
 parameter RAW_BITS=10;
 reg clk=0,rst=0,start=0,cmd_ready=1,m_ready=1,rsp_valid=0;
 always #5 clk=~clk;
 reg [15:0] width=0,height=0;reg [31:0] frames=0,period=0;reg [RAW_BITS-1:0] seed=0;
 reg [3:0] rsp_error=0;wire ready,cv,mv,sof,eol,eof,rr,done,error;
 wire [15:0] cw,ch,id;wire [RAW_BITS-1:0] data;
 wire [31:0] completed,misses,cs,ps,cycles;
 virtual_raw_source #(.RAW_BITS(RAW_BITS)) dut(clk,rst,start,ready,width,height,frames,period,seed,
 cv,cmd_ready,cw,ch,id,mv,m_ready,data,sof,eol,eof,rsp_valid,rr,rsp_error,done,error,completed,misses,cs,ps,cycles);
 integer tick=0,last_cmd=0,commands=0,pixels=0,fx=0,fy=0,expected_w=0,expected_h=0,expected_seed=0;
 integer expected_period=0,expected_frames=0;reg random_mode=0,held=0;
 reg [RAW_BITS+2:0] saved;reg [31:0] rng=32'h12345678;
 always @(negedge clk)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  cmd_ready=!random_mode||rng[1];m_ready=!random_mode||rng[3]||rng[7];
 end
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(held&&(!mv||{eof,eol,sof,data}!==saved))$fatal(1,"source changed stalled pixel");
  held<=mv&&!m_ready;saved<={eof,eol,sof,data};
  if(cv&&cmd_ready)begin
   if(cw!=expected_w||ch!=expected_h||id!=commands)$fatal(1,"source command/config mismatch");
   if(!random_mode&&commands!=0&&tick-last_cmd!=expected_period)$fatal(1,"source cadence %0d expected %0d",tick-last_cmd,expected_period);
   last_cmd=tick;commands=commands+1;fx=0;fy=0;
  end
  if(mv&&m_ready)begin
   if(data!==((expected_seed+23*fx+37*fy+57*(commands-1))&((1<<RAW_BITS)-1))||sof!=(fx==0&&fy==0)||eol!=(fx==expected_w-1)||eof!=(fx==expected_w-1&&fy==expected_h-1))$fatal(1,"source pixel/marker mismatch");
   pixels=pixels+1;
   if(eof)rsp_valid<=1;
   if(eol)begin fx=0;fy=fy+1;end else fx=fx+1;
  end
  if(rsp_valid&&rr)rsp_valid<=0;
 end
 task run_case(input integer w,input integer h,input integer n,input integer p,input bit stalls);
 begin
  @(negedge clk);commands=0;pixels=0;last_cmd=0;random_mode=stalls;
  expected_w=w;expected_h=h;expected_seed=71;expected_period=p;expected_frames=n;
  width=w;height=h;frames=n;period=p;seed=71;start=1;
  @(negedge clk);start=0;width=1;height=1;frames=99;period=2;seed=0;
  wait(done);@(negedge clk);
  if(error||completed!=n||commands!=n||pixels!=w*h*n)$fatal(1,"source totals");
  if(stalls?(misses!=n||ps==0||cs==0):(misses!=0||ps!=0||cs!=0))$fatal(1,"source timing counters");
  $display("SOURCE_CASE bits=%0d size=%0dx%0d frames=%0d pixels=%0d period=%0d misses=%0d cycles=%0d",RAW_BITS,w,h,n,pixels,p,misses,cycles);
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  run_case(7,5,4,200,0);
  run_case(5,3,7,2,1);
  run_case(320,240,3,1666667,0);
  run_case(640,480,2,1666667,0);
  @(negedge clk);start=1;width=0;height=5;frames=1;period=2;
  @(negedge clk);start=0;if(!done||!error)$fatal(1,"invalid configuration not rejected");
  $display("PASS virtual RAW source bits=%0d",RAW_BITS);$finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule
