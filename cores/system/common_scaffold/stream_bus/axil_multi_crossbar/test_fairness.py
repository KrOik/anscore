from run_tests import HERE,RTL,TB,execute
from pathlib import Path
import tempfile,json,hashlib

def main():
 tb=TB.replace('@M@','4').replace('@T@','4').replace('@DW@','32').replace('@N@','16')
 tb=tb.replace('if(n<8)target=0;','if(1)target=0;').replace('ce=cyc%31>7;','ce=1;').replace('rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);',"rng=32'hffffffff;")
 tb=tb.replace('if(offresponse==0)', 'if(0)').replace('if(M>1&&T>1&&parallel==0)','if(0)')
 extra=r'''integer wg_count=0,rg_count=0;
 always @(posedge clk)if(rst_n)begin
 if(m_axil_awvalid[0]&&m_axil_awready[0])begin
 if(((m_axil_awaddr[7:0+16]>>8)&3)!==wg_count%4)$fatal(1,"write RR order");wg_count=wg_count+1;
 end
 if(m_axil_arvalid[0]&&m_axil_arready[0])begin
 if(((m_axil_araddr[15:0]>>8)&3)!==rg_count%4)$fatal(1,"read RR order");rg_count=rg_count+1;
 end
 end
'''.replace('m_axil_awaddr[7:0+16]','m_axil_awaddr[15:0]')
 tb=tb.replace('initial begin\nfor(m=0;',extra+'initial begin\nfor(m=0;')
 with tempfile.TemporaryDirectory(prefix='axil_multi_fair_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/'fair_compile.log')
  out=execute(['vvp',d/'sim'],d,HERE/'fair_simulation.log');assert 'PASS AXIL' in out;print(out)
 (HERE/'fairness_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),masters=4,targets=4,transactions=128,scope='All 4 continuously requesting initiators contend target0; exact repeated 0,1,2,3 read and write grants independently checked, bounded bypass <=3 grants under responsive targets and response consumers.',output=out),indent=2)+'\n')
if __name__=='__main__':main()
