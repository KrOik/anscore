import sys,json,re
from pathlib import Path
p=Path(sys.argv[1]);raw=p.read_bytes()
if p.suffix=='.json':
 d=json.loads(raw);raw=bytes.fromhex(d['runs'][-1]['uart_hex'])
match=re.search(rb'\r\nJDBG ([0-9A-F]{40})\r\n',raw)
if not match:raise SystemExit('No diagnostic packet found')
v=int(match[1],16);bus=v&((1<<128)-1);sc=bus>>64
flags=(sc>>16)&65535;dd=sc>>48;qd=(sc>>32)&65535
r=dict(prefix_bytes=match.start(),wrapper_state=(v>>145)&15,frame=(v>>144)&1,sent=(v>>136)&255,error=(v>>128)&255,
 frame_state=(bus>>19)&15,captured=(bus>>23)&131071,scan_error=(bus>>11)&255,raster_error=(bus>>10)&1,
 scan_start_ready=(bus>>9)&1,raster_source_ready=(bus>>8)&1,raster_output_valid=(bus>>7)&1,scan_pixel_ready=(bus>>6)&1,
 dct_state=(dd>>13)&7,dct_pass=(dd>>12)&1,dct_count=(dd>>6)&63,dct_tap=(dd>>3)&7,dct_position=dd&7,
 quant_state=(qd>>12)&15,quant_configured=(qd>>11)&1,quant_count=(qd>>5)&63,quant_bit_count=qd&31,
 scan_flags={k:(flags>>(15-i))&1 for i,k in enumerate(['configured','failed','block_enabled','next_restart','busy','dready','dvalid','qready','qvalid','coeff_ready','token_valid','token_ready','hvalid','hready','scan_start_ready','predictor_reset'])},
 pixel_index=(sc>>6)&63,coefficient_index=sc&63,raster_state_raw=(bus>>40)&16777215)
print(json.dumps(r,indent=2))
