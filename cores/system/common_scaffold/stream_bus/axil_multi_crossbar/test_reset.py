from run_tests import HERE,RTL,TB,execute
from pathlib import Path
import tempfile,json,hashlib

def main():
 tb=TB[:TB.index('integer wi')].replace('@M@','2').replace('@T@','4').replace('@DW@','32').replace('@N@','1')
 tb+=r"""
 task tick;begin @(negedge clk);#1;end endtask
 task reset_all;begin
 rst_n=0;ce=0;tick;
 if(s_axil_bvalid||s_axil_rvalid||m_axil_awvalid||m_axil_wvalid||m_axil_arvalid)$fatal(1,"reset did not clear valids");
 s_axil_awvalid=0;s_axil_wvalid=0;s_axil_arvalid=0;m_axil_bvalid=0;m_axil_rvalid=0;m_axil_awready=0;m_axil_wready=0;m_axil_arready=0;
 rst_n=1;ce=1;tick;
 if(s_axil_awready!==2'b11||s_axil_wready!==2'b11||s_axil_arready!==2'b11||s_axil_bvalid||s_axil_rvalid)$fatal(1,"reset recovery");
 end endtask
 integer j;
 initial begin repeat(3)tick;reset_all;
 // independently accepted AW-only and W-only canceled by coordinated global reset.
 s_axil_awvalid=1;tick;s_axil_awvalid=0;reset_all;
 s_axil_wvalid=2;tick;s_axil_wvalid=0;reset_all;
 // Three valid target channels exposed under target backpressure.
 s_axil_awvalid=1;s_axil_wvalid=1;s_axil_arvalid=2;tick;s_axil_awvalid=0;s_axil_wvalid=0;s_axil_arvalid=0;
 while(!m_axil_awvalid||!m_axil_wvalid||!m_axil_arvalid)tick;
 reset_all;
 // Buffered upstream responses held; reset at CE0 clears both directions.
 s_axil_awvalid=1;s_axil_wvalid=1;s_axil_arvalid=1;tick;s_axil_awvalid=0;s_axil_wvalid=0;s_axil_arvalid=0;
 m_axil_awready=15;m_axil_wready=15;m_axil_arready=15;
 while(!m_axil_awvalid||!m_axil_arvalid)tick;tick;
 m_axil_bvalid=1;m_axil_rvalid=1;m_axil_rdata=32'h12345678;
 while(!m_axil_bready||!m_axil_rready)tick;tick;m_axil_bvalid=0;m_axil_rvalid=0;
 while(!s_axil_bvalid||!s_axil_rvalid)tick;
 reset_all;
 repeat(10)tick;if(s_axil_bvalid||s_axil_rvalid||m_axil_awvalid||m_axil_arvalid||m_axil_wvalid)$fatal(1,"phantom postreset");
 $display("PASS AXIL reset partial buffers / exposed target / held upstream / CE0 coordinated reset");$finish;end
 initial begin #100000;$fatal(1,"timeout");end
 endmodule
 """
 with tempfile.TemporaryDirectory(prefix='axil_multi_reset_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/'reset_compile.log')
  out=execute(['vvp',d/'sim'],d,HERE/'reset_simulation.log');assert 'PASS AXIL' in out;print(out)
 (HERE/'reset_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='Coordinated global synchronous reset (CE0), AW-only/W-only buffers, exposed target AW/W/AR, held master B/R and clean no-phantom recovery.',output=out),indent=2)+'\n')
if __name__=='__main__':main()
