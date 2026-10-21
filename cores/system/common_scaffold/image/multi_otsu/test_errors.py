from test_multi_otsu import *
a=np.array([[0,80,160,240]]*4,dtype=np.uint8)
thresholds,objective,ties=oracle(a);assert thresholds==(0,80)
c=np.digitize(a,thresholds,right=True).astype(np.uint8);e=np.take([0,127,255],c)
init='\n'.join(f"pixels[{i}]=8'd{int(v)};expected[{i}]=13'h{(int(cl)<<11)|((i==15)<<10)|((i%4==3)<<9)|((i==0)<<8)|int(z):04x};" for i,(v,cl,z) in enumerate(zip(a.flat,c.flat,e.flat)))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
 reg[5:0]cfg_width=4,cfg_height=4;reg[7:0]cfg_level0=0,cfg_level1=127,cfg_level2=255,s_data=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code,threshold0,threshold1;wire[1:0]m_class;
 multi_otsu dut(.*);
 reg[7:0]pixels[0:15];reg[12:0]expected[0:15];integer i,got=0,recovered=0,cycles=0;reg check_pixels=0;
 wire[12:0]token={m_class,m_last,m_eol,m_sof,m_data};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>1500000)$fatal(1,"watchdog state %d",dut.state);
  if(check_pixels&&rst_n&&ce&&m_valid&&m_ready)begin
   if(got>=16||token!==expected[got])$fatal(1,"recovery pixel %d %h %h",got,token,expected[got]);got=got+1;
  end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task start;begin while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task send_pixel;input integer index;begin
  s_data=pixels[index];s_sof=index==0;s_eol=index%4==3;s_last=index==15;
  while(!s_ready)tick;s_valid=1;tick;s_valid=0;
 end endtask
 task frame;begin for(i=0;i<16;i=i+1)send_pixel(i);end endtask
 task ack;begin done_ready=1;tick;done_ready=0;tick;end endtask
 task recovery;begin
  cfg_width=4;cfg_height=4;cfg_level0=0;cfg_level1=127;cfg_level2=255;abort=0;m_ready=1;ce=1;
  got=0;check_pixels=1;start;frame;while(!done_valid)tick;
  if(done_error||error_code||got!=16||threshold0!=0||threshold1!=80)$fatal(1,"recovery done err %h got %d thresholds %d %d",error_code,got,threshold0,threshold1);
  check_pixels=0;ack;recovered=recovered+1;
 end endtask
 task error_ack;input[7:0]code;begin
  while(!done_valid)tick;
  if(!done_error||error_code!=code||m_valid||s_ready)$fatal(1,"error expected %h got %h",code,error_code);
  repeat(4)begin tick;if(!done_valid||!done_error||error_code!=code)$fatal(1,"error hold");end
  ce=0;done_ready=1;repeat(3)begin tick;if(!done_valid)$fatal(1,"CE0 ack consumed");end
  done_ready=0;ce=1;ack;recovery;
 end endtask
 task abort_at;input integer target;begin
  start;if(target!=1&&target!=2)frame;
  while(dut.state!=target)tick;
  if(target==33)m_ready=0;
  abort=1;#1;if(m_valid)$fatal(1,"abort transfer gate");tick;abort=0;
  error_ack(8'h93);
 end endtask
 task reset_at;input integer target;begin
  start;if(target==4)send_pixel(0);else if(target!=1&&target!=2)frame;
  if(target==33)m_ready=0;
  while(dut.state!=target)tick;
  ce=0;rst_n=0;repeat(3)tick;
  if(m_valid||done_valid||busy)$fatal(1,"CE0 reset failure");
  rst_n=1;ce=1;m_ready=1;tick;recovery;
 end endtask
 task spectrum_error;input integer kind;begin
  start;
  for(i=0;i<16;i=i+1)begin
   s_data=kind==0?0:kind==1?255:(i%2?0:255);s_sof=i==0;s_eol=i%4==3;s_last=i==15;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)begin tick;if(m_valid)$fatal(1,"insufficient-level frame emitted pixels");end
  if(threshold0||threshold1)$fatal(1,"invalid frame stale thresholds");error_ack(8'h90);
 end endtask
 initial begin
 INITDATA
 repeat(3)tick;rst_n=1;tick;
 abort=1;start_valid=1;repeat(3)begin tick;if(start_ready||busy||done_valid)$fatal(1,"abort-high START accepted");end
 start_valid=0;abort=0;recovery;
 cfg_width=0;start;error_ack(8'h80);
 cfg_width=33;start;error_ack(8'h80);
 cfg_height=0;start;error_ack(8'h80);
 cfg_height=33;start;error_ack(8'h80);
 cfg_level1=0;start;error_ack(8'h82);
 cfg_level1=255;start;error_ack(8'h82);
 cfg_level0=200;start;error_ack(8'h82);
 start;while(!s_ready)tick;s_valid=1;s_data=2;s_sof=0;s_eol=0;s_last=0;tick;s_valid=0;error_ack(8'h81);
 start;while(!s_ready)tick;s_valid=1;s_sof=1;s_eol=1;s_last=0;tick;s_valid=0;error_ack(8'h81);
 start;while(!s_ready)tick;s_valid=1;s_sof=1;s_eol=0;s_last=1;tick;s_valid=0;error_ack(8'h81);
 spectrum_error(0);spectrum_error(1);spectrum_error(2);
 cfg_width=32;cfg_height=32;start;
 for(i=0;i<1024;i=i+1)begin
  s_data=255;s_sof=i==0;s_eol=i%32==31;s_last=i==1023;
  while(!s_ready)tick;s_valid=1;tick;s_valid=0;
 end
 while(!done_valid)begin tick;if(m_valid)$fatal(1,"flat1024 emitted pixels");end
 if(dut.total_count!=1024||dut.run_count!=1024||dut.hist[255]!=1024)$fatal(1,"1024-count truncation");
 error_ack(8'h90);
 abort_at(1);abort_at(2);abort_at(7);abort_at(37);abort_at(27);abort_at(33);
 start;frame;m_ready=0;while(!m_valid)tick;ce=0;abort=1;#1;if(m_valid)$fatal(1,"CE0 abort gate");
 repeat(3)begin tick;if(done_valid||dut.state!=33)$fatal(1,"CE0 abort unexpectedly sampled");end
 ce=1;tick;abort=0;error_ack(8'h93);
 reset_at(1);reset_at(2);reset_at(4);reset_at(7);reset_at(37);reset_at(27);reset_at(31);reset_at(33);reset_at(34);
 start;force dut.state=63;tick;release dut.state;tick;error_ack(8'h94);
 if(recovered!=32)$fatal(1,"recovery count %d",recovered);
 $display("MULTIOTSU OK recoveries=%d",recovered);$finish;
 end
endmodule'''.replace('INITDATA',init)
simulate(tb,'errors')
for bound in (0,33):
 static_tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0;
 wire start_ready,done_valid,done_error,busy,s_ready,m_valid;wire[7:0]error_code;
 multi_otsu #(.MAX_SIDE(BOUND)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),
 .cfg_width(6'd1),.cfg_height(6'd1),.cfg_level0(8'd0),.cfg_level1(8'd127),.cfg_level2(8'd255),.abort(1'b0),
 .s_data(8'd0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.s_ready(s_ready),
 .m_valid(m_valid),.m_ready(1'b1),.done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code),.busy(busy));
 initial begin repeat(3)@(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
 if(!done_valid||!done_error||error_code!=8'h80||busy||s_ready||m_valid)$fatal(1,"bad static parameter accepted");
 repeat(5)begin @(negedge clk);if(!done_valid||!done_error||error_code!=8'h80)$fatal(1,"static error not held");end
 $display("MULTIOTSU OK static bound");$finish;end
 endmodule'''.replace('BOUND',str(bound))
 simulate(static_tb,'static_'+str(bound))
(HERE/'error_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),healthy_recovery_frames=32,coverage=['static MAX_SIDE=0/33 explicit rejection; abort-high START blocked','zero/oversize geometry; equal/descending output levels','SOF/EOL/LAST immediate partial-frame errors','zero/constant/two-level frames: error90 no pixels and cleared thresholds; full1024 histogram count','abort clear/capture/prefix/serial multiply/exact comparison/output','CE0 abort through CE1','CE0 reset clear/capture/histogram-RMW/prefix/multiply/compare/frame-RAM/output/held DONE','error and CE0 ACK hold','invalid internal state','all recovered output data/class/markers/thresholds checked'],board=False),indent=2)+'\n')
print('32 complete healthy recoveries PASS')
