"""Independent five-channel burst peer, generated from byte-address oracle."""
from pathlib import Path
import sys,json,hashlib,tempfile,importlib.util
from address_oracle import transaction
HERE=Path(__file__).resolve().parent
OWNER=HERE.parent/'axi_multi_crossbar'
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute

def build(dw, contention=False, bad=False, tx_override=None, region=8, masters=2, rounds=1, strict_rr=False):
 spec=importlib.util.spec_from_file_location('axi_owner_port_schema',OWNER/'port_schema.py')
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 schema=module.PORT_SCHEMA;decl=[]
 for side,count in [('s','MASTERS'),('m','TARGETS')]:
  for name,(width,direction) in schema.items():
   driven=(side=='s' and direction=='f')or(side=='m' and direction=='b')
   decl.append(f'{"reg" if driven else "wire"} [{count}*({width})-1:0] {side}_axi_{name}'+('=0;' if driven else ';'))
 # Independent directed transaction tuples: m,address,LEN,SIZE,BURST,LOCK.
 # Both write/read directions contend or run on separate targets concurrently.
 tx=[(0,0x18,3,2,2,0),(1,0x103,2,1,1,0)]
 if contention:tx=[(0,0xff,0,2,1,0),(1,0xf8,3,1,0,0)]
 if tx_override is not None:tx=tx_override
 text=TEMPLATE.replace('@MASTERS@',str(masters)).replace('@ROUNDS@',str(rounds)).replace('@RR@',str(int(strict_rr))).replace('@REGION@',str(region)).replace('@DECL@','\n'.join(decl)).replace('@DW@',str(dw)).replace('@BAD@',str(int(bad)))
 plans=[];init=[];calls=[]
 for m,a,l,z,b,k in tx:
  v=transaction(a,l,z,b,data_bits=dw,targets=2,region_bits=region,ident=m+1,lock=k)
  plans.append(dict(master=m,address=a,len=l,size=z,burst=b,lock=k,accepted=v.accepted,reason=v.reason))
  init.append(f'e_addr[{m}]=32\'h{a:08x};e_len[{m}]={l};e_size[{m}]={z};e_burst[{m}]={b};e_lock[{m}]={k};e_ok[{m}]={int(v.accepted)};')
  for index,beat in enumerate(v.beats):init.append(f'e_strb[{m}][{index}]={sum(1<<lane for lane in beat.lanes)};')
  calls.extend([f'write_master({m});',f'read_master({m});'])
 text=text.replace('@EXPECTED@',str(rounds*sum(int(p['accepted']) for p in plans))).replace('@INIT@','\n'.join(init)).replace('@CALLS@','\n'.join(calls))
 return text,plans

TEMPLATE=r'''
`timescale 1ns/1ps
module tb;
localparam MASTERS=@MASTERS@,TARGETS=2,ADDR_WIDTH=32,DATA_WIDTH=@DW@,ID_WIDTH=4,REGION_ADDR_BITS=@REGION@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1;wire protocol_error;
@DECL@
axi_multi_crossbar #(.MASTERS(MASTERS),.DATA_WIDTH(DATA_WIDTH),.REGION_ADDR_BITS(REGION_ADDR_BITS)) dut(.*);
integer cycle=0,t,m,i;
reg[31:0]e_addr[0:MASTERS-1];integer e_len[0:MASTERS-1],e_size[0:MASTERS-1],e_burst[0:MASTERS-1],e_lock[0:MASTERS-1],e_ok[0:MASTERS-1];
reg[DATA_WIDTH/8-1:0]e_strb[0:MASTERS-1][0:255];
integer wowner[0:1],rowner[0:1],windex[0:1],rindex[0:1],awseen=0,arseen=0,wseen=0,rseen=0,bseen=0;
reg[1:0]wa=0,ra=0;
function[DATA_WIDTH-1:0]word;input integer master,index,rd;begin word=(rd?32'h20000000:32'h10000000)+master*65536+index;end endfunction
always @*begin
 m_axi_awready=0;m_axi_arready=0;m_axi_wready=0;
 for(integer x=0;x<2;x=x+1)begin
  m_axi_awready[x]=!wa[x]&&!m_axi_bvalid[x]&&(cycle%4!=1);
  m_axi_arready[x]=!ra[x]&&!m_axi_rvalid[x]&&(cycle%3!=1);
  m_axi_wready[x]=wa[x]&&(cycle%5!=2);
 end
end
always @(posedge clk)begin
 if(rst_n)begin
  cycle<=cycle+1;
  for(integer x=0;x<2;x=x+1)begin
   if(m_axi_awvalid[x]&&m_axi_awready[x])begin
    m=m_axi_awid[x*4+:4]-1;
    if(m<0||m>=MASTERS||!e_ok[m]||(e_addr[m]>>REGION_ADDR_BITS)!=x||m_axi_awaddr[x*32+:32]!=(e_addr[m]&((1<<REGION_ADDR_BITS)-1))||m_axi_awlen[x*8+:8]!=e_len[m]||m_axi_awsize[x*3+:3]!=e_size[m]||m_axi_awburst[x*2+:2]!=e_burst[m])$fatal(1,"target AW decode/metadata");
    if(@RR@)$display("GRANT AW target%0d master%0d sequence%0d",x,m,awseen);
    if(@RR@&&m!=awseen%MASTERS)$fatal(1,"AW RR order master%0d grant%0d",m,awseen);
    wowner[x]<=m;windex[x]<=0;wa[x]<=1;awseen=awseen+1;
   end
   if(m_axi_wvalid[x]&&m_axi_wready[x])begin
    m=wowner[x];i=windex[x];
    if(m_axi_wdata[x*DATA_WIDTH+:DATA_WIDTH]!==word(m,i,0)||m_axi_wstrb[x*(DATA_WIDTH/8)+:DATA_WIDTH/8]!==e_strb[m][i]||m_axi_wlast[x]!=(i==e_len[m]))$fatal(1,"target W data/strb/LAST m%0d beat%0d",m,i);
    wseen=wseen+1;
    if(i==e_len[m])begin
     wa[x]<=0;m_axi_bvalid[x]<=1;m_axi_bresp[x*2+:2]<=0;m_axi_bid[x*4+:4]<=@BAD@?15:m+1;
    end else windex[x]<=i+1;
   end
   if(m_axi_bvalid[x]&&m_axi_bready[x])begin m_axi_bvalid[x]<=0;bseen=bseen+1;end
   if(m_axi_arvalid[x]&&m_axi_arready[x])begin
    m=m_axi_arid[x*4+:4]-1;
    if(m<0||m>=MASTERS||!e_ok[m]||(e_addr[m]>>REGION_ADDR_BITS)!=x||m_axi_araddr[x*32+:32]!=(e_addr[m]&((1<<REGION_ADDR_BITS)-1))||m_axi_arlen[x*8+:8]!=e_len[m]||m_axi_arsize[x*3+:3]!=e_size[m]||m_axi_arburst[x*2+:2]!=e_burst[m])$fatal(1,"target AR decode/metadata");
    if(@RR@)$display("GRANT AR target%0d master%0d sequence%0d",x,m,arseen);
    if(@RR@&&m!=arseen%MASTERS)$fatal(1,"AR RR order master%0d grant%0d",m,arseen);
    rowner[x]<=m;rindex[x]<=0;ra[x]<=1;arseen=arseen+1;
   end
   if(m_axi_rvalid[x]&&m_axi_rready[x])begin
    rseen=rseen+1;m_axi_rvalid[x]<=0;
    if(rindex[x]==e_len[rowner[x]])ra[x]<=0;else rindex[x]<=rindex[x]+1;
   end
   if(ra[x]&&!m_axi_rvalid[x]&&cycle%4!=0)begin
    m=rowner[x];i=rindex[x];m_axi_rvalid[x]<=1;m_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH]<=word(m,i,1);
    m_axi_rid[x*4+:4]<=@BAD@?15:m+1;m_axi_rresp[x*2+:2]<=0;m_axi_rlast[x]<=@BAD@?(i==0):(i==e_len[m]);
   end
  end
 end
end
always @(negedge clk)if(rst_n)begin
 for(integer x=0;x<MASTERS;x=x+1)begin s_axi_bready[x]=(cycle+x)%7>2;s_axi_rready[x]=(cycle+x)%5>2;end
end
// Every VALID channel must retain its full payload under arbitrary backpressure.
reg [MASTERS*(DATA_WIDTH+7)-1:0]old_r;reg[MASTERS-1:0]holdr=0,holdb=0;reg[MASTERS*6-1:0]old_b;
always @(posedge clk)if(rst_n)begin
 for(integer x=0;x<MASTERS;x=x+1)begin
  if(holdr[x]&&(!s_axi_rvalid[x]||{s_axi_rid[x*4+:4],s_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH],s_axi_rresp[x*2+:2],s_axi_rlast[x]}!==old_r[x*(DATA_WIDTH+7)+:DATA_WIDTH+7]))$fatal(1,"held upstream R changed");
  if(holdb[x]&&(!s_axi_bvalid[x]||{s_axi_bid[x*4+:4],s_axi_bresp[x*2+:2]}!==old_b[x*6+:6]))$fatal(1,"held upstream B changed");
  holdr[x]<=s_axi_rvalid[x]&&!s_axi_rready[x];holdb[x]<=s_axi_bvalid[x]&&!s_axi_bready[x];
  old_r[x*(DATA_WIDTH+7)+:DATA_WIDTH+7]<={s_axi_rid[x*4+:4],s_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH],s_axi_rresp[x*2+:2],s_axi_rlast[x]};
  old_b[x*6+:6]<={s_axi_bid[x*4+:4],s_axi_bresp[x*2+:2]};
 end
end

task automatic write_master;input integer x;integer beat;begin
 @(negedge clk);s_axi_awid[x*4+:4]=x+1;s_axi_awaddr[x*32+:32]=e_addr[x];s_axi_awlen[x*8+:8]=e_len[x];s_axi_awsize[x*3+:3]=e_size[x];s_axi_awburst[x*2+:2]=e_burst[x];s_axi_awlock[x]=e_lock[x];s_axi_awvalid[x]=1;
 // W is presented before AW completes; cannot be consumed for a different owner.
 s_axi_wvalid[x]=1;s_axi_wdata[x*DATA_WIDTH+:DATA_WIDTH]=word(x,0,0);s_axi_wstrb[x*(DATA_WIDTH/8)+:DATA_WIDTH/8]=e_strb[x][0];s_axi_wlast[x]=@BAD@?1:e_len[x]==0;
 @(posedge clk);while(!s_axi_awready[x])@(posedge clk);
 @(negedge clk);s_axi_awvalid[x]=0;
 for(beat=0;beat<=e_len[x];beat=beat+1)begin
  if(beat!=0)begin @(negedge clk);s_axi_wvalid[x]=1;s_axi_wdata[x*DATA_WIDTH+:DATA_WIDTH]=word(x,beat,0);s_axi_wstrb[x*(DATA_WIDTH/8)+:DATA_WIDTH/8]=e_strb[x][beat];s_axi_wlast[x]=@BAD@?(beat==0):(beat==e_len[x]);end
  @(posedge clk);while(!s_axi_wready[x])@(posedge clk);
  @(negedge clk);s_axi_wvalid[x]=0;
 end
 @(posedge clk);while(!(s_axi_bvalid[x]&&s_axi_bready[x]))@(posedge clk);begin
  if(s_axi_bid[x*4+:4]!=x+1||s_axi_bresp[x*2+:2]!=(e_ok[x]?(@BAD@?2:0):3))$fatal(1,"master B ID/resp m%0d resp%0d",x,s_axi_bresp[x*2+:2]);
 end
end endtask

task automatic read_master;input integer x;integer beat;begin
 @(negedge clk);s_axi_arid[x*4+:4]=x+1;s_axi_araddr[x*32+:32]=e_addr[x];s_axi_arlen[x*8+:8]=e_len[x];s_axi_arsize[x*3+:3]=e_size[x];s_axi_arburst[x*2+:2]=e_burst[x];s_axi_arlock[x]=e_lock[x];s_axi_arvalid[x]=1;
 @(posedge clk);while(!s_axi_arready[x])@(posedge clk);
 @(negedge clk);s_axi_arvalid[x]=0;
 for(beat=0;beat<=e_len[x];beat=beat+1)begin
  @(posedge clk);while(!(s_axi_rvalid[x]&&s_axi_rready[x]))@(posedge clk);begin
   if(s_axi_rid[x*4+:4]!=x+1||s_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH]!== (e_ok[x]?word(x,beat,1):{DATA_WIDTH{1'b0}})||s_axi_rresp[x*2+:2]!=(e_ok[x]?0:3)||s_axi_rlast[x]!=(beat==e_len[x]))$fatal(1,"master R ID/data/resp/LAST m%0d beat%0d id%h data%h exp%h resp%h last%b ok%0d len%0d",x,beat,s_axi_rid[x*4+:4],s_axi_rdata[x*DATA_WIDTH+:DATA_WIDTH],word(x,beat,1),s_axi_rresp[x*2+:2],s_axi_rlast[x],e_ok[x],e_len[x]);
   
  end
 end
end endtask
initial begin
 @INIT@
 repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
 repeat(@ROUNDS@)begin
 ce=1;
 fork
 begin wait((&s_axi_awvalid)&&(&s_axi_arvalid));wait(s_axi_awvalid==0&&s_axi_arvalid==0);@(negedge clk);ce=0;end
 @CALLS@
 join
 end
 repeat(5)@(negedge clk);
 if(awseen!=@EXPECTED@||arseen!=@EXPECTED@||protocol_error!=@BAD@)$fatal(1,"counts or protocol_error");
 $display("PASS independent AXI five-channel DW=%0d AW=%0d AR=%0d W=%0d R=%0d",DATA_WIDTH,awseen,arseen,wseen,rseen);$finish;
end
initial begin #200000;$fatal(1,"five-channel watchdog");end
endmodule
'''

def main():
 freeze_path=OWNER/'source_freeze.json';freeze=json.loads(freeze_path.read_text(encoding="utf-8"));freeze_sha=hashlib.sha256(freeze_path.read_bytes()).hexdigest()
 for name,digest in freeze.items():assert hashlib.sha256((OWNER/name).read_bytes()).hexdigest()==digest,name
 source=OWNER/'axi_multi_crossbar.sv';before=hashlib.sha256(source.read_bytes()).hexdigest();rows=[]
 cases=[('parallel32',32,False,False,None,8),('parallel64',64,False,False,None,8),('contend32',32,True,False,None,8),('contend64',64,True,False,None,8),('protocol_corruption',32,False,True,None,8),
 ('reject_lock_reserved',32,False,False,[(0,0,3,2,1,1),(1,256,7,1,3,0)],8),
 ('region_boundary',32,False,False,[(0,255,1,0,1,0),(1,255,0,2,1,0)],8),
 ('page_boundary',64,False,False,[(0,4095,1,2,1,0),(1,4095,0,2,1,0)],12),
 ('reject_size_wrap',32,False,False,[(0,0,0,3,1,0),(1,3,3,2,2,0)],8),
 ('incr256_fixed16',64,False,False,[(0,0,255,3,1,0),(1,4096,15,3,0,0)],12),('rr4x8',64,False,False,[(m,16+m*8,3,1,1,0) for m in range(4)],8)]
 for label,dw,contend,bad,override,region in cases:
  tb,plans=build(dw,contend,bad,override,region,4 if label=='rr4x8' else 2,8 if label=='rr4x8' else 1,label=='rr4x8')
  with tempfile.TemporaryDirectory(prefix='axi_crossbar_peer_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(tb, encoding="utf-8")
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',source,p/'tb.sv'],p,p/'compile.log')
   output=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS independent AXI' in output
   (HERE/(label+'.log')).write_text(output, encoding="utf-8");print(output.strip(),flush=True)
   rows.append(dict(label=label,plans=plans,output=output))
 assert hashlib.sha256(source.read_bytes()).hexdigest()==before
 for name,digest in freeze.items():assert hashlib.sha256((OWNER/name).read_bytes()).hexdigest()==digest,name
 assert hashlib.sha256(freeze_path.read_bytes()).hexdigest()==freeze_sha
 (HERE/'five_channel_evidence.json').write_text(json.dumps(dict(status='PASS',source_freeze_sha256=freeze_sha,owner_frozen_inputs=freeze,rtl_sha256=before,peer_input_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.iterdir() if p.suffix in ('.py','.md') or p.name=='references.json'},profiles=rows,scope='Independent ideal five-channel RTL simulation against final frozen owner inputs; no board or electrical claim.'),indent=2)+'\n', encoding="utf-8")
if __name__=='__main__':main()


