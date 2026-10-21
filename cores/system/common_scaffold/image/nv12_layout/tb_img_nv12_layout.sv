`timescale 1ns/1ps
module tb;
 `include "geometry.vh"
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clk_en=0,cfg_valid=0,cfg_nv21=0;
 reg [31:0] cfg_y_base=YBASE,cfg_uv_base=UVBASE,cfg_y_stride=YS,cfg_uv_stride=UVS;
 reg [31:0] cfg_address_min=0,cfg_address_max=8191;
 wire cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_sof,m_eol;
 reg start_valid=0,start_read=0,s_valid=0,s_sof=0,s_eol=0,macro_gate=0,recon_ready=0;
 wire m_ready;
 reg [16:0] s_data=0;
 wire [16:0] m_data;
 wire mem_req_valid,mem_req_write,mem_rsp_ready;
 reg mem_req_ready=0,mem_rsp_valid=0,mem_rsp_error=0;
 wire [31:0] mem_req_addr;
 wire [7:0] mem_req_wdata;
 reg [7:0] mem_rsp_rdata=0;
 wire done_valid,done_error;
 reg done_ready=0;
 wire [2:0] error_code;
 img_nv12_layout #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) dut(.*);
 wire recon_input_ready,recon_valid,recon_sof,recon_eol,recon_marker_error;
 wire [23:0] recon_data;
 assign m_ready=recon_input_ready && macro_gate;
 chroma_420_to_444 #(.BITS(8),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) reconstruct(
  .clk(clk),.rst_n(rst_n),.ce(clk_en),.cfg_valid(1'b0),.cfg_ready(),
  .cfg_mode(2'b0),.cfg_h_siting(2'b0),.cfg_v_siting(2'b0),.cfg_done(),.cfg_error(),
  .s_tdata(m_data),.s_tvalid(m_valid && macro_gate),.s_tuser(m_sof),.s_tlast(m_eol),.s_tready(recon_input_ready),
  .m_tdata(recon_data),.m_tvalid(recon_valid),.m_tuser(recon_sof),.m_tlast(recon_eol),.m_tready(recon_ready),
  .busy(),.marker_error(recon_marker_error));
 reg [7:0] memory[0:8191],expected_memory[0:8191];
 reg [19:0] words[0:WORDS-1];
 reg [40:0] requests[0:REQUESTS-1];
 reg [25:0] expected444[0:WIDTH*HEIGHT-1];
 integer i,n,req_seen=0,out_seen=0,recon_seen=0,delay=0;
 reg pending=0,checking=1,randomize=1,inject_error=0;
 reg [31:0] rng=32'h3d68b192;
 always @(negedge clk) if(randomize) begin
  rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
  clk_en=rng[2:0]!=0;mem_req_ready=rng[5:3]!=0;macro_gate=rng[8:6]!=0;recon_ready=rng[15:13]!=0;
 end
 reg [40:0] expected_req;
 reg [20:0] hold_output;
 reg [41:0] hold_request;
 reg stalled_output,stalled_request;
 always @(posedge clk) begin
  if(!rst_n) begin pending<=0;mem_rsp_valid<=0;mem_rsp_error<=0;delay<=0;end
  else if(clk_en) begin
   if(mem_req_valid && mem_req_ready) begin
    if(pending || mem_rsp_valid) $fatal(1,"more than one outstanding request");
    if(mem_req_addr>8191) $fatal(1,"memory out of bounds");
    if(checking) begin
     if(req_seen>=REQUESTS) $fatal(1,"extra request");
     expected_req=requests[req_seen];
     if(mem_req_write!==expected_req[40] || mem_req_addr!==expected_req[39:8] ||
        (mem_req_write && mem_req_wdata!==expected_req[7:0])) $fatal(1,"request %0d mismatch addr=%0d expected=%h",req_seen,mem_req_addr,expected_req);
     req_seen=req_seen+1;
    end
    if(mem_req_write && !inject_error) memory[mem_req_addr]<=mem_req_wdata;
    mem_rsp_rdata<=memory[mem_req_addr];mem_rsp_error<=inject_error;
    pending<=1;delay<=rng[12:10];
   end
   if(pending && !mem_rsp_valid) begin
    if(delay==0) begin mem_rsp_valid<=1;pending<=0;end else delay<=delay-1;
   end
   if(mem_rsp_valid && mem_rsp_ready) mem_rsp_valid<=0;
   if(checking && m_valid && m_ready) begin
    if({m_sof,m_eol,m_data}!==words[out_seen%WORDS][18:0]) $fatal(1,"read macro %0d mismatch got %h expected %h",out_seen,{m_sof,m_eol,m_data},words[out_seen%WORDS]);
    out_seen=out_seen+1;
   end
   if(checking && recon_valid && recon_ready) begin
    if({recon_sof,recon_eol,recon_data}!==expected444[recon_seen%(WIDTH*HEIGHT)]) $fatal(1,"reconstruct mismatch %0d",recon_seen);
    recon_seen=recon_seen+1;
   end
  end
  hold_output={m_valid,m_sof,m_eol,m_data};stalled_output=rst_n&&m_valid&&(!clk_en||!m_ready);
  hold_request={mem_req_valid,mem_req_write,mem_req_addr,mem_req_wdata};stalled_request=rst_n&&mem_req_valid&&(!clk_en||!mem_req_ready);
  #1;
  if(stalled_output && hold_output!=={m_valid,m_sof,m_eol,m_data}) $fatal(1,"unstable output");
  if(stalled_request && hold_request!=={mem_req_valid,mem_req_write,mem_req_addr,mem_req_wdata}) $fatal(1,"unstable request");
  if(checking && rst_n && recon_marker_error) $fatal(1,"reconstruct markers");
 end
 task configure(input bit bad);
 begin
  @(negedge clk);#1;cfg_valid=1;
  do begin @(posedge clk);end while(!cfg_ready);
  #1;if(cfg_error!==bad || cfg_done===bad) $fatal(1,"config result");
  @(negedge clk);#1;cfg_valid=0;
 end endtask
 task start_frame(input bit rd);
 begin
  @(negedge clk);#1;start_valid=1;start_read=rd;
  do begin @(posedge clk);end while(!start_ready);
  @(negedge clk);#1;start_valid=0;
 end endtask
 task send(input [18:0] word);
 begin
  @(negedge clk);#1;s_data=word[16:0];s_sof=word[18];s_eol=word[17];s_valid=1;
  do begin @(posedge clk);end while(!s_ready);
  @(negedge clk);#1;s_valid=0;
 end endtask
 task finish_frame(input [2:0] code);
 reg [3:0] held;
 begin
  while(!done_valid) begin @(posedge clk);#2;end
  if(done_error!==(code!=0) || error_code!==code) $fatal(1,"frame completion code %0d expected %0d",error_code,code);
  held={done_error,error_code};
  repeat(7) begin @(posedge clk);#2;if(!done_valid || held!=={done_error,error_code} || cfg_ready || start_ready) $fatal(1,"completion backpressure");end
  @(negedge clk);#1;done_ready=1;
  do begin @(posedge clk);end while(!clk_en);
  @(negedge clk);#1;done_ready=0;
 end endtask
 initial begin
  $readmemh("words.mem",words);$readmemh("requests.mem",requests);$readmemh("memory.mem",expected_memory);$readmemh("recon.mem",expected444);
  for(i=0;i<8192;i=i+1) memory[i]=8'ha5;
  repeat(3) @(negedge clk);#1;rst_n=1;
  if(start_ready) $fatal(1,"unconfigured start");
  configure(0);
  cfg_y_stride=WIDTH-1;configure(1);cfg_y_stride=YS;
  cfg_uv_stride=2*((WIDTH+1)/2)-1;configure(1);cfg_uv_stride=UVS;
  cfg_uv_base=YBASE;configure(1);cfg_uv_base=UVBASE;
  cfg_address_max=YBASE;configure(1);cfg_address_max=8191;
  cfg_y_base=32'hfffffff0;configure(1);cfg_y_base=YBASE;
  // Exact inclusive span boundaries must be accepted, not require extra padding.
  cfg_address_min=YBASE<UVBASE?YBASE:UVBASE;
  cfg_address_max=(YBASE+(HEIGHT-1)*YS+WIDTH-1)>(UVBASE+((HEIGHT+1)/2-1)*UVS+2*((WIDTH+1)/2)-1) ?
      YBASE+(HEIGHT-1)*YS+WIDTH-1 : UVBASE+((HEIGHT+1)/2-1)*UVS+2*((WIDTH+1)/2)-1;
  configure(0);
  for(n=0;n<2;n=n+1) begin
   if(n!=0) begin cfg_nv21=1;configure(0);end
   start_frame(0);for(i=0;i<WORDS;i=i+1) send(words[i]);finish_frame(0);
   start_frame(1);finish_frame(0);
  end
  while(recon_seen<2*WIDTH*HEIGHT) begin @(posedge clk);#2;end
  if(req_seen!=REQUESTS || out_seen!=2*WORDS) $fatal(1,"missing transactions");
  for(i=0;i<8192;i=i+1) if(memory[i]!==expected_memory[i]) $fatal(1,"plane/padding byte %0d mismatch",i);
  checking=0;
  start_frame(0);send(19'h50000);finish_frame(1);
  inject_error=1;start_frame(0);send(words[0]);finish_frame(2);inject_error=0;
  // Reset with an outstanding transaction; the test memory bridge flushes its response too.
  start_frame(1);
  while(!pending) begin @(posedge clk);#2;end
  @(negedge clk);#1;rst_n=0;
  #1;if(mem_req_valid || mem_rsp_ready || m_valid || done_valid || start_ready) $fatal(1,"reset abort");
  @(negedge clk);#1;rst_n=1;
  repeat(20) @(posedge clk);#2;if(m_valid || done_valid || start_ready) $fatal(1,"post-reset transaction");
  $display("NV12 PASS %0dx%0d requests=%0d macros=%0d",WIDTH,HEIGHT,req_seen,out_seen);$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule
