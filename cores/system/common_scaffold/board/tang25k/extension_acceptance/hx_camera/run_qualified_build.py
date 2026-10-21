"""Retry on existing qualified OSS runtime; preserve failed baseline build."""
from pathlib import Path
import sys,shutil,json,hashlib,tempfile
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H));import run_build as base
P=base.P;ROOT=base.ROOT
sys.path.insert(0,str(P/'board/tang25k'));import resume_candidate_route_official as route
from tooling import execute

def main():
 d=H/'build_nolutram';d.mkdir(exist_ok=False);sources=base.SOURCE
 original={str(p.relative_to(ROOT)).replace('\\','/'):base.sha(p) for p in sources}
 for p in sources:shutil.copy2(p,d/p.name);assert base.sha(d/p.name)==base.sha(p)
 shutil.copy2(H/'expected_uart.txt',d/'expected_uart.txt');base.device_flow.write_cst(d)
 case=dict(top='hx_camera_acceptance',sources=[p.name for p in sources],scope='Digital pin-loopback FPGA output consistency only; no external peripherals')
 (d/'case.json').write_text(json.dumps(case,indent=2)+'\n',encoding='utf-8')
 inputs={n:base.sha(d/n) for n in [*[p.name for p in sources],'expected_uart.txt','tang25k.cst','case.json']}
 (d/'build_input_sha256.json').write_text(json.dumps(dict(production_sources=original,build_sources=inputs,runner_sha256=base.sha(Path(__file__)),testbench_sha256=base.sha(H/'tb_hx_camera_acceptance.sv')),indent=2)+'\n',encoding='utf-8')
 with tempfile.TemporaryDirectory(prefix='hx_camera_qualified_sim_') as tmp:
  w=Path(tmp);execute(['iverilog','-g2012','-s','tb','-o',w/'sim',*[d/p.name for p in sources],H/'tb_hx_camera_acceptance.sv'],w,d/'simulation_compile.log');out=execute(['vvp',w/'sim'],w,d/'simulation.log');assert 'PASS UART_DECODE HX_CAMERA' in out
 (d/'build_status.json').write_text(json.dumps(dict(status='SIMULATION_PASS',simulation='PASS',source_sha256=inputs),indent=2)+'\n',encoding='utf-8')
 ys='read_verilog -sv -I. '+' '.join(case['sources'])+'\n';lib=base.device_flow.cells_xtra_lib()
 if lib:ys+='read_verilog -lib '+str(lib).replace('\\','/')+'\n'
 ys+='synth_gowin -noalu -nolutram -family gw5a -top hx_camera_acceptance -json top25k.json\ncheck\nstat\n'
 (d/'build_nolutram.ys').write_text(ys,encoding='utf-8');base.device_flow.run(d,['yosys','-s','build_nolutram.ys'],'synthesis_25k.log',timeout=900)
 rc=route.run_attempt(d,'hxcam_v1',ROOT/'scratch/bram_timing_db_20261017/GW5A-25A_patched.bin',seed=3,route_only=False)
 for n,v in inputs.items():assert base.sha(d/n)==v,n
 assert original=={str(p.relative_to(ROOT)).replace('\\','/'):base.sha(p) for p in sources}
 (d/'post_build_source_check.json').write_text(json.dumps(dict(status='PASS',production_sources=original,build_sources=inputs,route_returncode=rc),indent=2)+'\n',encoding='utf-8')
 print('FINISH',rc,d)
if __name__=='__main__':main()
