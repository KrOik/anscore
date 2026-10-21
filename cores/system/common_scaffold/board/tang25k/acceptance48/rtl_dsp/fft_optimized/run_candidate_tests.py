from pathlib import Path
import sys,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[4];SV=COMMON/'signal_video';DSP=COMMON/'dsp'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV));sys.path.insert(0,str(DSP))
from tooling import execute
from fft_reference import fixtures as core_fixtures
from fft_adapter_reference import fixtures as adapter_fixtures

def main():
 results=[]
 with tempfile.TemporaryDirectory(prefix='fft_candidate_') as temporary:
  t=Path(temporary)
  for log_n,data_w in [(1,8),*[(n,16) for n in range(2,9)]]:
   label=f'core_n{1<<log_n}_w{data_w}';f=t/label;f.mkdir();counts=core_fixtures(f,log_n,data_w);binary=f/'sim.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_dsp_fft',f'-Ptb_cip_dsp_fft.LOG_N={log_n}',f'-Ptb_cip_dsp_fft.DATA_W={data_w}','-o',binary,HERE/'cip_dsp_fft.v',DSP/'rtl/cip_dsp_fft_twiddle.v',DSP/'sim/tb_cip_dsp_fft.v'],HERE,HERE/(label+'_compile.log'))
   result=execute(['vvp',binary,f'+folder={f}'],HERE,HERE/(label+'_simulation.log'));assert 'PASS FFT' in result and f"outputs={counts['outputs']}" in result;print(result.strip(),flush=True);results.append({'kind':'core',**counts})
  for log_n in range(1,9):
   label=f'adapter_n{1<<log_n}';f=t/label;f.mkdir();counts=adapter_fixtures(f,log_n);binary=f/'sim.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_fft_stream',f'-Ptb_cip_fft_stream.LOG_N={log_n}','-o',binary,HERE/'cip_dsp_fft.v',DSP/'rtl/cip_dsp_fft_twiddle.v',SV/'rtl/cip_fft_stream.v',SV/'sim/tb_cip_fft_stream.v'],HERE,HERE/(label+'_compile.log'))
   result=execute(['vvp',binary,f'+folder={f}'],HERE,HERE/(label+'_simulation.log'));assert 'FFT_ADAPTER PASS' in result and f"words={counts['words']} packets=10 responses=43 stalls=1111" in result;print(result.strip(),flush=True);results.append({'kind':'adapter',**counts})
 (HERE/'regression_summary.json').write_text(json.dumps({'status':'PASS','cases':results,'candidate_sha256':hashlib.sha256((HERE/'cip_dsp_fft.v').read_bytes()).hexdigest()},indent=2)+'\n')
if __name__=='__main__':main()
