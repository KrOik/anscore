from pathlib import Path
import json,hashlib,sys,shutil,tempfile,datetime
from test_wrapper import HERE,PACKAGE,SOURCES,execute,TB,hashes
NAMES=['ds3231','ads1115','sht3x']
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 for sensor,name in enumerate(NAMES):
  dest=HERE/'cases'/name;dest.mkdir(parents=True,exist_ok=False);top='sensor_'+name+'_top';upstream=hashes()
  for source in SOURCES:
   shutil.copy2(source,dest/source.name);assert h(dest/source.name)==h(source)
  wrap=f'''module {top} #(parameter CLK_HZ=50000000,BAUD=115200,CORRUPT=0)(input wire clk,uart_rx_pin,output wire uart_tx,dbg_uart);
sensor_i2c_top #(.SENSOR({sensor}),.CORRUPT(CORRUPT),.CLK_HZ(CLK_HZ),.BAUD(BAUD))inner(.*);
endmodule
'''
  (dest/(top+'.sv')).write_text(wrap,encoding='utf-8');shutil.copy2(HERE/'tang25k.cst',dest/'tang25k.cst')
  expected=f'PASS {name.upper()} PINLOOP\r\n';(dest/'expected_uart.txt').write_bytes(expected.encode('ascii'))
  rtl=[source.name for source in SOURCES]+[top+'.sv'];(dest/'case.json').write_text(json.dumps(dict(top=top,sources=rtl,name=name,scope='internal scripted sensor pin-loop acceptance only; not a physical sensor'),indent=2)+'\n',encoding='utf-8')
  frozen={n:h(dest/n) for n in rtl+['case.json','tang25k.cst','expected_uart.txt']};rows=[]
  for corrupt in [0,1]:
   token=expected if not corrupt else expected.replace('PASS','FAIL')
   tb=TB.replace('sensor_i2c_top #(.SENSOR(@SENSOR@),.CORRUPT(@CORRUPT@)',top+' #(.CORRUPT(@CORRUPT@)').replace('@CORRUPT@',str(corrupt)).replace('@LENGTH@',str(len(token))).replace('@PASS@',str(1-corrupt))
   with tempfile.TemporaryDirectory(prefix='sensor_i2c_stage_') as temp:
    t=Path(temp);(t/'tb.sv').write_text(tb,encoding='utf-8');execute(['iverilog','-g2012','-s','tb','-o',t/'sim',*[dest/n for n in rtl],t/'tb.sv'],t,t/'compile.log');out=execute(['vvp',t/'sim'],t,t/'run.log',timeout=60)
   norm=out.replace('\r\n','\n').replace('\r','');assert 'UART '+token.replace('\r','')+'END_UART\n' in norm,out
   log=dest/f'simulation_{corrupt}.log';log.write_text(out,encoding='utf-8');rows.append(dict(corrupt=corrupt,expected_uart=token,log=log.name,sha256=h(log)))
  assert frozen=={n:h(dest/n) for n in frozen} and upstream==hashes()
  provenance=dict(upstream_sources=upstream,staged_sources=frozen,stage_to_upstream={source.name:source.relative_to(PACKAGE).as_posix() for source in SOURCES},simulation_profiles=rows,scope='Internal synthesizable scripted sensor loopback; no JTAG/UART hardware operation performed')
  (dest/'build_input_sha256.json').write_text(json.dumps(provenance,indent=2)+'\n',encoding='utf-8')
  (dest/'build_status.json').write_text(json.dumps(dict(simulation='PASS',source_sha256=frozen,simulation_profiles=rows,upstream_source_sha256=upstream),indent=2)+'\n',encoding='utf-8');print('STAGED',name,h(dest/'build_input_sha256.json'),flush=True)
if __name__=='__main__':main()
