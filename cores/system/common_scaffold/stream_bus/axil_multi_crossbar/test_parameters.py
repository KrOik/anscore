from run_tests import HERE,RTL,TB,execute
from pathlib import Path
import tempfile,json,hashlib

def one(name,aw=16,dw=32,rb=12,invalid=False,m=1,t=1):
 tb=TB[:TB.index('integer wi')].replace('@M@',str(m)).replace('@T@',str(t)).replace('@DW@',str(dw)).replace('@N@','1').replace('AW=16,RB=12',f'AW={aw},RB={rb}')
 tb+=r"""
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 repeat(3)tick;rst_n=1;
 if(INVALID)begin
 s_axil_awvalid=1;s_axil_wvalid=1;s_axil_arvalid=1;
 repeat(5)tick;
 if(s_axil_awready||s_axil_wready||s_axil_arready||m_axil_awvalid||m_axil_wvalid||m_axil_arvalid||s_axil_bvalid||s_axil_rvalid)$fatal(1,"invalid cfg not fail closed");
 end else begin
 // W before AW; accepted traffic must dispatch and complete with CE0.
 s_axil_wdata=64'hfedcba9876543210;s_axil_wstrb={SW{1'b1}};s_axil_wvalid=1;tick;s_axil_wvalid=0;
 repeat(3)tick;s_axil_awaddr=1;s_axil_awprot=5;s_axil_awvalid=1;tick;s_axil_awvalid=0;ce=0;
 while(!m_axil_awvalid||!m_axil_wvalid)tick;
 if(m_axil_awaddr!=1||m_axil_awprot!=5||m_axil_wdata!==DW'(64'hfedcba9876543210)||m_axil_wstrb!={SW{1'b1}})$fatal(1,"dispatch payload");
 m_axil_wready=1;tick;m_axil_wready=0;
 repeat(3)tick;if(!m_axil_awvalid||m_axil_wvalid)$fatal(1,"AW/W independent");m_axil_awready=1;tick;m_axil_awready=0;
 m_axil_bvalid=1;m_axil_bresp=2;while(!m_axil_bready)tick;tick;m_axil_bvalid=0;
 while(!s_axil_bvalid)tick;repeat(3)tick;if(s_axil_bresp!=2)$fatal(1,"B SLVERR");s_axil_bready=1;tick;s_axil_bready=0;
 // AR accepted separately, CE0 downstream and upstream response.
 ce=1;s_axil_araddr=0;s_axil_arprot=7;s_axil_arvalid=1;tick;s_axil_arvalid=0;ce=0;
 while(!m_axil_arvalid)tick;if(m_axil_araddr!=0||m_axil_arprot!=7)$fatal(1,"AR/prot");m_axil_arready=1;tick;m_axil_arready=0;
 m_axil_rdata=64'h81234567fedcba98;m_axil_rresp=2;m_axil_rvalid=1;while(!m_axil_rready)tick;tick;m_axil_rvalid=0;
 while(!s_axil_rvalid)tick;repeat(3)tick;if(s_axil_rdata!==DW'(64'h81234567fedcba98)||s_axil_rresp!=2)$fatal(1,"R payload");s_axil_rready=1;tick;s_axil_rready=0;
 end
 $display("PASS AXIL parameter profile");$finish;end
 initial begin #100000;$fatal(1,"timeout");end
 endmodule
 """.replace('INVALID',str(int(invalid)))
 with tempfile.TemporaryDirectory(prefix='axil_multi_parameter_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/(name+'_compile.log'))
  out=execute(['vvp',d/'sim'],d,HERE/(name+'_simulation.log'));assert 'PASS AXIL' in out
 return dict(name=name,addr_width=aw,data_width=dw,region_bits=rb,invalid=invalid,masters=m,targets=t)
def main():
 cases=[one('addr4_dw32',4,32,1),one('addr32_dw64',32,64,32),one('addr8_dw64',8,64,4)]
 for name,aw,dw,rb in [('aw3',3,32,1),('aw33',33,32,12),('dw16',16,16,12),('dw128',16,128,12),('region0',16,32,0),('region17',16,32,17)]:cases.append(one(name,aw,dw,rb,True))
 cases.extend([one('masters5',invalid=True,m=5),one('targets9',invalid=True,t=9)])
 (HERE/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=cases),indent=2)+'\n');print('PASS 3 legal + 8 invalid parameter profiles')
if __name__=='__main__':main()
