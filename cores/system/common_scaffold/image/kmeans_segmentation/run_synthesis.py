from pathlib import Path
import sys,tempfile,json,hashlib
from collections import Counter
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
results=[]
for width,height in [(7,5),(32,32)]:
    with tempfile.TemporaryDirectory(prefix='kmeans_synth_') as temporary:
        td=Path(temporary);rtl=HERE/'kmeans_rgb_frame.sv'
        header=rtl.read_text(encoding='utf-8').split(');',1)[0]+');\n'
        header=header.replace('module kmeans_rgb_frame','module synth_top').replace('WIDTH=7,HEIGHT=5',f'WIDTH={width},HEIGHT={height}')
        (td/'wrapper.sv').write_text(header+'kmeans_rgb_frame #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) uut(.*);endmodule\n',encoding='utf-8')
        command=f'read_verilog -sv {rtl.as_posix()} {(td/"wrapper.sv").as_posix()}; synth_gowin -top synth_top -noalu -nodsp; check; stat; write_json {td.as_posix()}/net.json'
        out=execute(['yosys','-Q','-T','-p',command],HERE,td/'synthesis.log',timeout=180)
        data=json.loads((td/'net.json').read_text());cells=Counter()
        def walk(module):
            for cell in data['modules'][module]['cells'].values():
                name=cell['type']
                if name in data['modules'] and not int(data['modules'][name].get('attributes',{}).get('blackbox','0'),2):walk(name)
                else:cells[name]+=1
        walk('synth_top')
        result=dict(width=width,height=height,cells=dict(cells),check_zero_problems='Found and reported 0 problems.' in out)
        assert result['check_zero_problems'];results.append(result);print(result,flush=True)
(HERE/'synthesis_evidence.json').write_text(json.dumps(dict(status='PASS',command='synth_gowin -top synth_top -noalu -nodsp; check; stat',profiles=results,rtl_sha256=hashlib.sha256((HERE/'kmeans_rgb_frame.sv').read_bytes()).hexdigest()),indent=2)+'\n',encoding='utf-8')
