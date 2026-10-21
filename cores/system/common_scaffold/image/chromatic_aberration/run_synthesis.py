"""Isolated full-hierarchy Gowin synthesis; transient netlists auto removed."""
from pathlib import Path
import sys,tempfile,json,hashlib
from collections import Counter
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
SOURCES=[HERE/'chromatic_aberration_frame.sv',HERE.parent/'lens_distortion/lens_distortion_map.sv',HERE.parent/'geometry/rtl/img_geo_frame_sampler.v']

def main():
    results=[]
    for bits in (8,12):
        with tempfile.TemporaryDirectory(prefix='chromatic_synth_') as temporary:
            td=Path(temporary)
            header=SOURCES[0].read_text().split(');',1)[0]+');\n'
            header=header.replace('module chromatic_aberration_frame','module synth_top').replace('WIDTH=7,HEIGHT=5,BITS=8',f'WIDTH=9,HEIGHT=7,BITS={bits}')
            wrapper=td/'wrapper.sv'
            wrapper.write_text(header+'chromatic_aberration_frame #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(BITS)) uut(.*);\nendmodule\n',encoding='utf-8')
            command='read_verilog -sv '+' '.join(p.as_posix() for p in [*SOURCES,wrapper])+f'; synth_gowin -top synth_top -noalu -nodsp; check; stat; write_json {td.as_posix()}/net.json'
            output=execute(['yosys','-Q','-T','-p',command],HERE,td/'synthesis.log',timeout=180)
            data=json.loads((td/'net.json').read_text());counts=Counter()
            def walk(module):
                for cell in data['modules'][module]['cells'].values():
                    kind=cell['type']
                    if kind in data['modules'] and not int(data['modules'][kind].get('attributes',{}).get('blackbox','0'),2):walk(kind)
                    else:counts[kind]+=1
            walk('synth_top')
            result=dict(width=9,height=7,bits=bits,cells=dict(counts),check_zero_problems='Found and reported 0 problems.' in output)
            assert result['check_zero_problems']
            results.append(result);print(result,flush=True)
    evidence=dict(command='parameterized synth_top wrapper; synth_gowin -top synth_top -noalu -nodsp; check; stat',scope='Recursive full hierarchy including actual lens mapper and production sampler',profiles=results,source_sha256={str(p.relative_to(HERE.parents[1])):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES})
    (HERE/'synthesis_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
