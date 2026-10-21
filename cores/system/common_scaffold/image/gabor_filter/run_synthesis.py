"""Isolated Gowin resource checks; temporary netlists are automatically removed."""
from pathlib import Path
import sys,tempfile,json,hashlib
from collections import Counter
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute

def main():
    results=[];rtl=HERE/'gabor_filter_frame.sv'
    for w,h in [(7,5),(32,32)]:
        with tempfile.TemporaryDirectory(prefix='gabor_synth_') as temporary:
            td=Path(temporary)
            header=rtl.read_text(encoding='utf-8').split('module gabor_filter_frame',1)[1].split(');',1)[0]
            header=('module synth_top'+header+');\n').replace('WIDTH=7,HEIGHT=5',f'WIDTH={w},HEIGHT={h}')
            (td/'wrapper.sv').write_text(header+'gabor_filter_frame #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) uut(.*);endmodule\n',encoding='utf-8')
            command=f'read_verilog -sv {rtl.as_posix()} {(td/"wrapper.sv").as_posix()}; synth_gowin -top synth_top -nodsp; check; stat; write_json {td.as_posix()}/net.json'
            out=execute(['yosys','-Q','-T','-p',command],HERE,td/'synthesis.log',timeout=180)
            data=json.loads((td/'net.json').read_text());cells=Counter()
            def walk(module):
                for cell in data['modules'][module]['cells'].values():
                    name=cell['type']
                    if name in data['modules'] and not int(data['modules'][name].get('attributes',{}).get('blackbox','0'),2):walk(name)
                    else:cells[name]+=1
            walk('synth_top')
            lut_class=sum(v for k,v in cells.items() if k.startswith(('LUT','MUX')) or k=='ALU')
            dsp=sum(v for k,v in cells.items() if any(s in k.upper() for s in ('MULT','DSP','MAC')))
            result=dict(width=w,height=h,cells=dict(cells),lut_class_including_alu_mux=lut_class,dsp_class=dsp,
                        check_zero_problems='Found and reported 0 problems.' in out)
            assert result['check_zero_problems'] and lut_class<=15000 and dsp<=4
            results.append(result);print(result,flush=True)
    report=dict(status='PASS',command='synth_gowin -top synth_top -nodsp; check; stat',profiles=results,
                rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),board_tested=False)
    (HERE/'synthesis_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
