"""Isolated Gowin synthesis only; no timing, P&R or board acceptance claim."""
import datetime,hashlib,json,pathlib,subprocess
from collections import Counter
from test_stream import ROOT,tools

out=ROOT/'evidence'/('synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
out.mkdir(parents=True)
results=[]
for module,depth in [('stream_elastic',None),('stream_sync_fifo',16),('stream_sync_fifo',256)]:
    name=module+('' if depth is None else '_d'+str(depth))
    work=out/name;work.mkdir()
    source=ROOT/(module+'.v')
    script=f'read_verilog "{source.as_posix()}"\n'
    script+=f'chparam -set DATA_WIDTH 16 -set USER_WIDTH 1 {module}\n'
    if depth is not None:script+=f'chparam -set RAM_DEPTH {depth} {module}\n'
    script+=f'synth_gowin -top {module} -family gw2a -noalu -json mapped.json\nstat\n'
    (work/'synth.ys').write_text(script)
    cmd=[tools('yosys'),'-s','synth.ys']
    p=subprocess.run(cmd,cwd=work,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (work/'synth.log').write_text('$ '+' '.join(cmd)+'\n'+p.stdout)
    assert p.returncode==0,p.stdout[-4000:]
    net=json.loads((work/'mapped.json').read_text())
    cells=Counter(c['type'] for c in net['modules'][module]['cells'].values())
    result=dict(module=module,ram_depth=depth,data_width=16,user_width=1,payload_width=18,
                cells=dict(cells),source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                status='SYNTHESIS PASS',scope='core plus default synthesis IO pads; not P&R',timing='NOT RUN',board='NOT RUN')
    results.append(result);print(name,dict(cells))
(out/'summary.json').write_text(json.dumps(results,indent=2))
print(out)
