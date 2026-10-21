"""Isolated Gowin synthesis via repository tooling; no persistent netlist/binary."""
import hashlib,json,pathlib,re,sys,tempfile
HERE=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
def main():
    script=f'read_verilog "{(HERE/"img_stereo_lr_check.v").as_posix()}"; chparam -set WIDTH 17 -set HEIGHT 5 -set DISP_BITS 12 img_stereo_lr_check; synth_gowin -top img_stereo_lr_check -noalu -nolutram; stat'
    with tempfile.TemporaryDirectory(prefix='lr_synth_') as tmp:
        p=pathlib.Path(tmp)
        text=execute(['yosys','-Q','-T','-p',script],p,p/'synthesis.log',timeout=120)
    (HERE/'synthesis.log').write_text(text)
    assert 'Found and reported 0 problems.' in text
    last=text.rsplit('=== img_stereo_lr_check ===',1)[1]
    cells={name:int(count) for count,name in re.findall(r'^\s*(\d+)\s+([A-Z][A-Z0-9_]*)\s*$',last,re.M)}
    result={'status':'PASS','width':17,'height':5,'disp_bits':12,'cells':cells,
            'LUT1_to_LUT4':sum(cells.get('LUT'+str(n),0) for n in range(1,5)),
            'FF':sum(v for k,v in cells.items() if k.startswith('DFF')),
            'BRAM':sum(cells.get(n,0) for n in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9']),
            'DSP':sum(v for k,v in cells.items() if k.startswith(('MULT','ALU54','DSP'))),
            'rtl_sha256':hashlib.sha256((HERE/'img_stereo_lr_check.v').read_bytes()).hexdigest()}
    (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
