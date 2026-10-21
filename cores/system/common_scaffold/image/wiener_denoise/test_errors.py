from test_wiener import *
a=np.array([[10,12,22,27],[11,25,35,39],[9,42,50,65],[5,48,80,90]],dtype=np.uint8)
e=oracle(a,3,100)
init='\n'.join(f'pixels[{i}]=8\'d{int(v)};expected[{i}]=11\'h{((i==15)<<10)|((i%4==3)<<9)|((i==0)<<8)|int(z):03x};' for i,(v,z) in enumerate(zip(a.flat,e.flat)))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,cfg_window5=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
 reg[5:0]cfg_width=4,cfg_height=4;reg[15:0]cfg_noise_variance=100;reg[7:0]s_data=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
 wiener_denoise dut(.*);
 reg[7:0]pixels[0:15];reg[10:0]expected[0:15];integer i,got=0,recovered=0,cycles=0;reg check_pixels=0;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>1000000)$fatal(1,"watchdog state %d",dut.state);
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
  cfg_width=4;cfg_height=4;cfg_window5=0;cfg_noise_variance=100;abort=0;m_ready=1;ce=1;
  got=0;check_pixels=1;start;frame;while(!done_valid)tick;
  if(done_error||error_code||got!=16)$fatal(1,"recovery done err %h got %d",error_code,got);
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
  start;if(target!=1)frame;
  while(dut.state!=target)tick;
  if(target==12)m_ready=0;
  abort=1;#1;if(m_valid)$fatal(1,"abort transfer gate");tick;abort=0;
  error_ack(8'h93);
 end endtask
 task reset_at;input integer target;begin
  start;if(target!=1)frame;
  if(target==12)m_ready=0;
  while(dut.state!=target)tick;
  ce=0;rst_n=0;repeat(3)tick;
  if(m_valid||done_valid||busy)$fatal(1,"CE0 reset failure");
  rst_n=1;ce=1;m_ready=1;tick;recovery;
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
 start;s_valid=1;s_data=2;s_sof=0;s_eol=0;s_last=0;tick;s_valid=0;error_ack(8'h81);
 start;s_valid=1;s_sof=1;s_eol=1;s_last=0;tick;s_valid=0;error_ack(8'h81);
 start;s_valid=1;s_sof=1;s_eol=0;s_last=1;tick;s_valid=0;error_ack(8'h81);
 abort_at(1);abort_at(17);abort_at(19);abort_at(12);
 // Abort held while CE=0 suppresses valid, then becomes sampled error on CE=1.
 start;frame;m_ready=0;while(!m_valid)tick;ce=0;abort=1;#1;if(m_valid)$fatal(1,"CE0 abort gate");
 repeat(3)begin tick;if(done_valid||dut.state!=12)$fatal(1,"CE0 abort unexpectedly sampled");end
 ce=1;tick;abort=0;error_ack(8'h93);
 reset_at(1);reset_at(4);reset_at(17);reset_at(19);reset_at(12);reset_at(14);
 // Invalid state fails explicitly; do not change module source to inject fault.
 start;force dut.state=31;tick;release dut.state;tick;error_ack(8'h94);
 if(recovered!=20)$fatal(1,"recovery count %d",recovered);
 $display("WIENER OK recoveries=%d",recovered);$finish;
 end
endmodule'''.replace('INITDATA',init)
simulate(tb,'errors')
for bound in (0,33):
 static_tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;
 wire start_ready,done_valid,done_error,busy,s_ready,m_valid;wire[7:0]error_code;
 wiener_denoise #(.MAX_SIDE(BOUND)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),
 .cfg_width(6'd1),.cfg_height(6'd1),.cfg_window5(1'b0),.cfg_noise_variance(16'd1),.abort(abort),
 .s_data(8'd0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.s_ready(s_ready),
 .m_valid(m_valid),.m_ready(1'b1),.done_valid(done_valid),.done_ready(1'b0),.done_error(done_error),.error_code(error_code),.busy(busy));
 initial begin repeat(3)@(negedge clk);rst_n=1;@(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
 if(!done_valid||!done_error||error_code!=8'h80||busy||s_ready||m_valid)$fatal(1,"bad static parameter accepted");
 repeat(5)begin @(negedge clk);if(!done_valid||!done_error||error_code!=8'h80)$fatal(1,"static error not held");end
 $display("WIENER OK static bound");$finish;end
 endmodule'''.replace('BOUND',str(bound))
 simulate(static_tb,'static_'+str(bound))
(HERE/'error_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),healthy_recovery_frames=20,coverage=['static MAX_SIDE=0/33 explicit rejection; abort-high START blocked','zero/oversize width and height','missing SOF, early EOL/LAST: immediate partial-capture failure','abort capture/serial multiply/divide/output','CE0 abort gate held until CE1','error and CE0 ACK holds','CE0 reset capture/RAM/serial multiply/divide/output/held DONE','invalid internal state','all recovered output bytes and markers compared to Fraction oracle'],board=False),indent=2)+'\n')
print('20 complete healthy recoveries PASS')
