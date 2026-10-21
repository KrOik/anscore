"""Independent numeric checks for exact frame-bounded histogram counts/clip."""
from pathlib import Path
import sys,tempfile,random,json
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3];SV=COMMON/'signal_video'
sys.path.insert(0,str(COMMON/'integration'));sys.path.insert(0,str(SV))
from tooling import execute
from run_clahe_tests import clahe
rng=random.Random(0xc18b);commands=[];inputs=[];outputs=[]
for w,h,tw,th in [(1,1,1,1),(8,6,3,4),(8,6,8,6)]:
 for clip in [47,48,49,64,16777215]:
  image=[127]*(w*h) if w==34 else [rng.randrange(256) for _ in range(w*h)]
  commands.extend([0,w,h,w,h,clip,th<<16|tw,0,0,len(image)]);inputs.extend(image)
  result=clahe(image,w,h,tw,th,clip)
  outputs.extend(v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(result))
sources=[HERE/'candidate_v8/cip_image_clahe.v',HERE/'candidate_v8/cip_image_clahe_frame.v',HERE/'tb_clahe_board_clip.v',*[COMMON/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]]
with tempfile.TemporaryDirectory(prefix='clahe_board_clip_bound_') as t:
 root=Path(t)
 for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
  (root/(name+'.hex')).write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
 for bits in [8,32]:
  binary=root/f'clip{bits}.vvp';compile_text=execute(['iverilog','-g2012','-s','tb_cip_image_clahe',f'-Ptb_cip_image_clahe.DW={bits}','-Ptb_cip_image_clahe.GB=8','-o',binary,*sources],HERE,HERE/f'board_clip_bound_w{bits}_compile.log')
  if compile_text.strip():raise RuntimeError(compile_text)
  output=execute(['vvp',binary,f'+folder={root}',f'+commands={len(commands)//10}',f'+pixels={len(inputs)}',f'+outputs={len(outputs)}'],HERE,HERE/f'board_clip_bound_w{bits}_simulation.log');print(output.strip())
  if f'CLAHE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
(HERE/'board_clip_bound_summary.json').write_text(json.dumps({'status':'PASS','commands_per_width':len(commands)//10,'outputs_per_width':len(outputs),'widths':[8,32],'clip_values':[47,48,49,64,16777215],'max_frame_pixels':48,'oracle':'unchanged run_clahe_tests.clahe'},indent=2)+'\n')
