"""Isolated Gowin synthesis of stream_stats only; no timing, P&R or board
acceptance claim. synth_gowin is run without a -family flag (default family).
"""
import datetime,hashlib,json,pathlib,subprocess
from collections import Counter
from test_stats import ROOT,tools

out=ROOT/'evidence'/('synth_stats_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
out.mkdir(parents=True)
results=[]
for uw in (1,3):
    name=f'stream_stats_u{uw}'
    work=out/name;work.mkdir()
    source=ROOT/'stream_stats.v'
    script=f'read_verilog "{source.as_posix()}"\n'
    script+=f'chparam -set USER_WIDTH {uw} stream_stats\n'
    script+='synth_gowin -top stream_stats -noalu -json mapped.json\nstat\n'
    (work/'synth.ys').write_text(script)
    cmd=[tools('yosys'),'-s','synth.ys']
    p=subprocess.run(cmd,cwd=work,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (work/'synth.log').write_text('$ '+' '.join(cmd)+'\n'+p.stdout)
    assert p.returncode==0,p.stdout[-4000:]
    net=json.loads((work/'mapped.json').read_text())
    cells=Counter(c['type'] for c in net['modules']['stream_stats']['cells'].values())
    result=dict(module='stream_stats',user_width=uw,
                cells=dict(cells),source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                synth_command='synth_gowin -top stream_stats -noalu (no -family flag)',
                status='SYNTHESIS PASS',scope='core plus default synthesis IO pads; not P&R',
                timing='NOT RUN',board='NOT RUN')
    results.append(result);print(name,dict(cells))
(out/'summary.json').write_text(json.dumps(results,indent=2))
print(out)
