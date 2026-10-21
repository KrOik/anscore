"""Promoted DC acceptance and still-failing representative hardware chains."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
B='cores/signal_processing/dsp_isp_library/';A='artifacts/dsp_isp_20260925/'
out=ROOT/A/'v3_tracking';out.mkdir(exist_ok=False)
p=HERE/'requirements.json';(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger=json.loads(p.read_text(encoding='utf-8'))
def add(row,field,*paths):
    for path in paths:
        assert (ROOT/path).is_file(),path
        if path not in row.setdefault(field,[]):row[field].append(path)
dc=json.loads((HERE/'dsp/dc/ip_manifest.json').read_text())
for row in ledger['requirements']:
    if row['id']=='DSP-09':
        row['status']='生产集成验收通过'
        row['inventory_status']='bounded DC production source and physical configurations accepted'
        for field in ('numeric_protocol','long_window','baseline_host_replay','blocker_host_replay','mean_host_replay','rounding_helpers'):
            add(row,'simulation',B+'dsp/dc/'+dc['simulation'][field])
        add(row,'checker_negative',B+'dsp/dc/'+dc['simulation']['numeric_protocol'])
        add(row,'synthesis',B+'dsp/dc/'+dc['core_synthesis']['evidence'])
        image=dc['candidate_board_image']['path_from_repo'];folder=image.rsplit('/',1)[0]
        add(row,'route_timing',folder+'/build_summary.json')
        for verdict in dc['candidate_board_image']['inspected_evidence_from_repo']:
            add(row,'board_injection',verdict)
            parent=verdict.rsplit('/',1)[0];add(row,'board_capture',parent+'/case_00/capture.sr',parent+'/case_00/decoded.bin')
            if '_02/' in verdict:add(row,'board_reprogram',verdict)
        add(row,'production',B+'dsp/dc/ip_manifest.json',A+'dc_delivery_audit_20260925_035911_615453.json',dc['production_integration']['default_uart'])
        row['limitations']=['v3 latency2/II1/two independently elastic slots intentionally replaces one-cycle production; legacy sources and failed captures preserved', 'Physical configurations: poles0/65024/65535, mean windows1/8/16/64, blocks1/64, stalls0/1/7; W256 wraps simulation only', 'Tool timing estimate is not silicon Fmax; finite physical tests do not prove arbitrary pole/window/duration; physical root cause of legacy failures not uniquely established']
    elif row['id']=='DSP-04':
        add(row,'failed_board_evidence',A+'dsp_chain_v3_board_01/verdict.json',A+'dsp_chain_rms_replay_01/verdict.json')
        row['limitations']=['Real-valued reference channel; no complex-magnitude claim', 'Composed hardware shows RMS-only numerical errors; all other record fields agree; source replay and independent sqrt pipeline candidate work pending', 'No production acceptance']
chain=ledger['integration_chains']['DSP'];chain['status']='physical_RMS_failure_under_repair'
for path in [B+'chains/dc_statistics/evidence/sim_20260925_035643_791091/summary.json',B+'chains/dc_statistics/evidence/synth_20260925_035701_208872/summary.json',B+'board/dsp_chain_harness/evidence/chain_20260925_035056_409839/build_summary.json',A+'dsp_chain_v3_board_01/verdict.json',A+'dsp_chain_rms_replay_01/verdict.json']:
    if path not in chain['evidence']:chain['evidence'].append(path)
chain=ledger['integration_chains']['ISP'];chain['status']='old_build_revoked_physical_failure_new_build_under_test'
chain['evidence']=[B+'chains/csc_morphology/README.md',B+'board/image_harness/RETIREMENTS.md',A+'isp_chain8_board_01/verdict.json',B+'board/image_harness/evidence/image8_pad1_20260925_035358_204245/build_summary.json']
p.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('DC bounded production accepted; both representative physical chains remain open.')
