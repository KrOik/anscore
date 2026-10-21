integer cycles=0,tt;integer fairness_count=0,fair_b=0,ii;reg fairness_phase=0;reg[MASTERS-1:0] sent_w;integer leftw[0:TARGETS-1],leftr[0:TARGETS-1];reg[3:0]wid[0:TARGETS-1],rid[0:TARGETS-1];integer rbeat[0:TARGETS-1];reg bad_bid=0,bad_rid=0,bad_rlast=0;integer checks=0;
always @(posedge clk) begin
 cycles<=cycles+1;
 if(fairness_phase)begin
 if(m_axi_awvalid[0]&&m_axi_awready[0])begin if(m_axi_awaddr[15:8]!=(32+fairness_count))$fatal(1,"round robin order");fairness_count<=fairness_count+1;end
 for(integer fm=0;fm<MASTERS;fm=fm+1)if(s_axi_bvalid[fm]&&s_axi_bready[fm])fair_b<=fair_b+1;
 end
 if(cycles>50000)$fatal(1,"timeout");
 if(!rst_n)begin
  m_axi_bvalid<=0;m_axi_rvalid<=0;
  for(tt=0;tt<TARGETS;tt=tt+1)begin leftw[tt]<=0;leftr[tt]<=0;rbeat[tt]<=0;end
 end else begin
  for(tt=0;tt<TARGETS;tt=tt+1)begin
   if(m_axi_awvalid[tt]&&m_axi_awready[tt])begin leftw[tt]<=m_axi_awlen[tt*8+:8]+1;wid[tt]<=m_axi_awid[tt*4+:4];end
   if(m_axi_wvalid[tt]&&m_axi_wready[tt])begin
    if(leftw[tt]<=0||m_axi_wlast[tt]!=(leftw[tt]==1))$fatal(1,"target W framing");
    leftw[tt]<=leftw[tt]-1;
    if(leftw[tt]==1)begin m_axi_bvalid[tt]<=1;m_axi_bid[tt*4+:4]<=wid[tt]^bad_bid;m_axi_bresp[tt*2+:2]<=0;end
   end
   if(m_axi_bvalid[tt]&&m_axi_bready[tt])m_axi_bvalid[tt]<=0;
   if(m_axi_arvalid[tt]&&m_axi_arready[tt])begin leftr[tt]<=m_axi_arlen[tt*8+:8]+1;rid[tt]<=m_axi_arid[tt*4+:4];rbeat[tt]<=0;end
   if(m_axi_rvalid[tt]&&m_axi_rready[tt])begin m_axi_rvalid[tt]<=0;leftr[tt]<=leftr[tt]-1;rbeat[tt]<=rbeat[tt]+1;end
   if(!m_axi_rvalid[tt]&&leftr[tt]>0&&cycles%3!=0)begin
    m_axi_rvalid[tt]<=1;m_axi_rid[tt*4+:4]<=rid[tt]^bad_rid;m_axi_rdata[tt*DATA_WIDTH+:DATA_WIDTH]<=32'h13570000+rbeat[tt];m_axi_rresp[tt*2+:2]<=0;m_axi_rlast[tt]<=(leftr[tt]==1)^bad_rlast;
   end
  end
 end
end
always @(negedge clk)begin
 m_axi_awready={TARGETS{cycles%3!=0}};m_axi_arready={TARGETS{cycles%4!=0}};m_axi_wready={TARGETS{cycles%5!=0}};
end
task reset_all;begin @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;end endtask
task automatic write_burst;
 input integer master;input[31:0]addr;input integer length;input integer expected;input integer corrupt;
 integer b;reg[3:0]ident;
 begin
 ident=5;
 @(negedge clk);s_axi_awaddr[master*32+:32]=addr;s_axi_awid[master*4+:4]=ident;s_axi_awlen[master*8+:8]=length;s_axi_awsize[master*3+:3]=$clog2(DATA_WIDTH/8);s_axi_awburst[master*2+:2]=1;s_axi_awvalid[master]=1;
 @(posedge clk);while(!s_axi_awready[master])@(posedge clk);
 @(negedge clk);s_axi_awvalid[master]=0;
 for(b=0;b<=length;b=b+1)begin
  s_axi_wvalid[master]=1;s_axi_wdata[master*DATA_WIDTH+:DATA_WIDTH]=32'h12340000+b;s_axi_wstrb[master*(DATA_WIDTH/8)+:(DATA_WIDTH/8)]={DATA_WIDTH/8{1'b1}};s_axi_wlast[master]=(b==length)^(corrupt&&b==0);
  @(posedge clk);while(!s_axi_wready[master])@(posedge clk);
  @(negedge clk);
 end
 s_axi_wvalid[master]=0;s_axi_bready[master]=0;
 @(posedge clk);while(!s_axi_bvalid[master])@(posedge clk);
 repeat(4)begin @(posedge clk);if(!s_axi_bvalid[master]||s_axi_bid[master*4+:4]!=ident||s_axi_bresp[master*2+:2]!=expected)$fatal(1,"B stable/response");end
 @(negedge clk);s_axi_bready[master]=1;@(posedge clk);@(negedge clk);s_axi_bready[master]=0;checks=checks+1;
 end
endtask
task automatic read_burst;
 input integer master;input[31:0]addr;input integer length;input integer expected;
 integer b;reg[DATA_WIDTH-1:0]held;
 begin
 @(negedge clk);s_axi_araddr[master*32+:32]=addr;s_axi_arid[master*4+:4]=5;s_axi_arlen[master*8+:8]=length;s_axi_arsize[master*3+:3]=$clog2(DATA_WIDTH/8);s_axi_arburst[master*2+:2]=1;s_axi_arvalid[master]=1;
 @(posedge clk);while(!s_axi_arready[master])@(posedge clk);
 @(negedge clk);s_axi_arvalid[master]=0;
 for(b=0;b<=length;b=b+1)begin
  @(posedge clk);while(!s_axi_rvalid[master])@(posedge clk);
  held=s_axi_rdata[master*DATA_WIDTH+:DATA_WIDTH];
  repeat(2)begin @(posedge clk);if(!s_axi_rvalid[master]||s_axi_rdata[master*DATA_WIDTH+:DATA_WIDTH]!=held)$fatal(1,"R stability");end
  if(s_axi_rid[master*4+:4]!=5||s_axi_rresp[master*2+:2]!=expected||s_axi_rlast[master]!=(b==length)||held!=(expected==3?0:32'h13570000+b))$fatal(1,"R payload/response");
  @(negedge clk);s_axi_rready[master]=1;@(posedge clk);@(negedge clk);s_axi_rready[master]=0;
 end
 checks=checks+1;
 end
endtask
initial begin
 repeat(2)@(negedge clk);reset_all;
 fork write_burst(0,32'h100,255,0,0);read_burst(1,32'h10100,255,0);join
 if(protocol_error)$fatal(1,"legal error");
 fork write_burst(0,32'h10000,15,0,0);write_burst(1,32'h10100,15,0,0);read_burst(0,32'h10000,15,0);read_burst(1,32'h10100,15,0);join
 fork write_burst(0,32'hfff,1,3,0);read_burst(1,32'hfff,1,3);join
 fork write_burst(0,32'hf0000000,3,3,0);read_burst(1,32'hf0000000,3,3);join
 write_burst(0,32'h100,3,2,1);if(!protocol_error)$fatal(1,"missing WLAST error");reset_all;
 bad_bid=1;write_burst(0,32'h100,1,0,0);if(!protocol_error)$fatal(1,"missing BID error");bad_bid=0;reset_all;
 bad_rid=1;bad_rlast=1;read_burst(1,32'h10100,3,0);if(!protocol_error)$fatal(1,"missing RID/RLAST error");bad_rid=0;bad_rlast=0;reset_all;
 // CE disables new descriptors, but already accepted bursts must complete.
 fork begin write_burst(0,32'h100,63,0,0);end begin repeat(10)@(negedge clk);ce=0;repeat(100)@(negedge clk);ce=1;end join
 if(protocol_error)$fatal(1,"CE disrupted accepted traffic");
 // Reset and enqueue every master simultaneously into target zero.
 reset_all;fairness_phase=1;
 @(negedge clk);
 for(ii=0;ii<MASTERS;ii=ii+1)begin s_axi_awaddr[ii*32+:32]=32'h2000+ii*256;s_axi_awid[ii*4+:4]=5;s_axi_awlen[ii*8+:8]=0;s_axi_awsize[ii*3+:3]=0;s_axi_awburst[ii*2+:2]=1;end
 s_axi_awvalid={MASTERS{1'b1}};s_axi_wvalid={MASTERS{1'b1}};s_axi_wlast={MASTERS{1'b1}};s_axi_bready={MASTERS{1'b1}};
 @(posedge clk);if(s_axi_awready!={MASTERS{1'b1}})$fatal(1,"admission");
 @(negedge clk);s_axi_awvalid=0;
 while(s_axi_wvalid!=0)begin @(posedge clk);sent_w=s_axi_wvalid&s_axi_wready;@(negedge clk);s_axi_wvalid=s_axi_wvalid&~sent_w;end
 wait(fair_b==MASTERS);@(negedge clk);fairness_phase=0;s_axi_bready=0;
 if(fairness_count!=MASTERS)$fatal(1,"fairness incomplete");checks=checks+1;
 // Coordinated reset aborts captured descriptors and clears sticky fault state.
 @(negedge clk);s_axi_awvalid[0]=1;s_axi_arvalid[0]=1;m_axi_awready=0;m_axi_arready=0;
 @(posedge clk);@(negedge clk);s_axi_awvalid=0;s_axi_arvalid=0;
 reset_all;repeat(5)@(negedge clk);
 if(s_axi_bvalid||s_axi_rvalid||m_axi_awvalid||m_axi_arvalid||protocol_error)$fatal(1,"reset retained transaction");
 write_burst(0,32'h100,0,0,0);read_burst(1,32'h10100,0,0);
 $display("PROTOCOL PASS M=%0d T=%0d W=%0d checks=%0d",MASTERS,TARGETS,DATA_WIDTH,checks);$finish;
end
endmodule

