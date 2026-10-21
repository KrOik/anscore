"""Isolated Gowin mapping through repository tooling; temporary work is removed."""
import hashlib,json,pathlib,re,sys,tempfile
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
def main():
    script=f'read_verilog "{(HERE/"img_block_motion.v").as_posix()}"; chparam -set WIDTH 9 -set HEIGHT 7 -set BITS 8 -set BLOCK_W 4 -set BLOCK_H 3 -set SEARCH_RANGE 2 img_block_motion; synth_gowin -top img_block_motion -noalu -nolutram; stat'
    with tempfile.TemporaryDirectory(prefix='motion_synth_') as tmp:
        p=pathlib.Path(tmp);text=execute(['yosys','-Q','-T','-p',script],p,p/'synthesis.log',timeout=120)
    (HERE/'synthesis.log').write_text(text)
    assert 'Found and reported 0 problems.' in text
    last=text.rsplit('=== img_block_motion ===',1)[1]
    cells={name:int(count) for count,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',last,re.M)}
    result={'status':'PASS','width':9,'height':7,'bits':8,'block_w':4,'block_h':3,'search_range':2,'cells':cells,
            'LUT1_to_LUT4':sum(cells.get('LUT'+str(n),0) for n in range(1,5)),
            'FF':sum(v for k,v in cells.items() if k.startswith('DFF')),
            'BRAM':sum(cells.get(n,0) for n in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9']),
            'DSP':sum(v for k,v in cells.items() if k.startswith(('MULT','ALU54','DSP'))),
            'rtl_sha256':hashlib.sha256((HERE/'img_block_motion.v').read_bytes()).hexdigest()}
    (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
