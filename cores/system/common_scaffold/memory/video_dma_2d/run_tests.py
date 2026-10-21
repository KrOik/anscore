import tempfile,subprocess,json,hashlib,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
RTL=HERE/'video_dma_2d_axi32.v'
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute as tool_execute
def execute(args,cwd):
 return tool_execute(args,cwd,Path(cwd)/'tool.log',timeout=180)
TB=r'''
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,abort=0,start_valid=0,cfg_write=0,done_ready=0;
reg [31:0] cfg_base,cfg_row_bytes,cfg_stride;reg [15:0] cfg_rows;
wire start_ready,done_valid;wire [7:0] error_code;wire [31:0] bytes_done;
reg [31:0] s_data;reg [3:0] s_keep;reg s_valid=0,s_eol,s_last;
wire s_ready;wire [31:0] m_data;wire [3:0] m_keep;wire m_valid,m_eol,m_last;reg m_ready=0;
wire [31:0] m_axi_awaddr,m_axi_araddr,m_axi_wdata;wire [7:0] m_axi_awlen,m_axi_arlen;
wire [2:0] m_axi_awsize,m_axi_arsize;wire [1:0] m_axi_awburst,m_axi_arburst;
wire m_axi_awvalid,m_axi_arvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready,m_axi_rready;
wire [3:0] m_axi_wstrb;
reg m_axi_awready=0,m_axi_arready=0,m_axi_wready=0,m_axi_bvalid=0,m_axi_rvalid=0,m_axi_rlast=0;
reg [1:0] m_axi_bresp=0,m_axi_rresp=0;reg [31:0] m_axi_rdata=0;
video_dma_2d_axi32 #(.MAX_BURST(BURST_VALUE)) dut(.*);
reg [7:0] ram[0:65535];integer wa,ra,wn,rn,wi,ri,cycle=0,j,k,n,tx,rx;
integer testid=0,abort_cycle=-1,inject_error=0,burst_count=0;
reg [31:0] seed=32'h76543210;
reg [63:0] held_aw,held_ar,held_w,held_m;
reg stall_aw=0,stall_ar=0,stall_w=0,stall_m=0;integer ceoff=0;
always @(negedge clk) begin
 seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
 ce=seed[0]|seed[1];m_ready=seed[2]|seed[3];
 m_axi_awready=seed[4];m_axi_arready=seed[5];m_axi_wready=seed[6];
 cycle=cycle+1;
 if(cycle>300000) $fatal(1,"timeout");
end
always @(posedge clk) if(rst_n) begin
 if(stall_aw&&(!m_axi_awvalid||{m_axi_awaddr,m_axi_awlen}!=held_aw))$fatal(1,"AW unstable");
 if(stall_ar&&(!m_axi_arvalid||{m_axi_araddr,m_axi_arlen}!=held_ar))$fatal(1,"AR unstable");
 if(stall_w&&(!m_axi_wvalid||{m_axi_wdata,m_axi_wstrb,m_axi_wlast}!=held_w))$fatal(1,"W unstable");
 if(stall_m&&(!m_valid||{m_data,m_keep,m_eol,m_last}!=held_m))$fatal(1,"stream unstable");
 stall_aw=m_axi_awvalid&&!m_axi_awready;held_aw={m_axi_awaddr,m_axi_awlen};
 stall_ar=m_axi_arvalid&&!m_axi_arready;held_ar={m_axi_araddr,m_axi_arlen};
 stall_w=m_axi_wvalid&&!m_axi_wready;held_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
 stall_m=m_valid&&!m_ready;held_m={m_data,m_keep,m_eol,m_last};
 if(!ce&&m_valid&&m_ready)ceoff=ceoff+1;
 if(m_axi_awvalid&&m_axi_awready) begin
  if(m_axi_awsize!=2||m_axi_awburst!=1||m_axi_awaddr[1:0]||m_axi_awaddr[11:0]+(m_axi_awlen+1)*4>4096) $fatal(1,"AW");
  wa=m_axi_awaddr;wn=m_axi_awlen+1;wi=0;burst_count=burst_count+1;
 end
 if(m_axi_wvalid&&m_axi_wready) begin
  if(m_axi_wlast!=(wi==wn-1)) $fatal(1,"WLAST");
  for(j=0;j<4;j=j+1) if(m_axi_wstrb[j]) ram[wa+wi*4+j]=m_axi_wdata[j*8+:8];
  $display("WRITE %0d %0d %08x %x",testid,wa+wi*4,m_axi_wdata,m_axi_wstrb);
  wi=wi+1;
  if(wi==wn) begin m_axi_bvalid<=1;m_axi_bresp<=inject_error==1?2:0;end
 end
 if(m_axi_bvalid&&m_axi_bready) m_axi_bvalid<=0;
 if(m_axi_arvalid&&m_axi_arready) begin
  if(m_axi_arsize!=2||m_axi_arburst!=1||m_axi_araddr[1:0]||m_axi_araddr[11:0]+(m_axi_arlen+1)*4>4096) $fatal(1,"AR");
  ra=m_axi_araddr;rn=m_axi_arlen+1;ri=0;burst_count=burst_count+1;
 end
 if(m_axi_rvalid&&m_axi_rready) begin ri=ri+1;m_axi_rvalid<=0;end
 if(!m_axi_rvalid&&ri<rn&&seed[7]) begin
  m_axi_rdata<={ram[ra+ri*4+3],ram[ra+ri*4+2],ram[ra+ri*4+1],ram[ra+ri*4]};
  // Broken marker only: slave still supplies exactly all ARLEN+1 promised beats.
  m_axi_rlast<=(ri==rn-1)^((inject_error==2&&ri==0)||(inject_error==3&&ri==rn-1));
  m_axi_rvalid<=1;m_axi_rresp<=inject_error==1?2:0;
  if((inject_error==2&&ri==0)||(inject_error==3&&ri==rn-1))$display("RFAULT %0d %0d %0d",testid,ri,rn);
 end
 if(s_valid&&s_ready) tx=tx+1;
 if(m_valid&&m_ready) begin $display("PIX %0d %08x %x %0d %0d",testid,m_data,m_keep,m_eol,m_last);rx=rx+1;end
end
task launch(input integer id,input integer write_mode,input integer base,input integer rb,input integer st,input integer rows,input integer err,input integer abort_at,input integer bad);
integer row,col,b,steps;begin
 @(negedge clk);testid=id;cfg_write=write_mode;cfg_base=base;cfg_row_bytes=rb;cfg_stride=st;cfg_rows=rows;
 inject_error=err;tx=0;rx=0;rn=0;ri=0;start_valid=1;
 do @(posedge clk);while(!start_ready);
 @(negedge clk);start_valid=0;steps=0;
 // Deliberately change live config after acceptance.
 cfg_base=32'hdead0001;cfg_row_bytes=0;cfg_stride=1;cfg_rows=0;
 while(!done_valid) begin
  if(write_mode&&!s_valid&&!abort) begin
   row=tx/((rb+3)/4);col=(tx%((rb+3)/4))*4;
   s_data=0;for(b=0;b<4;b=b+1) s_data[b*8+:8]=(id*17+row*13+col+b)&255;
   n=rb-col;if(n>4)n=4;s_keep=(1<<n)-1;s_eol=col+4>=rb;s_last=s_eol&&row==rows-1;
   if(bad==1) s_keep=0;
   if(bad==2) s_eol=!s_eol;
   if(bad==3) s_last=!s_last;
   s_valid=1;
  end
  if(steps==abort_at) abort=1;
  @(posedge clk);
  if(s_valid&&s_ready) begin @(negedge clk);s_valid=0;end
  else @(negedge clk);
  steps=steps+1;
 end
 $display("DONE %0d %0d %0d %0d %0d",id,error_code,bytes_done,tx,rx);
 repeat(3)begin @(posedge clk);if(!done_valid)$fatal(1,"DONE hold");@(negedge clk);end
 s_valid=0;abort=0;done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
end endtask
initial begin
 rn=0;ri=0;for(k=0;k<65536;k=k+1) ram[k]=(k*7+3)&255;
 repeat(4) @(negedge clk);rst_n=1;
 CASES
 for(k=0;k<65536;k=k+1) $display("MEM %0d %02x",k,ram[k]);
 if(ceoff==0)$fatal(1,"no CE-off output coverage");
 $display("PASS %0d %0d",burst_count,ceoff);$finish;
end
endmodule
'''
def main():
 profiles=[(4092,67,80,3),(8188,4097,4100,2),(128,1,4,3),(256,4,8,2),(512,63,64,4)]
 reports=[]
 for burst in (1,16,256):
  cases=[];expected={};expected_bytes={};memory=bytearray((i*7+3)&255 for i in range(65536));errors={};id=0
  for base,rb,st,rows in profiles:
   id+=1;cases.append(f'launch({id},1,{base},{rb},{st},{rows},0,-1,0);');errors[id]=0
   expected_bytes[id]=rb*rows
   for row in range(rows):
    for col in range(rb):memory[base+row*st+col]=(id*17+row*13+col)&255
   id+=1;cases.append(f'launch({id},0,{base},{rb},{st},{rows},0,-1,0);');errors[id]=0
   expected_bytes[id]=rb*rows
   expected[id]=[(int.from_bytes(memory[base+r*st+c:base+r*st+c+4],'little'),(1<<min(4,rb-c))-1,int(c+4>=rb),int(c+4>=rb and r==rows-1)) for r in range(rows) for c in range(0,rb,4)]
  # Abort reads and AXI read errors do not modify RAM; subsequent healthy reads prove recovery.
  special={}
  for mode,err,ab,bad,code in [(0,0,3,0,5),(0,0,12,0,5),(0,1,-1,0,4),(1,1,-1,1,3),(1,0,2,1,5),(1,0,12,0,5),(1,1,-1,0,4)]:
   id+=1;cases.append(f'launch({id},{mode},32000,65,80,2,{err},{ab},{bad});');errors[id]=code
   if mode:special[id]=(err,ab,bad)
  # Healthy command after error and abort sequences.
  id+=1;cases.append(f'launch({id},0,128,1,4,3,0,-1,0);');errors[id]=0
  expected[id]=[(int.from_bytes(memory[128+r*4:132+r*4],'little'),1,1,int(r==2)) for r in range(3)]
  injected_rlast=[];added_faults=[]
  for mode,err,bad,code in [(1,0,2,3),(1,0,3,3),(0,2,0,4),(0,3,0,4)]:
   id+=1;cases.append(f'launch({id},{mode},32000,65,80,2,{err},-1,{bad});');errors[id]=code
   added_faults.append(dict(command=id,write=mode,axi_error_mode=err,stream_error_mode=bad,expected_error=code))
   if mode:special[id]=(err,-1,bad)
   else:injected_rlast.append(id)
   # Each individual new error has its own healthy command, checking data and all markers.
   id+=1;cases.append(f'launch({id},0,128,1,4,3,0,-1,0);');errors[id]=0;expected_bytes[id]=3
   expected[id]=[(int.from_bytes(memory[128+r*4:132+r*4],'little'),1,1,int(r==2)) for r in range(3)]
  for base,rb,st,rows in [(1,4,4,1),(0,0,4,1),(0,4,4,0),(0,9,8,1),(4294967292,8,8,1),(0,4,5,1),(0,131072,131072,65535)]:
   id+=1;cases.append(f'launch({id},0,{base},{rb},{st},{rows},0,-1,0);');errors[id]=2
  with tempfile.TemporaryDirectory(prefix='video_dma_2d_') as tmp:
   d=Path(tmp);tb=d/'tb.sv';tb.write_text(TB.replace('BURST_VALUE',str(burst)).replace('CASES','\n'.join(cases)))
   execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,tb],d)
   out=execute(['vvp',d/'sim'],d)
  pix={};done={};actual=bytearray(65536);rlast_faults=set()
  for line in out.splitlines():
   v=line.split()
   if v[0]=='PIX':pix.setdefault(int(v[1]),[]).append((int(v[2],16),int(v[3],16),int(v[4]),int(v[5])))
   elif v[0]=='DONE':done[int(v[1])]=list(map(int,v[2:]))
   elif v[0]=='MEM':actual[int(v[1])]=int(v[2],16)
   elif v[0]=='RFAULT':rlast_faults.add(int(v[1]))
   elif v[0]=='WRITE' and int(v[1]) in special:
    tid,addr,data,mask=int(v[1]),int(v[2]),int(v[3],16),int(v[4],16)
    assert 32000<=addr<32148,(tid,'write outside frame')
    row,col=divmod(addr-32000,80)
    for b in range(4):
     if mask>>b&1:
      assert col+b<65 and (data>>(8*b))&255==(tid*17+row*13+col+b)&255
      memory[addr+b]=(data>>(8*b))&255
  for i,e in errors.items():assert done[i][0]==e,(burst,i,done[i],e)
  for i,e in expected_bytes.items():assert done[i][1]==e,(burst,i,'byte accounting',done[i],e)
  for i,e in expected.items():assert pix[i]==e,(burst,i,'pixels')
  assert rlast_faults==set(injected_rlast),(burst,'RLAST fault coverage')
  assert actual==memory,(burst,'RAM/stride hole mismatch')
  reports.append(dict(max_burst=burst,commands=len(cases),healthy_read_pixels=sum(map(len,expected.values())),additional_faults_with_individual_recovery=added_faults,status='PASS'))
  print(reports[-1],flush=True)
 for burst in (0,257):
  with tempfile.TemporaryDirectory(prefix='video_dma_2d_static_') as tmp:
   d=Path(tmp);tb=d/'tb.sv'
   body=TB.replace('BURST_VALUE',str(burst)).replace('CASES','launch(1,0,0,4,4,1,0,-1,0);').replace('if(ceoff==0)$fatal(1,"no CE-off output coverage");','')
   tb.write_text(body);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,tb],d)
   out=execute(['vvp',d/'sim'],d);assert 'DONE 1 2 0 0 0' in out
  reports.append(dict(max_burst=burst,status='PASS rejected static parameter'))
 result=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=reports)
 (HERE/'test_results.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()



