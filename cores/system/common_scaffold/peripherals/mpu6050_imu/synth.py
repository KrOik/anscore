"""Isolated MPU6050 IMU plus shared physical engine synthesis."""
from test_transactions import *
import re

def main():
 frozen=hashes();dep=dependency();rows=[]
 for label,half,stretch,retry,startup in [('minimum',4,4,1,0),('default',68,270000,1024,2700000),('large',65536,1000000,2147483647,2147483647)]:
  with tempfile.TemporaryDirectory(prefix='mpu6050_imu_synth_') as tmp:
   p=Path(tmp);params=dict(HALF_PERIOD_CYCLES=half,STRETCH_TIMEOUT_CYCLES=stretch,MAX_READY_POLLS=retry,STARTUP_DELAY_CYCLES=startup)
   ys=f'read_verilog -sv {PHY.as_posix()} {SOURCE.as_posix()}\nchparam '+' '.join(f'-set {k} {v}' for k,v in params.items())+' mpu6050_imu\nsynth_gowin -top mpu6050_imu -nodsp\ncheck -assert\nstat\n'
   (p/'run.ys').write_text(ys,encoding='utf-8');out=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=120)
   log=HERE/('synthesis_'+label+'.log');log.write_text(out,encoding='utf-8');stat=out[out.rfind('=== mpu6050_imu ==='):]
   cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stat,re.M) if k not in ('wires','ports','cells','memories','processes')}
   lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0);dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=2*sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
   assert 0<lut<=15000 and dsp<=4 and bram<=46
   row=dict(module='mpu6050_imu',parameters=params,cells=cells,lut_class=lut,dsp=dsp,bram9=bram,log_filename=log.name,report_sha256=hashlib.sha256(log.read_bytes()).hexdigest());rows.append(row);print(json.dumps(row),flush=True)
 assert hashes()==frozen and dependency()==dep
 (HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
