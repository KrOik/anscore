from pathlib import Path
import sys,tempfile,json,hashlib
from collections import Counter
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
with tempfile.TemporaryDirectory(prefix='jpeg_color_headers_synth_') as temporary:
    td=Path(temporary)
    command=f'read_verilog -sv {(HERE/"jpeg_color_headers.sv").as_posix()}; synth_gowin -top jpeg_color_headers -noalu -nodsp; check; stat; write_json {td.as_posix()}/net.json'
    output=execute(['yosys','-Q','-T','-p',command],HERE,td/'synthesis.log',timeout=180)
    data=json.loads((td/'net.json').read_text())
    cells=Counter(c['type'] for c in data['modules']['jpeg_color_headers']['cells'].values())
    result=dict(status='PASS',command='synth_gowin -top jpeg_color_headers -noalu -nodsp; check; stat',cells=dict(cells),check_zero_problems='Found and reported 0 problems.' in output,rtl_sha256=hashlib.sha256((HERE/'jpeg_color_headers.sv').read_bytes()).hexdigest())
    assert result['check_zero_problems']
    (HERE/'synthesis.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))
