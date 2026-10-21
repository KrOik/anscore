// Multi-initiator AXI4-Lite fabric. CE gates new upstream requests only.
module axil_multi_crossbar #(
 parameter MASTERS=2,TARGETS=4,ADDR_WIDTH=16,DATA_WIDTH=32,
 parameter REGION_ADDR_BITS=ADDR_WIDTH-3
)(
 input wire clk,rst_n,ce,
 input wire[MASTERS*ADDR_WIDTH-1:0]s_axil_awaddr,input wire[MASTERS*3-1:0]s_axil_awprot,
 input wire[MASTERS-1:0]s_axil_awvalid,output wire[MASTERS-1:0]s_axil_awready,
 input wire[MASTERS*DATA_WIDTH-1:0]s_axil_wdata,input wire[MASTERS*(DATA_WIDTH/8)-1:0]s_axil_wstrb,
 input wire[MASTERS-1:0]s_axil_wvalid,output wire[MASTERS-1:0]s_axil_wready,
 output wire[MASTERS*2-1:0]s_axil_bresp,output wire[MASTERS-1:0]s_axil_bvalid,input wire[MASTERS-1:0]s_axil_bready,
 input wire[MASTERS*ADDR_WIDTH-1:0]s_axil_araddr,input wire[MASTERS*3-1:0]s_axil_arprot,
 input wire[MASTERS-1:0]s_axil_arvalid,output wire[MASTERS-1:0]s_axil_arready,
 output wire[MASTERS*DATA_WIDTH-1:0]s_axil_rdata,output wire[MASTERS*2-1:0]s_axil_rresp,
 output wire[MASTERS-1:0]s_axil_rvalid,input wire[MASTERS-1:0]s_axil_rready,
 output wire[TARGETS*ADDR_WIDTH-1:0]m_axil_awaddr,output wire[TARGETS*3-1:0]m_axil_awprot,
 output wire[TARGETS-1:0]m_axil_awvalid,input wire[TARGETS-1:0]m_axil_awready,
 output wire[TARGETS*DATA_WIDTH-1:0]m_axil_wdata,output wire[TARGETS*(DATA_WIDTH/8)-1:0]m_axil_wstrb,
 output wire[TARGETS-1:0]m_axil_wvalid,input wire[TARGETS-1:0]m_axil_wready,
 input wire[TARGETS*2-1:0]m_axil_bresp,input wire[TARGETS-1:0]m_axil_bvalid,output wire[TARGETS-1:0]m_axil_bready,
 output wire[TARGETS*ADDR_WIDTH-1:0]m_axil_araddr,output wire[TARGETS*3-1:0]m_axil_arprot,
 output wire[TARGETS-1:0]m_axil_arvalid,input wire[TARGETS-1:0]m_axil_arready,
 input wire[TARGETS*DATA_WIDTH-1:0]m_axil_rdata,input wire[TARGETS*2-1:0]m_axil_rresp,
 input wire[TARGETS-1:0]m_axil_rvalid,output wire[TARGETS-1:0]m_axil_rready
);
 localparam SW=DATA_WIDTH/8;
 localparam IW=MASTERS<=1?1:$clog2(MASTERS);
 localparam CONFIG_OK=MASTERS>=1&&MASTERS<=4&&TARGETS>=1&&TARGETS<=8&&
 ADDR_WIDTH>=4&&ADDR_WIDTH<=32&&(DATA_WIDTH==32||DATA_WIDTH==64)&&
 REGION_ADDR_BITS>=1&&REGION_ADDR_BITS<=ADDR_WIDTH;
 reg[MASTERS-1:0]aw_full,w_full,ar_full,wb,rb,bv,rv;
 reg[ADDR_WIDTH-1:0]aw_addr[0:MASTERS-1],ar_addr[0:MASTERS-1];
 reg[2:0]aw_prot[0:MASTERS-1],ar_prot[0:MASTERS-1];
 reg[DATA_WIDTH-1:0]w_data[0:MASTERS-1],r_data[0:MASTERS-1];
 reg[SW-1:0]w_strb[0:MASTERS-1];
 reg[1:0]b_resp[0:MASTERS-1],r_resp[0:MASTERS-1];
 reg[TARGETS-1:0]tw_busy,tr_busy,tav,twv,tarv;
 reg[IW-1:0]wo[0:TARGETS-1],ro[0:TARGETS-1],wrr[0:TARGETS-1],rrr[0:TARGETS-1];
 reg[ADDR_WIDTH-1:0]ta[0:TARGETS-1],tra[0:TARGETS-1];
 reg[2:0]tp[0:TARGETS-1],trp[0:TARGETS-1];
 reg[DATA_WIDTH-1:0]td[0:TARGETS-1];reg[SW-1:0]ts[0:TARGETS-1];
 integer wg[0:TARGETS-1],rg[0:TARGETS-1];integer t,k,idx;
 function[ADDR_WIDTH-1:0]local_address;
 input[ADDR_WIDTH-1:0]a;begin local_address=a&({ADDR_WIDTH{1'b1}}>>(ADDR_WIDTH-REGION_ADDR_BITS));end
 endfunction
 always @*begin
 for(t=0;t<TARGETS;t=t+1)begin
 wg[t]=-1;rg[t]=-1;
 for(k=0;k<MASTERS;k=k+1)begin
 idx=wrr[t]+k;if(idx>=MASTERS)idx=idx-MASTERS;
 if(wg[t]<0&&aw_full[idx]&&w_full[idx]&&!wb[idx]&&((aw_addr[idx]>>REGION_ADDR_BITS)==t))wg[t]=idx;
 idx=rrr[t]+k;if(idx>=MASTERS)idx=idx-MASTERS;
 if(rg[t]<0&&ar_full[idx]&&!rb[idx]&&((ar_addr[idx]>>REGION_ADDR_BITS)==t))rg[t]=idx;
 end
 end
 end
 genvar g;
 generate for(g=0;g<MASTERS;g=g+1)begin:up
 assign s_axil_awready[g]=rst_n&&ce&&CONFIG_OK&&!aw_full[g]&&!wb[g];
 assign s_axil_wready[g]=rst_n&&ce&&CONFIG_OK&&!w_full[g]&&!wb[g];
 assign s_axil_arready[g]=rst_n&&ce&&CONFIG_OK&&!ar_full[g]&&!rb[g];
 assign s_axil_bvalid[g]=bv[g];assign s_axil_bresp[g*2+:2]=b_resp[g];
 assign s_axil_rvalid[g]=rv[g];assign s_axil_rresp[g*2+:2]=r_resp[g];
 assign s_axil_rdata[g*DATA_WIDTH+:DATA_WIDTH]=r_data[g];
 end
 for(g=0;g<TARGETS;g=g+1)begin:down
 assign m_axil_awaddr[g*ADDR_WIDTH+:ADDR_WIDTH]=ta[g];assign m_axil_awprot[g*3+:3]=tp[g];
 assign m_axil_awvalid[g]=tav[g];assign m_axil_wvalid[g]=twv[g];
 assign m_axil_wdata[g*DATA_WIDTH+:DATA_WIDTH]=td[g];assign m_axil_wstrb[g*SW+:SW]=ts[g];
 assign m_axil_bready[g]=tw_busy[g]&&!tav[g]&&!twv[g]&&!bv[wo[g]];
 assign m_axil_araddr[g*ADDR_WIDTH+:ADDR_WIDTH]=tra[g];assign m_axil_arprot[g*3+:3]=trp[g];
 assign m_axil_arvalid[g]=tarv[g];
 assign m_axil_rready[g]=tr_busy[g]&&!tarv[g]&&!rv[ro[g]];
 end endgenerate
 integer i,j;
 always @(posedge clk)begin
 if(!rst_n)begin
 aw_full<=0;w_full<=0;ar_full<=0;wb<=0;rb<=0;bv<=0;rv<=0;
 tw_busy<=0;tr_busy<=0;tav<=0;twv<=0;tarv<=0;
 for(i=0;i<MASTERS;i=i+1)begin aw_addr[i]<=0;ar_addr[i]<=0;aw_prot[i]<=0;ar_prot[i]<=0;w_data[i]<=0;w_strb[i]<=0;b_resp[i]<=0;r_resp[i]<=0;r_data[i]<=0;end
 for(j=0;j<TARGETS;j=j+1)begin wo[j]<=0;ro[j]<=0;wrr[j]<=0;rrr[j]<=0;ta[j]<=0;tra[j]<=0;tp[j]<=0;trp[j]<=0;td[j]<=0;ts[j]<=0;end
 end else begin
 for(i=0;i<MASTERS;i=i+1)begin
 if(s_axil_awvalid[i]&&s_axil_awready[i])begin aw_full[i]<=1;aw_addr[i]<=s_axil_awaddr[i*ADDR_WIDTH+:ADDR_WIDTH];aw_prot[i]<=s_axil_awprot[i*3+:3];end
 if(s_axil_wvalid[i]&&s_axil_wready[i])begin w_full[i]<=1;w_data[i]<=s_axil_wdata[i*DATA_WIDTH+:DATA_WIDTH];w_strb[i]<=s_axil_wstrb[i*SW+:SW];end
 if(s_axil_arvalid[i]&&s_axil_arready[i])begin ar_full[i]<=1;ar_addr[i]<=s_axil_araddr[i*ADDR_WIDTH+:ADDR_WIDTH];ar_prot[i]<=s_axil_arprot[i*3+:3];end
 if(bv[i]&&s_axil_bready[i])begin bv[i]<=0;wb[i]<=0;end
 if(rv[i]&&s_axil_rready[i])begin rv[i]<=0;rb[i]<=0;end
 if(aw_full[i]&&w_full[i]&&!wb[i]&&((aw_addr[i]>>REGION_ADDR_BITS)>=TARGETS))begin aw_full[i]<=0;w_full[i]<=0;wb[i]<=1;bv[i]<=1;b_resp[i]<=3;end
 if(ar_full[i]&&!rb[i]&&((ar_addr[i]>>REGION_ADDR_BITS)>=TARGETS))begin ar_full[i]<=0;rb[i]<=1;rv[i]<=1;r_resp[i]<=3;r_data[i]<=0;end
 end
 for(j=0;j<TARGETS;j=j+1)begin
 if(tav[j]&&m_axil_awready[j])tav[j]<=0;
 if(twv[j]&&m_axil_wready[j])twv[j]<=0;
 if(tarv[j]&&m_axil_arready[j])tarv[j]<=0;
 if(!tw_busy[j]&&wg[j]>=0)begin
 wo[j]<=wg[j];tw_busy[j]<=1;wb[wg[j]]<=1;aw_full[wg[j]]<=0;w_full[wg[j]]<=0;
 ta[j]<=local_address(aw_addr[wg[j]]);tp[j]<=aw_prot[wg[j]];td[j]<=w_data[wg[j]];ts[j]<=w_strb[wg[j]];tav[j]<=1;twv[j]<=1;
 end
 if(m_axil_bvalid[j]&&m_axil_bready[j])begin
 bv[wo[j]]<=1;b_resp[wo[j]]<=m_axil_bresp[j*2+:2];tw_busy[j]<=0;
 wrr[j]<=wo[j]==MASTERS-1?0:wo[j]+1'b1;
 end
 if(!tr_busy[j]&&rg[j]>=0)begin
 ro[j]<=rg[j];tr_busy[j]<=1;rb[rg[j]]<=1;ar_full[rg[j]]<=0;
 tra[j]<=local_address(ar_addr[rg[j]]);trp[j]<=ar_prot[rg[j]];tarv[j]<=1;
 end
 if(m_axil_rvalid[j]&&m_axil_rready[j])begin
 rv[ro[j]]<=1;r_data[ro[j]]<=m_axil_rdata[j*DATA_WIDTH+:DATA_WIDTH];r_resp[ro[j]]<=m_axil_rresp[j*2+:2];tr_busy[j]<=0;
 rrr[j]<=ro[j]==MASTERS-1?0:ro[j]+1'b1;
 end
 end
 end
 end
endmodule
