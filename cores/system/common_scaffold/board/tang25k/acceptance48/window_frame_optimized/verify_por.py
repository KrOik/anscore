from pathlib import Path
import tempfile,sys,json
HERE=Path(__file__).resolve().parent;sys.path.insert(0,str(HERE.parent));from make_case import execute
for name,version in [('window',2),('frame_difference',2),('frame_difference',5),('sobel',9)]:
 case=HERE/(name+'_v'+str(version));info=json.loads((case/'case.json').read_text());text=(case/'verification/normal_tb.v').read_text()
 check="""always @(negedge clk) if($time>20 && !uut.rst_n) begin
 if((^{uut.ci,uut.ii,uut.ai,uut.ki,uut.ei,uut.ce,uut.cv,uut.rr,uut.sv,uut.av,uut.kv,uut.mr,uut.tag,uut.errors,uut.digest,uut.timed_out,uut.finished,uut.uart_tx})===1'bx)$fatal(1,"POR harness output unknown");
 if(uut.cv || uut.sv || uut.av || uut.kv || uut.rr || uut.finished || uut.errors || uut.timed_out || !uut.uart_tx)$fatal(1,"POR output value");
end
"""
 with tempfile.TemporaryDirectory(prefix='a48_por_') as t:
  t=Path(t);tb=t/'por_tb.v';tb.write_text(text.replace('endmodule',check+'endmodule'));binary=t/'test.vvp'
  execute(['iverilog','-g2012','-s','acceptance48_tb','-o',binary,*[case/x for x in info['sources']],tb],case,HERE/(name+'_v'+str(version)+'_por_compile.log'))
  result=execute(['vvp',binary,'+golden='+str(case/'verification/normal_expected_uart.txt')],case,HERE/(name+'_v'+str(version)+'_por_simulation.log'))
  assert 'ACCEPTANCE48 UART GOLDEN PASS' in result
 print(name+' POR determinism and normal UART PASS')
