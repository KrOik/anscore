from pathlib import Path
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
text=(COMMON/'signal_video/rtl/cip_image_dehaze_scalar_frame.v').read_text()
old=' if(state==REQ)begin rgb_q<=rgb_mem[index];t_q<=t_mem[index];end\n if(state==SCAN_REQ)rgb_q<=rgb_mem[neighbor];'
new=''' if(state==REQ)t_q<=t_mem[index];
 if(state==REQ || state==SCAN_REQ)
  rgb_q<=rgb_mem[state==SCAN_REQ ? neighbor : index];'''
if old not in text:raise RuntimeError('baseline read-port pattern changed')
(HERE/'cip_image_dehaze_scalar_frame.v').write_text(text.replace(old,new))
