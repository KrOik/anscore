"""Independent concurrent initiator/target AXI4-Lite scoreboard."""
from pathlib import Path
import hashlib,json,sys,tempfile,re
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'axil_multi_crossbar.sv'
TB=r'''module tb;
localparam M=@M@,T=@T@,DW=@DW@,AW=16,RB=12,SW=DW/8,N=@N@;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;
reg[M*AW-1:0]s_axil_awaddr=0,s_axil_araddr=0;reg[M*3-1:0]s_axil_awprot=0,s_axil_arprot=0;
reg[M-1:0]s_axil_awvalid=0,s_axil_wvalid=0,s_axil_bready=0,s_axil_arvalid=0,s_axil_rready=0;
wire[M-1:0]s_axil_awready,s_axil_wready,s_axil_bvalid,s_axil_arready,s_axil_rvalid;
reg[M*DW-1:0]s_axil_wdata=0;reg[M*SW-1:0]s_axil_wstrb=0;wire[M*2-1:0]s_axil_bresp,s_axil_rresp;wire[M*DW-1:0]s_axil_rdata;
wire[T*AW-1:0]m_axil_awaddr,m_axil_araddr;wire[T*3-1:0]m_axil_awprot,m_axil_arprot;
wire[T-1:0]m_axil_awvalid,m_axil_wvalid,m_axil_bready,m_axil_arvalid,m_axil_rready;
reg[T-1:0]m_axil_awready=0,m_axil_wready=0,m_axil_bvalid=0,m_axil_arready=0,m_axil_rvalid=0;
wire[T*DW-1:0]m_axil_wdata;wire[T*SW-1:0]m_axil_wstrb;reg[T*2-1:0]m_axil_bresp=0,m_axil_rresp=0;reg[T*DW-1:0]m_axil_rdata=0;
axil_multi_crossbar #(.MASTERS(M),.TARGETS(T),.ADDR_WIDTH(AW),.DATA_WIDTH(DW),.REGION_ADDR_BITS(RB))dut(.*);
integer wi[0:M-1],ri[0:M-1];reg aws[0:M-1],ws[0:M-1],ars[0:M-1],awo[0:M-1],wof[0:M-1],aro[0:M-1];
reg taw[0:T-1],tww[0:T-1],tar[0:T-1];reg[AW-1:0]ta[0:T-1],ra[0:T-1];reg[2:0]tp[0:T-1],rp[0:T-1];reg[DW-1:0]td[0:T-1];reg[SW-1:0]ts[0:T-1];integer bt[0:T-1],rt[0:T-1];
reg hb[0:M-1],hr[0:M-1],ha[0:T-1],hw[0:T-1],har[0:T-1];reg[1:0]pb[0:M-1];reg[DW+1:0]pr[0:M-1];reg[AW+2:0]pa[0:T-1],par[0:T-1];reg[DW+SW-1:0]pw[0:T-1];
integer m,t,k,cyc=0,completed=0,dispatchw=0,dispatchr=0,offresponse=0,parallel=0,active_targets,all_done;reg[31:0]rng=32'h91a5e291;
function integer target;
input integer master,n;
begin
if(n<8)target=0;
else if(n%7==0&&T<8)target=T;
else target=(master+n)%T;
end endfunction
function[15:0]addr;
input integer master,n;
begin addr=(target(master,n)<<12)|(master<<8)|(n<<2);end endfunction
function[DW-1:0]payload;
input integer master,n;
begin payload=64'h5a9b0000a5000000^(master<<20)^n;end endfunction
function[DW-1:0]read_value;
input integer port;input[15:0]local_;input[2:0]prot;
begin read_value=64'h98765432a5000000^(port<<20)^local_^(prot<<16);end endfunction
function[SW-1:0]strobe;
input integer master,n;
begin strobe=(n*11+master)&((1<<SW)-1);end endfunction
always @(negedge clk)if(rst_n)begin
rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
ce=cyc%31>7;
for(m=0;m<M;m=m+1)begin
if(wi[m]<N)begin
if(!aws[m]&&!awo[m]&&((rng>>(m+1))&1))awo[m]=1;
if(!ws[m]&&!wof[m]&&((rng>>(m+6))&1))wof[m]=1;
end
if(ri[m]<N&&!ars[m]&&!aro[m]&&((rng>>(m+12))&1))aro[m]=1;
s_axil_awvalid[m]=awo[m];s_axil_wvalid[m]=wof[m];s_axil_arvalid[m]=aro[m];
s_axil_awaddr[m*AW+:AW]=addr(m,wi[m]);s_axil_araddr[m*AW+:AW]=addr(m,ri[m]);
s_axil_awprot[m*3+:3]=(wi[m]+m)&7;s_axil_arprot[m*3+:3]=(ri[m]+m*3)&7;
s_axil_wdata[m*DW+:DW]=payload(m,wi[m]);s_axil_wstrb[m*SW+:SW]=strobe(m,wi[m]);
s_axil_bready[m]=(rng>>(m+17))&1;s_axil_rready[m]=(rng>>(m+23))&1;
end
for(t=0;t<T;t=t+1)begin
m_axil_awready[t]=!taw[t]&&((rng>>(t%8))&1);
m_axil_wready[t]=!tww[t]&&((rng>>(8+t%8))&1);
m_axil_arready[t]=!tar[t]&&((rng>>(16+t%8))&1);
end
end
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>100000)$fatal(1,"timeout");
for(m=0;m<M;m=m+1)begin
if(!ce&&(s_axil_awready[m]||s_axil_wready[m]||s_axil_arready[m]))$fatal(1,"new request CEoff");
if(hb[m]&&(!s_axil_bvalid[m]||s_axil_bresp[m*2+:2]!==pb[m]))$fatal(1,"B hold");
if(hr[m]&&(!s_axil_rvalid[m]||{s_axil_rdata[m*DW+:DW],s_axil_rresp[m*2+:2]}!==pr[m]))$fatal(1,"R hold");
hb[m]=s_axil_bvalid[m]&&!s_axil_bready[m];pb[m]=s_axil_bresp[m*2+:2];hr[m]=s_axil_rvalid[m]&&!s_axil_rready[m];pr[m]={s_axil_rdata[m*DW+:DW],s_axil_rresp[m*2+:2]};
if(s_axil_awvalid[m]&&s_axil_awready[m])begin if(aws[m])$fatal(1,"duplicate AW");aws[m]=1;awo[m]=0;end
if(s_axil_wvalid[m]&&s_axil_wready[m])begin if(ws[m])$fatal(1,"duplicate W");ws[m]=1;wof[m]=0;end
if(s_axil_arvalid[m]&&s_axil_arready[m])begin if(ars[m])$fatal(1,"duplicate AR");ars[m]=1;aro[m]=0;end
if(s_axil_bvalid[m]&&s_axil_bready[m])begin
if(!aws[m]||!ws[m]||s_axil_bresp[m*2+:2]!==((target(m,wi[m])>=T)?2'b11:(wi[m]&4)?2'b10:2'b00))$fatal(1,"B oracle master %d transaction %d",m,wi[m]);
wi[m]=wi[m]+1;aws[m]=0;ws[m]=0;completed=completed+1;if(!ce)offresponse=offresponse+1;
end
if(s_axil_rvalid[m]&&s_axil_rready[m])begin
if(!ars[m])$fatal(1,"unexpected R");
if(target(m,ri[m])>=T)begin if(s_axil_rdata[m*DW+:DW]!==0||s_axil_rresp[m*2+:2]!==3)$fatal(1,"DECERR oracle");end
else if(s_axil_rdata[m*DW+:DW]!==read_value(target(m,ri[m]),addr(m,ri[m])&4095,(ri[m]+m*3)&7)||s_axil_rresp[m*2+:2]!==((ri[m]&8)?2'b10:2'b00))$fatal(1,"R oracle %d %d",m,ri[m]);
ri[m]=ri[m]+1;ars[m]=0;completed=completed+1;if(!ce)offresponse=offresponse+1;
end
end
active_targets=0;
for(t=0;t<T;t=t+1)begin
if(ha[t]&&(!m_axil_awvalid[t]||{m_axil_awaddr[t*AW+:AW],m_axil_awprot[t*3+:3]}!==pa[t]))$fatal(1,"AW hold");
if(hw[t]&&(!m_axil_wvalid[t]||{m_axil_wdata[t*DW+:DW],m_axil_wstrb[t*SW+:SW]}!==pw[t]))$fatal(1,"W hold");
if(har[t]&&(!m_axil_arvalid[t]||{m_axil_araddr[t*AW+:AW],m_axil_arprot[t*3+:3]}!==par[t]))$fatal(1,"AR hold");
ha[t]=m_axil_awvalid[t]&&!m_axil_awready[t];pa[t]={m_axil_awaddr[t*AW+:AW],m_axil_awprot[t*3+:3]};hw[t]=m_axil_wvalid[t]&&!m_axil_wready[t];pw[t]={m_axil_wdata[t*DW+:DW],m_axil_wstrb[t*SW+:SW]};har[t]=m_axil_arvalid[t]&&!m_axil_arready[t];par[t]={m_axil_araddr[t*AW+:AW],m_axil_arprot[t*3+:3]};
if(dut.tw_busy[t]||dut.tr_busy[t])active_targets=active_targets+1;
if(m_axil_awvalid[t]&&m_axil_awready[t])begin if(taw[t])$fatal(1,"target AW duplicate");taw[t]=1;ta[t]=m_axil_awaddr[t*AW+:AW];tp[t]=m_axil_awprot[t*3+:3];end
if(m_axil_wvalid[t]&&m_axil_wready[t])begin if(tww[t])$fatal(1,"target W duplicate");tww[t]=1;td[t]=m_axil_wdata[t*DW+:DW];ts[t]=m_axil_wstrb[t*SW+:SW];end
if(m_axil_bvalid[t]&&m_axil_bready[t])begin m_axil_bvalid[t]<=0;taw[t]=0;tww[t]=0;bt[t]=0;dispatchw=dispatchw+1;end
else if(taw[t]&&tww[t]&&!m_axil_bvalid[t])begin
k=(ta[t]>>8)&3;
if(ta[t]>>12||k>=M||td[t]!==payload(k,(ta[t]>>2)&63)||ts[t]!==strobe(k,(ta[t]>>2)&63)||tp[t]!==((((ta[t]>>2)&63)+k)&7))$fatal(1,"AW/W owner mismatch");
if(bt[t]==3)begin m_axil_bvalid[t]<=1;m_axil_bresp[t*2+:2]<=ta[t][4]?2:0;end else bt[t]=bt[t]+1;
end
if(m_axil_arvalid[t]&&m_axil_arready[t])begin if(tar[t])$fatal(1,"target AR duplicate");tar[t]=1;ra[t]=m_axil_araddr[t*AW+:AW];rp[t]=m_axil_arprot[t*3+:3];end
if(m_axil_rvalid[t]&&m_axil_rready[t])begin m_axil_rvalid[t]<=0;tar[t]=0;rt[t]=0;dispatchr=dispatchr+1;end
else if(tar[t]&&!m_axil_rvalid[t])begin
if(rt[t]==2)begin m_axil_rvalid[t]<=1;m_axil_rdata[t*DW+:DW]<=read_value(t,ra[t],rp[t]);m_axil_rresp[t*2+:2]<=ra[t][5]?2:0;end else rt[t]=rt[t]+1;
end
end
if(active_targets>1)parallel=parallel+1;
if(completed==M*N*2)begin
if(offresponse==0)$fatal(1,"no CEoff response");if(M>1&&T>1&&parallel==0)$fatal(1,"no target concurrency");
$display("PASS AXIL M=%0d T=%0d DW=%0d transactions=%0d dispatchedw=%0d dispatchedr=%0d CEoffresponses=%0d parallelcycles=%0d",M,T,DW,completed,dispatchw,dispatchr,offresponse,parallel);$finish;
end
end
initial begin
for(m=0;m<M;m=m+1)begin wi[m]=0;ri[m]=0;aws[m]=0;ws[m]=0;ars[m]=0;awo[m]=0;wof[m]=0;aro[m]=0;hb[m]=0;hr[m]=0;end
for(t=0;t<T;t=t+1)begin taw[t]=0;tww[t]=0;tar[t]=0;bt[t]=0;rt[t]=0;ha[t]=0;hw[t]=0;har[t]=0;end
repeat(4)@(negedge clk);rst_n=1;
end endmodule'''
def run(m,t,dw,n=48):
 tb=TB
 for key,value in dict(M=m,T=t,DW=dw,N=n).items():tb=tb.replace('@'+key+'@',str(value))
 name=f'{m}x{t}_{dw}'
 with tempfile.TemporaryDirectory(prefix='axil_multi_test_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/(name+'_compile.log'))
  out=execute(['vvp',d/'sim'],d,HERE/(name+'_simulation.log'),timeout=180);assert 'PASS AXIL' in out;print(out,flush=True)
 return dict(masters=m,targets=t,data_width=dw,transactions=m*n*2,output=out)
def main():
 sha=hashlib.sha256(RTL.read_bytes()).hexdigest();rows=[run(*v) for v in [(2,4,32),(4,8,64),(3,3,32),(1,1,32),(1,8,64),(4,1,64)]]
 assert sha==hashlib.sha256(RTL.read_bytes()).hexdigest()
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=sha,cases=rows,scope='Independent concurrent initiator response scoreboard, target AW/W association and WSTRB/PROT checks, target stalls, all AXI held channels, CEoff response progress and multi-target concurrency.'),indent=2)+'\n')
if __name__=='__main__':main()
