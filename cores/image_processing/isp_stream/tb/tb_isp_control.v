`timescale 1ns/1ps
module tb_isp_control;
 reg clk=0,rst=0,qv=0,qw=0,rr=0,output_ready=0;always #5 clk=~clk;
 reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] strobe=15;
 wire qr,rv,re,mv,ms,me,mf;wire [31:0] rd;wire [7:0] probe,md;wire [15:0] mid;
 isp_control dut(clk,rst,qv,qw,addr,data,strobe,qr,rv,re,rd,rr,probe,mv,output_ready,md,ms,me,mf,mid);
 reg [31:0] rng=32'h13579bdf;reg held=0;reg [26:0] saved_pixel;
 reg [7:0] expected_probe=0;
 integer fd,outputs=0;reg [1023:0] path;reg [31:0] read_value;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};output_ready=rng[0]||rng[3];end
 always @(posedge clk)if(rst)begin
  case(dut.probe_page)
   0:expected_probe<={dut.rv,dut.rr,mf,me,ms,output_ready,mv,dut.sv&&dut.sr};
   1:expected_probe<=dut.raw[7:0];
   2:expected_probe<=md;
   3:expected_probe<={2'd0,dut.cfg_pending,dut.cfg_valid,dut.source_error,dut.source_done,dut.source_ready,dut.cv&&dut.cr};
  endcase
  if(held&&(!mv||{mid,ms,me,mf,md}!==saved_pixel))$fatal(1,"control output changed under stall");
  held<=mv&&!output_ready;saved_pixel<={mid,ms,me,mf,md};
  if(mv&&output_ready)begin outputs=outputs+1;$fwrite(fd,"%c%c%c%c",md,mid[7:0],mid[15:8],{5'd0,mf,me,ms});end
 end
 always @(negedge clk)if(rst&&probe!==expected_probe)$fatal(1,"registered probe page mismatch");
 task csr(input bit write,input integer address,input [31:0] value,input bit err);
 reg [32:0] saved;
 begin
  @(negedge clk);qv=1;qw=write;addr=address;data=value;
  do @(posedge clk);while(!qr);@(negedge clk);qv=0;
  wait(rv);saved={re,rd};repeat(5)begin @(negedge clk);if(!rv||{re,rd}!==saved)$fatal(1,"control CSR held response");end
  if(re!=err)$fatal(1,"control CSR address=%h error=%b expected=%b",address,re,err);
  read_value=rd;rr=1;@(negedge clk);rr=0;
 end endtask
 task poll_done(input bit expected_error);
 integer tries;reg finished;
 begin
  finished=0;
  for(tries=0;tries<200&&!finished;tries=tries+1)begin
   csr(1,12,1,0);csr(0,192,0,0);finished=read_value[1];
  end
  if(!finished||read_value[2]!=expected_error)$fatal(1,"run status/error %h",read_value);
 end endtask
 task metric(input integer word_index);
 begin csr(1,28,(word_index>=16?256:0),0);csr(0,192+(word_index%16)*4,0,0);end endtask
 task metrics(input integer run_number,input integer count,input integer bytes);
 begin
  metric(1);if(read_value!=count)$fatal(1,"completed count");
  metric(2);if(read_value!=0)$fatal(1,"deadline missed");
  metric(6);if(read_value!=bytes)$fatal(1,"output bytes");
  metric(7);if(read_value!=count)$fatal(1,"output frames");
  metric(8);$display("CONTROL_CRC run=%0d value=%08h",run_number,read_value);
  // Snapshot is frozen while data/control transactions continue.
  metric(20);if(read_value!=run_number)$fatal(1,"snapshot configuration version");
  metric(14);$display("CONTROL_R run=%0d value=%0d",run_number,read_value);
  metric(16);$display("CONTROL_G run=%0d value=%0d",run_number,read_value);
  metric(18);$display("CONTROL_B run=%0d value=%0d",run_number,read_value);
 end endtask
 reg [31:0] config_words[0:15];reg [31:0] frozen_bytes,frozen_id;
 initial begin
  if(!$value$plusargs("output=%s",path))$fatal(1,"output missing");fd=$fopen(path,"wb");
  repeat(4)@(negedge clk);rst=1;
  csr(0,192,0,1); // snapshot required
  csr(1,28,4,1);csr(1,16,32'h03000000,1); // invalid page/channel
  for(integer i=0;i<16;i=i+1)config_words[i]=0;
  config_words[0]={16'd7,16'd7};config_words[1]=2;config_words[2]=1000;config_words[3]=71;
  config_words[8]={16'd256,16'd256};config_words[9]=256;
  config_words[10]=1024;config_words[12]=1024;config_words[14]=1024;
  for(integer i=0;i<16;i=i+1)csr(1,32+i*4,config_words[i],0);
  csr(1,4,1,0);csr(1,16,0,1); // LUT blocked during a run
  csr(1,12,1,0);metric(6);frozen_bytes=read_value;
  csr(0,24,0,0);frozen_id=read_value;
  repeat(400)@(negedge clk);
  if(outputs==0)$fatal(1,"snapshot stability test had no live traffic");
  metric(6);if(read_value!=frozen_bytes)$fatal(1,"snapshot changed without capture");
  csr(0,24,0,0);if(read_value!=frozen_id)$fatal(1,"snapshot id changed without capture");
  poll_done(0);metrics(1,2,18);
  csr(0,24,0,0);if(read_value==0)$fatal(1,"snapshot id");
  // Probe switching is passive and registered; no bitstream change.
  for(integer p=0;p<4;p=p+1)begin
   csr(1,28,p,0);repeat(2)@(negedge clk);
  end
  // Gamma configuration must fail until a complete table has been loaded.
  csr(1,36,1,0);csr(1,48,6,0);csr(1,4,1,0);poll_done(1);
  metric(6);if(read_value!=0)$fatal(1,"Gamma rejection emitted pixels");
  for(integer channel=0;channel<3;channel=channel+1)for(integer a=0;a<256;a=a+1)
   csr(1,16,(channel<<24)|(a<<16)|a,0);
  csr(1,4,1,0);poll_done(0);metrics(3,1,9);
  if(outputs!=27)$fatal(1,"unexpected output count %0d",outputs);
  $fclose(fd);$display("PASS ISP runtime CSR/source/pipeline, LUT recovery, snapshots, probes and restart");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
