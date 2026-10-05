"""Validate exact promoted source/evidence identity and emit production manifest."""
import hashlib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[2];LIB=HERE.parent
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def rel(p):return p.relative_to(ROOT).as_posix()
def main():
    frozen='0ecd8f6416ef31cdcce3b9557b7972a310bba88006a101ce3f0458d347e9237a'
    assert digest(HERE/'csc_stream.v')==digest(HERE/'candidates/pipeline4/csc_stream.v')==frozen
    builds={8:'csc8_inferred_20260925_031306_002825',10:'csc10_inferred_20260925_031627_439716'}
    qualified=[]
    for bits,name in builds.items():
        d=LIB/'board/block_harness/evidence'/name;s=read(d/'build_summary.json')
        assert s['status']=='BUILD_PASS_NOT_BOARD' and s['latency']==4 and s['bits']==bits and s['lut']<=15000 and s['dsp']<=4 and min(s['fmax_mhz'])>=27
        assert digest(d/'csc_stream.v')==frozen and digest(d/'block.fs')==s['bitstream_sha256']
        physical=[]
        for suffix in ('board_01','board_02','fullrate_01'):
            b=ROOT/'artifacts/dsp_isp_20260925'/f'csc{bits}_pipeline4_{suffix}';v=read(b/'verdict.json')
            assert v['status']=='PASS' and v['sha256']==s['bitstream_sha256'] and v['latency']==4 and len(v['cases'])==12
            configs=[]
            for i,c in enumerate(v['cases']):
                e=read(b/f'case_{i:02d}'/'expected.json');configs.append(e['config'])
                assert c['status']=='PASS' and c['negative_check']=='PASS'
                if suffix=='fullrate_01':assert c['count']==64 and c['cycles']==68 and len(e['words'])==64 and e['stall']==0
            assert sorted(configs)==list(range(12))
            physical.append(dict(verdict=rel(b/'verdict.json'),coverage='all12 configs x64 words, stall0, 68 cycles' if suffix=='fullrate_01' else 'cfg0 one word, cfg1..11 64 words, mixed stall0/1/7'))
        qualified.append(dict(bits=bits,source_snapshot=rel(d/'csc_stream.v'),build=rel(d/'build_summary.json'),image=rel(d/'block.fs'),image_sha256=s['bitstream_sha256'],physical=physical))
    regression_paths=[HERE/'evidence/20260925_032401_924030/summary.json',HERE/'evidence/20260925_032420_209129/summary.json']
    assert [read(p)['latency'] for p in regression_paths]==[4,1]
    for p in regression_paths:assert read(p)['status']=='PASS'
    board_regressions=[]
    for name,latency in [('csc8_inferred_20260925_032433_403770',4),('csc10_inferred_20260925_032456_263575',4),('dc8_inferred_20260925_032514_596661',1),('identity8_inferred_20260925_032532_255121',1)]:
        p=LIB/'board/block_harness/evidence'/name/'simulation_summary.json';v=read(p);assert v['status']=='PASS' and v['latency']==latency;board_regressions.append(rel(p))
    manifest=dict(ip_name='dsp_isp_csc',module='csc_stream',status='production_source_qualified_bounded_board_configuration',core_sources=[rel(HERE/'csc_stream.v')],include_files=[rel(HERE/'csc_coeffs.vh')],source_sha256=frozen,coefficient_sha256=digest(HERE/'csc_coeffs.vh'),parameters={'BITS':[8,10]},operations=['RGB_to_YCbCr','YCbCr_to_RGB','RGB_to_gray'],standards=['BT601','BT709'],ranges=['Full','Limited'],interface='ready/valid with pixel-bound SOF/EOL',reset='active-low synchronous, discard pipeline and pending config',latency=4,II=1,capacity=4,stall='global advance; ready=!m_valid||m_ready',configuration='atomic pending slot commits on accepted SOF',spec=rel(HERE/'CSC_SPEC.md'),legacy={'source':rel(HERE/'legacy/one_cycle_904bbc03/csc_stream.v'),'latency':1},qualification=qualified,default_and_legacy_regressions=[rel(p) for p in regression_paths],default_board_regressions=board_regressions,evidence_reuse='Canonical source byte-identical to both qualified build snapshots; coefficients unchanged; default-entry simulations rerun; no new bitstream claimed',limits=['Physical cases bounded to1/64-word loaded blocks and one-row markers','Fullrate means27MHz RAM replay, not UART line rate','Tool Fmax is not measured silicon Fmax','No claim of arbitrary camera resolution or full-library completion'])
    (HERE/'ip_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('PASS production source/evidence identity and default regressions',HERE/'ip_manifest.json')
if __name__=='__main__':main()
