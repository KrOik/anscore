// Full AXI4 burst router. One outstanding/master/direction and target/direction.
module axi_multi_crossbar #(
 parameter MASTERS=2,TARGETS=2,ADDR_WIDTH=32,DATA_WIDTH=32,ID_WIDTH=4,
 parameter REGION_ADDR_BITS=16)(
input wire clk,rst_n,ce,
output reg protocol_error,
input wire[MASTERS*(ID_WIDTH)-1:0]s_axi_awid,
input wire[MASTERS*(ADDR_WIDTH)-1:0]s_axi_awaddr,
input wire[MASTERS*(8)-1:0]s_axi_awlen,
input wire[MASTERS*(3)-1:0]s_axi_awsize,
input wire[MASTERS*(2)-1:0]s_axi_awburst,
input wire[MASTERS-1:0]s_axi_awlock,
input wire[MASTERS*(4)-1:0]s_axi_awcache,
input wire[MASTERS*(3)-1:0]s_axi_awprot,
input wire[MASTERS*(4)-1:0]s_axi_awqos,
input wire[MASTERS*(4)-1:0]s_axi_awregion,
input wire[MASTERS-1:0]s_axi_awvalid,
output reg[MASTERS-1:0]s_axi_awready,
input wire[MASTERS*(ID_WIDTH)-1:0]s_axi_arid,
input wire[MASTERS*(ADDR_WIDTH)-1:0]s_axi_araddr,
input wire[MASTERS*(8)-1:0]s_axi_arlen,
input wire[MASTERS*(3)-1:0]s_axi_arsize,
input wire[MASTERS*(2)-1:0]s_axi_arburst,
input wire[MASTERS-1:0]s_axi_arlock,
input wire[MASTERS*(4)-1:0]s_axi_arcache,
input wire[MASTERS*(3)-1:0]s_axi_arprot,
input wire[MASTERS*(4)-1:0]s_axi_arqos,
input wire[MASTERS*(4)-1:0]s_axi_arregion,
input wire[MASTERS-1:0]s_axi_arvalid,
output reg[MASTERS-1:0]s_axi_arready,
input wire[MASTERS*(DATA_WIDTH)-1:0]s_axi_wdata,
input wire[MASTERS*(DATA_WIDTH/8)-1:0]s_axi_wstrb,
input wire[MASTERS-1:0]s_axi_wlast,
input wire[MASTERS-1:0]s_axi_wvalid,
output reg[MASTERS-1:0]s_axi_wready,
output reg[MASTERS*(ID_WIDTH)-1:0]s_axi_bid,
output reg[MASTERS*(2)-1:0]s_axi_bresp,
output reg[MASTERS-1:0]s_axi_bvalid,
input wire[MASTERS-1:0]s_axi_bready,
output reg[MASTERS*(ID_WIDTH)-1:0]s_axi_rid,
output reg[MASTERS*(DATA_WIDTH)-1:0]s_axi_rdata,
output reg[MASTERS*(2)-1:0]s_axi_rresp,
output reg[MASTERS-1:0]s_axi_rlast,
output reg[MASTERS-1:0]s_axi_rvalid,
input wire[MASTERS-1:0]s_axi_rready,
output reg[TARGETS*(ID_WIDTH)-1:0]m_axi_awid,
output reg[TARGETS*(ADDR_WIDTH)-1:0]m_axi_awaddr,
output reg[TARGETS*(8)-1:0]m_axi_awlen,
output reg[TARGETS*(3)-1:0]m_axi_awsize,
output reg[TARGETS*(2)-1:0]m_axi_awburst,
output reg[TARGETS-1:0]m_axi_awlock,
output reg[TARGETS*(4)-1:0]m_axi_awcache,
output reg[TARGETS*(3)-1:0]m_axi_awprot,
output reg[TARGETS*(4)-1:0]m_axi_awqos,
output reg[TARGETS*(4)-1:0]m_axi_awregion,
output reg[TARGETS-1:0]m_axi_awvalid,
input wire[TARGETS-1:0]m_axi_awready,
output reg[TARGETS*(ID_WIDTH)-1:0]m_axi_arid,
output reg[TARGETS*(ADDR_WIDTH)-1:0]m_axi_araddr,
output reg[TARGETS*(8)-1:0]m_axi_arlen,
output reg[TARGETS*(3)-1:0]m_axi_arsize,
output reg[TARGETS*(2)-1:0]m_axi_arburst,
output reg[TARGETS-1:0]m_axi_arlock,
output reg[TARGETS*(4)-1:0]m_axi_arcache,
output reg[TARGETS*(3)-1:0]m_axi_arprot,
output reg[TARGETS*(4)-1:0]m_axi_arqos,
output reg[TARGETS*(4)-1:0]m_axi_arregion,
output reg[TARGETS-1:0]m_axi_arvalid,
input wire[TARGETS-1:0]m_axi_arready,
output reg[TARGETS*(DATA_WIDTH)-1:0]m_axi_wdata,
output reg[TARGETS*(DATA_WIDTH/8)-1:0]m_axi_wstrb,
output reg[TARGETS-1:0]m_axi_wlast,
output reg[TARGETS-1:0]m_axi_wvalid,
input wire[TARGETS-1:0]m_axi_wready,
input wire[TARGETS*(ID_WIDTH)-1:0]m_axi_bid,
input wire[TARGETS*(2)-1:0]m_axi_bresp,
input wire[TARGETS-1:0]m_axi_bvalid,
output reg[TARGETS-1:0]m_axi_bready,
input wire[TARGETS*(ID_WIDTH)-1:0]m_axi_rid,
input wire[TARGETS*(DATA_WIDTH)-1:0]m_axi_rdata,
input wire[TARGETS*(2)-1:0]m_axi_rresp,
input wire[TARGETS-1:0]m_axi_rlast,
input wire[TARGETS-1:0]m_axi_rvalid,
output reg[TARGETS-1:0]m_axi_rready);
 localparam SW=DATA_WIDTH/8,IW=$clog2(MASTERS),TW=$clog2(TARGETS);
 localparam VALID_CONFIG=MASTERS>=2&&MASTERS<=4&&TARGETS>=2&&TARGETS<=4&&ADDR_WIDTH==32&&(DATA_WIDTH==32||DATA_WIDTH==64)&&ID_WIDTH>=1&&ID_WIDTH<=8&&REGION_ADDR_BITS>=8&&REGION_ADDR_BITS<=28;
 reg[MASTERS-1:0]wb,wp,wx,we,rb,rp,rx;
 reg[ADDR_WIDTH-1:0]wa[0:MASTERS-1],ra[0:MASTERS-1];
 reg[ID_WIDTH-1:0]wi[0:MASTERS-1],ri[0:MASTERS-1];
 reg[7:0]wl[0:MASTERS-1],rl[0:MASTERS-1];
 reg[2:0]ws[0:MASTERS-1],rs[0:MASTERS-1],wprot[0:MASTERS-1],rprot[0:MASTERS-1];
 reg[1:0]wburst[0:MASTERS-1],rburst[0:MASTERS-1];
 reg[3:0]wc[0:MASTERS-1],rc[0:MASTERS-1],wq[0:MASTERS-1],rq[0:MASTERS-1],wrgn[0:MASTERS-1],rrgn[0:MASTERS-1];
 reg[TW-1:0]wd[0:MASTERS-1],rd[0:MASTERS-1];
 reg[8:0]wleft[0:MASTERS-1],rleft[0:MASTERS-1];
 reg[TARGETS-1:0]wactive,ractive,aw_sent,ar_sent;
 reg[IW-1:0]wo[0:TARGETS-1],ro[0:TARGETS-1],wrr[0:TARGETS-1],rrr[0:TARGETS-1];
 integer wg[0:TARGETS-1],rg[0:TARGETS-1];
 integer t,k,x,j;
 function good_request;
 input[31:0]a;input[7:0]len;input[2:0]size;input[1:0]burst;input lock;
 reg[32:0]bytes,span,aligned,first,last;
 begin
  bytes=33'd1<<size;span=({25'b0,len}+1'b1)<<size;
  aligned={1'b0,a}&~(bytes-1'b1);first={1'b0,a};last=aligned+bytes-1'b1;
  good_request=VALID_CONFIG&&!lock&&size<=$clog2(SW)&&burst!=3;
  if(burst==0)begin if(len>15)good_request=0;end
  else if(burst==1)last=aligned+span-1'b1;
  else if(burst==2)begin
   if((len!=1&&len!=3&&len!=7&&len!=15)||aligned!={1'b0,a})good_request=0;
   first={1'b0,a}&~(span-1'b1);last=first+span-1'b1;
  end
  if(last[32]||first[32]||(first>>12)!=(last>>12)||(first>>REGION_ADDR_BITS)!=(last>>REGION_ADDR_BITS)||(first>>REGION_ADDR_BITS)>=TARGETS)good_request=0;
 end endfunction
 function[31:0]local_address;input[31:0]a;begin local_address=a&((32'hffffffff)>>(32-REGION_ADDR_BITS));end endfunction
 always @*begin
  s_axi_awready=0;
  s_axi_arready=0;
  s_axi_wready=0;
  s_axi_bid=0;
  s_axi_bresp=0;
  s_axi_bvalid=0;
  s_axi_rid=0;
  s_axi_rdata=0;
  s_axi_rresp=0;
  s_axi_rlast=0;
  s_axi_rvalid=0;
  m_axi_awid=0;
  m_axi_awaddr=0;
  m_axi_awlen=0;
  m_axi_awsize=0;
  m_axi_awburst=0;
  m_axi_awlock=0;
  m_axi_awcache=0;
  m_axi_awprot=0;
  m_axi_awqos=0;
  m_axi_awregion=0;
  m_axi_awvalid=0;
  m_axi_arid=0;
  m_axi_araddr=0;
  m_axi_arlen=0;
  m_axi_arsize=0;
  m_axi_arburst=0;
  m_axi_arlock=0;
  m_axi_arcache=0;
  m_axi_arprot=0;
  m_axi_arqos=0;
  m_axi_arregion=0;
  m_axi_arvalid=0;
  m_axi_wdata=0;
  m_axi_wstrb=0;
  m_axi_wlast=0;
  m_axi_wvalid=0;
  m_axi_bready=0;
  m_axi_rready=0;
  for(t=0;t<TARGETS;t=t+1)begin
   wg[t]=-1;rg[t]=-1;
   for(k=0;k<MASTERS;k=k+1)begin
    x=wrr[t]+k;if(x>=MASTERS)x=x-MASTERS;
    if(!wactive[t]&&wp[x]&&wd[x]==t&&wg[t]<0)wg[t]=x;
    x=rrr[t]+k;if(x>=MASTERS)x=x-MASTERS;
    if(!ractive[t]&&rp[x]&&rd[x]==t&&rg[t]<0)rg[t]=x;
   end
  end
  if(rst_n)begin
   for(j=0;j<MASTERS;j=j+1)begin
    s_axi_awready[j]=ce&&!wb[j];s_axi_arready[j]=ce&&!rb[j];
    if(wb[j]&&wx[j])begin
     s_axi_wready[j]=wleft[j]!=0;
     s_axi_bvalid[j]=wleft[j]==0;s_axi_bid[j*ID_WIDTH+:ID_WIDTH]=wi[j];s_axi_bresp[j*2+:2]=3;
    end
    if(rb[j]&&rx[j])begin
     s_axi_rvalid[j]=1;s_axi_rid[j*ID_WIDTH+:ID_WIDTH]=ri[j];s_axi_rresp[j*2+:2]=3;s_axi_rlast[j]=rleft[j]==1;
    end
   end
   for(t=0;t<TARGETS;t=t+1)begin
    if(wactive[t])begin
     x=wo[t];
     m_axi_awvalid[t]=!aw_sent[t];
     m_axi_awid[t*ID_WIDTH+:ID_WIDTH]=wi[x];m_axi_awaddr[t*ADDR_WIDTH+:ADDR_WIDTH]=local_address(wa[x]);
     m_axi_awlen[t*8+:8]=wl[x];m_axi_awsize[t*3+:3]=ws[x];m_axi_awburst[t*2+:2]=wburst[x];
     m_axi_awcache[t*4+:4]=wc[x];m_axi_awprot[t*3+:3]=wprot[x];m_axi_awqos[t*4+:4]=wq[x];m_axi_awregion[t*4+:4]=wrgn[x];
     if(aw_sent[t]&&wleft[x]!=0)begin
      m_axi_wvalid[t]=s_axi_wvalid[x];m_axi_wdata[t*DATA_WIDTH+:DATA_WIDTH]=s_axi_wdata[x*DATA_WIDTH+:DATA_WIDTH];m_axi_wstrb[t*SW+:SW]=s_axi_wstrb[x*SW+:SW];m_axi_wlast[t]=wleft[x]==1;s_axi_wready[x]=m_axi_wready[t];
     end
     if(aw_sent[t]&&wleft[x]==0)begin
      s_axi_bvalid[x]=m_axi_bvalid[t];s_axi_bid[x*ID_WIDTH+:ID_WIDTH]=wi[x];s_axi_bresp[x*2+:2]=we[x]&&m_axi_bresp[t*2+:2]<2?2:m_axi_bresp[t*2+:2];m_axi_bready[t]=s_axi_bready[x];
     end
    end
    if(ractive[t])begin
     x=ro[t];
     m_axi_arvalid[t]=!ar_sent[t];
     m_axi_arid[t*ID_WIDTH+:ID_WIDTH]=ri[x];m_axi_araddr[t*ADDR_WIDTH+:ADDR_WIDTH]=local_address(ra[x]);
     m_axi_arlen[t*8+:8]=rl[x];m_axi_arsize[t*3+:3]=rs[x];m_axi_arburst[t*2+:2]=rburst[x];
     m_axi_arcache[t*4+:4]=rc[x];m_axi_arprot[t*3+:3]=rprot[x];m_axi_arqos[t*4+:4]=rq[x];m_axi_arregion[t*4+:4]=rrgn[x];
     if(ar_sent[t])begin
      s_axi_rvalid[x]=m_axi_rvalid[t];s_axi_rid[x*ID_WIDTH+:ID_WIDTH]=ri[x];s_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH]=m_axi_rdata[t*DATA_WIDTH+:DATA_WIDTH];s_axi_rresp[x*2+:2]=m_axi_rresp[t*2+:2];s_axi_rlast[x]=rleft[x]==1;m_axi_rready[t]=s_axi_rready[x];
     end
    end
   end
  end
 end
 integer m,s;
 always @(posedge clk)begin
 if(!rst_n)begin
  wb<=0;wp<=0;wx<=0;we<=0;rb<=0;rp<=0;rx<=0;wactive<=0;ractive<=0;aw_sent<=0;ar_sent<=0;protocol_error<=0;
  for(m=0;m<MASTERS;m=m+1)begin wa[m]<=0;ra[m]<=0;wi[m]<=0;ri[m]<=0;wl[m]<=0;rl[m]<=0;ws[m]<=0;rs[m]<=0;wprot[m]<=0;rprot[m]<=0;wburst[m]<=0;rburst[m]<=0;wc[m]<=0;rc[m]<=0;wq[m]<=0;rq[m]<=0;wrgn[m]<=0;rrgn[m]<=0;wd[m]<=0;rd[m]<=0;wleft[m]<=0;rleft[m]<=0;end
  for(s=0;s<TARGETS;s=s+1)begin wo[s]<=0;ro[s]<=0;wrr[s]<=0;rrr[s]<=0;end
 end else begin
  for(m=0;m<MASTERS;m=m+1)begin
   if(s_axi_awvalid[m]&&s_axi_awready[m])begin
    wb[m]<=1;wp[m]<=good_request(s_axi_awaddr[m*ADDR_WIDTH+:ADDR_WIDTH],s_axi_awlen[m*8+:8],s_axi_awsize[m*3+:3],s_axi_awburst[m*2+:2],s_axi_awlock[m]);wx[m]<=!good_request(s_axi_awaddr[m*ADDR_WIDTH+:ADDR_WIDTH],s_axi_awlen[m*8+:8],s_axi_awsize[m*3+:3],s_axi_awburst[m*2+:2],s_axi_awlock[m]);we[m]<=0;
    wa[m]<=s_axi_awaddr[m*ADDR_WIDTH+:ADDR_WIDTH];wi[m]<=s_axi_awid[m*ID_WIDTH+:ID_WIDTH];wl[m]<=s_axi_awlen[m*8+:8];ws[m]<=s_axi_awsize[m*3+:3];wburst[m]<=s_axi_awburst[m*2+:2];wc[m]<=s_axi_awcache[m*4+:4];wprot[m]<=s_axi_awprot[m*3+:3];wq[m]<=s_axi_awqos[m*4+:4];wrgn[m]<=s_axi_awregion[m*4+:4];wd[m]<=s_axi_awaddr[m*ADDR_WIDTH+:ADDR_WIDTH]>>REGION_ADDR_BITS;wleft[m]<={1'b0,s_axi_awlen[m*8+:8]}+1'b1;
   end
   if(s_axi_wvalid[m]&&s_axi_wready[m])begin
    wleft[m]<=wleft[m]-1'b1;
    if(s_axi_wlast[m]!=(wleft[m]==1))begin protocol_error<=1;we[m]<=1;end
   end
   if(s_axi_bvalid[m]&&s_axi_bready[m])wb[m]<=0;
   if(s_axi_arvalid[m]&&s_axi_arready[m])begin
    rb[m]<=1;rp[m]<=good_request(s_axi_araddr[m*ADDR_WIDTH+:ADDR_WIDTH],s_axi_arlen[m*8+:8],s_axi_arsize[m*3+:3],s_axi_arburst[m*2+:2],s_axi_arlock[m]);rx[m]<=!good_request(s_axi_araddr[m*ADDR_WIDTH+:ADDR_WIDTH],s_axi_arlen[m*8+:8],s_axi_arsize[m*3+:3],s_axi_arburst[m*2+:2],s_axi_arlock[m]);
    ra[m]<=s_axi_araddr[m*ADDR_WIDTH+:ADDR_WIDTH];ri[m]<=s_axi_arid[m*ID_WIDTH+:ID_WIDTH];rl[m]<=s_axi_arlen[m*8+:8];rs[m]<=s_axi_arsize[m*3+:3];rburst[m]<=s_axi_arburst[m*2+:2];rc[m]<=s_axi_arcache[m*4+:4];rprot[m]<=s_axi_arprot[m*3+:3];rq[m]<=s_axi_arqos[m*4+:4];rrgn[m]<=s_axi_arregion[m*4+:4];rd[m]<=s_axi_araddr[m*ADDR_WIDTH+:ADDR_WIDTH]>>REGION_ADDR_BITS;rleft[m]<={1'b0,s_axi_arlen[m*8+:8]}+1'b1;
   end
   if(s_axi_rvalid[m]&&s_axi_rready[m])begin
    rleft[m]<=rleft[m]-1'b1;if(rleft[m]==1)rb[m]<=0;
   end
  end
  for(s=0;s<TARGETS;s=s+1)begin
   if(wg[s]>=0)begin wactive[s]<=1;aw_sent[s]<=0;wo[s]<=wg[s];wp[wg[s]]<=0;wrr[s]<=wg[s]==MASTERS-1?0:wg[s]+1;end
   if(m_axi_awvalid[s]&&m_axi_awready[s])aw_sent[s]<=1;
   if(m_axi_bvalid[s]&&m_axi_bready[s])begin
    wactive[s]<=0;aw_sent[s]<=0;if(m_axi_bid[s*ID_WIDTH+:ID_WIDTH]!=wi[wo[s]])protocol_error<=1;
   end
   if(rg[s]>=0)begin ractive[s]<=1;ar_sent[s]<=0;ro[s]<=rg[s];rp[rg[s]]<=0;rrr[s]<=rg[s]==MASTERS-1?0:rg[s]+1;end
   if(m_axi_arvalid[s]&&m_axi_arready[s])ar_sent[s]<=1;
   if(m_axi_rvalid[s]&&m_axi_rready[s])begin
    if(m_axi_rid[s*ID_WIDTH+:ID_WIDTH]!=ri[ro[s]]||m_axi_rlast[s]!=(rleft[ro[s]]==1))protocol_error<=1;
    if(rleft[ro[s]]==1)begin ractive[s]<=0;ar_sent[s]<=0;end
   end
  end
 end end
 initial if(!VALID_CONFIG)$fatal(1,"invalid AXI crossbar parameters");
endmodule
