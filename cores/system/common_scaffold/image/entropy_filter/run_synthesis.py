"""Isolated Gowin resource check; temporary netlists and logs are removed."""
from pathlib import Path
from collections import Counter
import sys,tempfile,json,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def main():
    profiles=[];rtl=HERE/'entropy_filter_frame.sv'
    for w,h in [(7,5),(32,32)]:
        with tempfile.TemporaryDirectory(prefix='entropy_synth_') as tmp:
            td=Path(tmp);(td/'entropy.mem').write_bytes((HERE/'entropy.mem').read_bytes())
            head=rtl.read_text().split('module entropy_filter_frame',1)[1].split(');',1)[0]
            head=('module synth_top'+head+');\n').replace('WIDTH=7,HEIGHT=5',f'WIDTH={w},HEIGHT={h}')
            (td/'wrapper.sv').write_text(head+'entropy_filter_frame #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.ENTROPY_FILE(ENTROPY_FILE))uut(.*);endmodule\n')
            command=f'read_verilog -sv {rtl.as_posix()} {(td/"wrapper.sv").as_posix()}; synth_gowin -top synth_top -nodsp; check -assert; stat; write_json {td.as_posix()}/net.json'
            out=execute(['yosys','-Q','-T','-p',command],td,td/'synth.log',timeout=180)
            net=json.loads((td/'net.json').read_text());cells=Counter()
            def walk(name):
                for c in net['modules'][name]['cells'].values():
                    t=c['type']
                    if t in net['modules'] and not int(net['modules'][t].get('attributes',{}).get('blackbox','0'),2):walk(t)
                    else:cells[t]+=1
            walk('synth_top')
            lut=sum(v for k,v in cells.items() if k.startswith(('LUT','MUX')) or k=='ALU')
            dsp=sum(v for k,v in cells.items() if any(s in k.upper() for s in ('DSP','MULT','MAC')))
            profile=dict(width=w,height=h,cells=dict(cells),lut_class_including_alu_mux=lut,dsp_class=dsp,
                         check_zero_problems='Found and reported 0 problems.' in out)
            assert lut<=15000 and dsp<=4 and profile['check_zero_problems'];profiles.append(profile);print(profile,flush=True)
    sha=lambda n:hashlib.sha256((HERE/n).read_bytes()).hexdigest()
    result=dict(status='PASS',command='synth_gowin -top synth_top -nodsp; check -assert; stat',profiles=profiles,
                rtl_sha256=sha('entropy_filter_frame.sv'),rom_sha256=sha('entropy.mem'),board_tested=False)
    (HERE/'synthesis_evidence.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
