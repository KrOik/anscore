from run_tests import *
import re
def main():
 rows=[]
 profiles=[('small',dict(CLOCK_HZ=1000000,HALF_PERIOD_CYCLES=4,STRETCH_TIMEOUT_CYCLES=20,WAIT_LOW_US=1,WAIT_MEDIUM_US=1,WAIT_HIGH_US=1,RETRY_GAP_US=1,READ_ATTEMPTS=1)),('default',{}),('maximum',dict(CLOCK_HZ=100000000,HALF_PERIOD_CYCLES=512,STRETCH_TIMEOUT_CYCLES=1000000,WAIT_LOW_US=1000000,WAIT_MEDIUM_US=1000000,WAIT_HIGH_US=1000000,RETRY_GAP_US=1000000,READ_ATTEMPTS=65535))]
 for name,params in profiles:
  with tempfile.TemporaryDirectory(prefix='sht3x_synthesis_') as td:
   p=Path(td);script=f'read_verilog -sv {(H/"sht3x_sensor.sv").as_posix()} {PHY.as_posix()}\n'
   if params:script+='chparam '+ ' '.join(f'-set {k} {v}' for k,v in params.items())+' sht3x_sensor\n'
   script+='synth_gowin -top sht3x_sensor -nodsp\ncheck -assert\nstat\n';(p/'run.ys').write_text(script,encoding='utf-8');log=H/f'synthesis_{name}.log';out=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,log,timeout=600)
   # Hierarchical top includes its PHY; collect the final design-hierarchy total.
   marker='=== design hierarchy ===';assert marker in out and 'Found and reported 0 problems.' in out
   stats=out[out.rfind(marker):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',stats,re.M)}
   dspcell=lambda k:'DSP' in k or 'MULT' in k or k in ('ALU54D','PADD9','PADD18')
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')) and not dspcell(k))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if dspcell(k));bram9=2*sum(v for k,v in cells.items() if k in ('SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'))
   assert cells and lut<=15000 and dsp<=4 and bram9<=46
   row=dict(module='sht3x_sensor',profile=name,parameters=params,cells=cells,lut_class=lut,dsp=dsp,bram9=bram9,log_filename=log.name,report_sha256=sha(log),status='PASS');rows.append(row);print(json.dumps(row),flush=True)
 save('synthesis.json',rows,'Complete controller plus reused synchronous physical I2C byte engine hierarchy; actual mapped primitive totals, synth_gowin -nodsp/check -assert; no route/board claim')
if __name__=='__main__':main()
