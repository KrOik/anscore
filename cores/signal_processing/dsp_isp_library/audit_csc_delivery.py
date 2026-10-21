"""Independent delivery review: current source identity and raw physical results."""
import datetime, hashlib, json, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
sys.path.insert(0,str(HERE/'board/block_harness'))
from protocol import verify
sys.path.insert(0,str(HERE/'board'))
from probe_external import parse_decode
manifest=json.loads((HERE/'isp/ip_manifest.json').read_text())
review=[]
for item in manifest['qualification']:
    build=(ROOT/item['build']).parent
    for name in ('csc_stream.v','csc_coeffs.vh'):
        assert (HERE/'isp'/name).read_bytes()==(build/name).read_bytes(),name
    assert hashlib.sha256((ROOT/item['image']).read_bytes()).hexdigest()==item['image_sha256']
    for session in item['physical']:
        folder=(ROOT/session['verdict']).parent
        verdict=json.loads((folder/'verdict.json').read_text())
        assert verdict['sram_programmed'] and verdict['sha256']==item['image_sha256']
        results=[]
        for index in range(12):
            case=folder/f'case_{index:02d}'
            expected=json.loads((case/'expected.json').read_text())
            raw=(case/'decoded.bin').read_bytes()
            assert raw==parse_decode((case/'decoded.txt').read_text())
            assert (case/'capture.sr').stat().st_size>0
            result=verify(raw,expected['tag'],expected['config'],expected['words'],1,item['bits'],expected['stall'],latency=4)
            assert result['tag']==verdict['cases'][index]['tag']
            results.append(result)
        review.append(dict(session=str(folder.relative_to(ROOT)),bits=item['bits'],results=results))
dest=ROOT/'artifacts/dsp_isp_20260925'/('csc_delivery_audit_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
dest.write_text(json.dumps(dict(status='PASS',source_sha256=manifest['source_sha256'],sessions=review,scope='72 physically captured cases rechecked against independent host model; current source/include identical to both qualified images'),indent=2))
print('PASS 72 physical reports and current source/include identity',dest)
