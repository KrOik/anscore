"""Record bounded CSC production acceptance, new DC failure and isolated cores."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
B='cores/signal_processing/dsp_isp_library/';A='artifacts/dsp_isp_20260925/'
out=ROOT/A/'delivery_tracking';out.mkdir(exist_ok=False)
path=HERE/'requirements.json';(out/'requirements_before.json').write_bytes(path.read_bytes())
ledger=json.loads(path.read_text(encoding='utf-8'))
def add(row,field,*paths):
    for p in paths:
        assert (ROOT/p).is_file(),p
        if p not in row.setdefault(field,[]):row[field].append(p)
for row in ledger['requirements']:
    rid=row['id']
    if rid=='ISP-01':
        manifest=json.loads((HERE/'isp/ip_manifest.json').read_text())
        row['status']='生产集成验收通过'
        row['inventory_status']='bounded Stream CSC production source and board configurations accepted'
        add(row,'simulation',*manifest['default_and_legacy_regressions'],*manifest['default_board_regressions'])
        add(row,'checker_negative',manifest['default_and_legacy_regressions'][0])
        add(row,'production',B+'isp/ip_manifest.json',A+'csc_delivery_audit_20260925_033331_556357.json')
        for q in manifest['qualification']:
            add(row,'synthesis',str(Path(q['build']).with_name('synthesis_counts.json')).replace('\\','/'))
            for v in q['physical']:
                add(row,'board_injection',v['verdict'])
                folder=v['verdict'].rsplit('/',1)[0]
                add(row,'board_capture',folder+'/case_00/capture.sr',folder+'/case_11/decoded.bin')
                if 'board_02' in folder:add(row,'board_reprogram',v['verdict'])
        row['limitations']=['Latency changed from historical1 to4; II1 and numerical contract preserved; legacy source/regression and physical failures retained', 'Physical acceptance: 8/10bit, all12 configs, loaded blocks1/64 with stalls0/1/7, dedicated every-config64pixel fullrate at27MHz', 'UART bandwidth is not pixel throughput; no arbitrary camera resolution claim; ISP composed chain remains independent pending work']
    elif rid=='DSP-09':
        row['status']='仿真通过'
        add(row,'failed_board_evidence',A+'dc_candidate_boundaries_01/verdict.json',A+'dc_pole65535_replay_01/verdict.json',A+'dc_baseline_boundaries_01/verdict.json')
        row['limitations']=['Promoted mean narrowing passes prior bounded physical matrix; original and new boundary failures retained', 'New physical blocker/baseline pole65535 fails; blocker reprogram replay reproduces; source replay passes, root cause unresolved', 'Mean8/16 fullrate64-sample wrap and blocker/baseline pole0 pass in mixed verdict sessions; W256 wrap remains simulation only', 'No complete DC physical/production acceptance; diagnostic arithmetic candidate work ongoing']
    elif rid in ('DSP-02','ISP-02'):
        if rid=='DSP-02':
            prefix=B+'dsp/biquad/'
            fields={'implementation':['rtl/biquad_sos_stream.sv'],'float_model':['models/reference.py'],'bit_exact_model':['models/reference.py'],'specification':['SPEC.md'],'documentation':['README.md'],'simulation':['evidence/rtl_20260925_032757_874431/summary.json','evidence/model_validation_signed.json','evidence/frequency_validation.json'],'checker_negative':['evidence/rtl_20260925_032757_874431/summary.json'],'synthesis':['evidence/synth_20260925_032655_363788/summary.json']}
            row['configurations']=['DF-II-T runtime1..4 SOS, signed18 Q3.15 coefficients, signed16 data, atomic clear/retain, quantized Jury screen']
            row['limitations']=['Resource-oriented shared multiplier II=7*S+1; II1 target remains unqualified','Near-margin zero-tail deadband512LSB observed; no arbitrary coefficient switching/overload stability guarantee','No P&R or physical/production acceptance']
        else:
            prefix=B+'isp/convolution/'
            fields={'implementation':['convolution_stream.v'],'float_model':['model.py'],'bit_exact_model':['model.py'],'specification':['SPEC.md'],'documentation':['README.md'],'simulation':['evidence/sim_20260925_032529_241316/summary.json'],'checker_negative':['evidence/sim_20260925_032529_241316/summary.json'],'synthesis':['evidence/synth_20260925_032534_347881/summary.json']}
            row['configurations']=['K3/5, 8/10bit, ZERO/REPLICATE, signed12 true convolution kernels, signed32bias, RNE shift0..31, saturation']
            row['limitations']=['Shared single multiplier II10/26 for K3/K5; not accepted as continuous II1 configuration','No P&R or physical/production acceptance']
        row['status']='仿真通过'
        for field,paths in fields.items():add(row,field,*(prefix+p for p in paths))
chain=ledger['integration_chains']['DSP'];chain['status']='simulation_and_synthesis_pass_physical_pending'
chain['evidence']=[B+'chains/dc_statistics/README.md',B+'chains/dc_statistics/evidence/sim_20260925_032740_517370/summary.json',B+'chains/dc_statistics/evidence/synth_20260925_033036_401630/summary.json']
path.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('CSC bounded production accepted; DC boundary failure explicit; full goal remains open.')
