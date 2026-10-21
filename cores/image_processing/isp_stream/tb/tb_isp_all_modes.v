`timescale 1ns/1ps
module tb_isp_all_modes;
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
  csr(1,28,0,0); // status is word0 on metric page0
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
 integer flags;
 initial begin
  if(!$value$plusargs("output=%s",path))$fatal(1,"output missing");fd=$fopen(path,"wb");
  repeat(4)@(negedge clk);rst=1;
  for(integer mode=0;mode<64;mode=mode+1)begin
   if(mode==16||mode==48)begin
    for(integer channel=0;channel<3;channel=channel+1)for(integer a=0;a<256;a=a+1)
     csr(1,16,(channel<<24)|(a<<16)|a,0);
   end
   for(integer i=0;i<16;i=i+1)config_words[i]=0;
   flags=(mode&1)|((mode&2)<<2)|((mode&4)<<4)|((mode&8)<<4)|((mode&16)>>3)|((mode&32)>>3)|((mode%4)<<4);
   config_words[0]={16'd7,16'd7};config_words[1]=1;config_words[2]=1000;
   config_words[3]=(71+17*mode)&1023;config_words[4]=flags;config_words[5]=21;
   config_words[6]={16'd29,16'd13};config_words[7]={16'd57,16'd41};
   config_words[8]={16'd200,16'd300};config_words[9]=400;
   config_words[10]={16'd128,16'd1024};config_words[11]={16'hff80,16'hffc0};
   config_words[12]={16'd128,16'd1024};config_words[13]={16'hff80,16'd64};
   config_words[14]={16'hfffb,16'd1024};config_words[15]={16'd7,16'd3};
   for(integer i=0;i<16;i=i+1)csr(1,32+i*4,config_words[i],0);
   csr(1,4,1,0);poll_done(0);metrics(mode+1,1,9);
   metric(22);if(read_value!=flags)$fatal(1,"full mode flag snapshot");
  end
  if(outputs!=576)$fatal(1,"mode stream count %0d",outputs);
  $fclose(fd);$display("PASS all64 ISP bypass combinations via atomic CSR, output CRC/RGB and restart");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
