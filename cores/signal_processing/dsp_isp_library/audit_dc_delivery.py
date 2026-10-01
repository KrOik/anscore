"""Review promoted DC against frozen RTL, default integration and raw board data."""
import datetime, hashlib, json, sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];DC=HERE/'dsp/dc'
sys.path.insert(0,str(HERE/'board/block_harness'))
from protocol import verify
sys.path.insert(0,str(HERE/'board'))
from probe_external import parse_decode
from build_log_gate import assert_clean_build
manifest=json.loads((DC/'ip_manifest.json').read_text())
image=ROOT/manifest['candidate_board_image']['path_from_repo'];build=image.parent
assert_clean_build(build)
assert (DC/manifest['source']).read_bytes()==(build/'dc_stream.sv').read_bytes()
assert hashlib.sha256((DC/manifest['source']).read_bytes()).hexdigest()==manifest['source_sha256']
assert hashlib.sha256(image.read_bytes()).hexdigest()==manifest['candidate_board_image']['sha256']
default_uart=HERE/'board/block_harness/evidence/dc8_inferred_20260925_035630_761438/simulation_summary.json'
u=json.loads(default_uart.read_text());assert u['status']=='PASS' and u['latency']==2
default_chain=HERE/'chains/dc_statistics/evidence/sim_20260925_035643_791091/summary.json'
c=json.loads(default_chain.read_text());assert c['status']=='PASS' and c['dc_latency']==2
sessions=[]
for path in manifest['candidate_board_image']['inspected_evidence_from_repo']:
    folder=(ROOT/path).parent;v=json.loads((folder/'verdict.json').read_text())
    assert v['status']=='PASS' and v['sram_programmed'] and v['latency']==2
    assert v['sha256']==manifest['candidate_board_image']['sha256']
    results=[]
    for index,record in enumerate(v['cases']):
        case=folder/f'case_{index:02d}';e=json.loads((case/'expected.json').read_text())
        data=(case/'decoded.bin').read_bytes();assert data==parse_decode((case/'decoded.txt').read_text())
        assert (case/'capture.sr').stat().st_size>0
        r=verify(data,e['tag'],e['config'],e['words'],0,8,e['stall'],latency=2)
        assert r['tag']==record['tag'];results.append(r)
    sessions.append(dict(session=str(folder.relative_to(ROOT)),results=results))
dest=ROOT/'artifacts/dsp_isp_20260925'/('dc_delivery_audit_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
dest.write_text(json.dumps(dict(status='PASS',source_sha256=manifest['source_sha256'],default_uart=str(default_uart.relative_to(ROOT)),default_chain=str(default_chain.relative_to(ROOT)),sessions=sessions,scope='bounded production source/package integration; no arbitrary pole/duration claim'),indent=2))
print('PASS promoted DC identity, default integrations and23 physical reports',dest)
