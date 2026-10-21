"""Record reviewed window/statistics evidence and failed hardware qualification."""
import json
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[1]
path=here/'requirements.json';out=root/'artifacts/dsp_isp_20260925/expanded_tracking'
out.mkdir(parents=True,exist_ok=False)
(out/'requirements_before.json').write_bytes(path.read_bytes())
ledger=json.loads(path.read_text(encoding='utf-8'));base='cores/signal_processing/dsp_isp_library/'
for row in ledger['requirements']:
    if row['id'].startswith('INFRA-'):row['reuse_audit']=base+'infra/REUSE_AUDIT.md'
    if row['id']=='INFRA-02':
        row.update(status='仿真通过',configurations=['K3/5, VALID/ZERO/REPLICATE, 8/10bit; 30 simulation configurations; 12 synthesis configurations'],
                   implementation=[base+'infra/window/stream_window.v',base+'infra/window/stream_window_padded.v'],
                   bit_exact_model=[base+'infra/window/model.py'],
                   simulation=[base+'infra/window/evidence/padding_sim_02/results.json'],
                   checker_negative=[base+'infra/window/evidence/padding_sim_02/results.json'],
                   synthesis=[base+'infra/window/evidence/padding_synth_20260925_023358_118551/summary.json'],
                   limitations=['Physical memory K historical/current banks plus one row cache for padding; row capture/replay introduces documented input stalls', 'P&R, full raw-data board windows, reprogram and production integration pending'])
    if row['id']=='DSP-04':
        row.update(status='仿真通过',configurations=['real signed16; sliding/block windows1..64; magnitude, mean power, floor RMS, earliest-tie peak; scale -8..15; multiplier/LOGIC_SQUARE variants'],
                   specification=[base+'dsp/statistics/SPEC.md'],implementation=[base+'dsp/statistics/rtl/statistics_stream.sv'],
                   float_model=[base+'dsp/statistics/models/reference.py'],bit_exact_model=[base+'dsp/statistics/models/reference.py'],
                   simulation=[base+'dsp/statistics/evidence/rtl_20260925_023555_464308/summary.json'],
                   checker_negative=[base+'dsp/statistics/evidence/rtl_20260925_023555_464308/summary.json'],
                   synthesis=[base+'dsp/statistics/evidence/synth_variants_20260925_023712_913079/summary.json'],
                   documentation=[base+'dsp/statistics/SPEC.md'],
                   limitations=['Real-valued reference channel; no complex-magnitude claim', 'No routed or physical acceptance'])
    if row['id']=='DSP-09':
        row['failed_board_evidence']=['artifacts/dsp_isp_20260925/dc_board_02/verdict.json','artifacts/dsp_isp_20260925/dc_failure_replay_01/verdict.json','artifacts/dsp_isp_20260925/dc_explicit_replay_01/verdict.json']
        row['limitations']=['Physical mean window1 low-half numerical errors recur despite source/mapped-core simulation passing; source remains unchanged, isolated candidate under investigation', 'Higher stall7 rate diagnostic passes but cannot replace failed sustained-rate acceptance', 'Full production and remaining configurations not accepted']
    if row['id']=='ISP-01':
        row['failed_board_evidence']=['artifacts/dsp_isp_20260925/csc8_board_01/verdict.json','artifacts/dsp_isp_20260925/csc8_failure_replay_01/verdict.json']
        row['limitations']=['Real 64-pixel physical test has repeated low-byte bit error; independent fresh tag/count/cycle/SOF/EOL evidence retained', 'Pipeline candidate under development; original production source unchanged', 'No production acceptance']
    if row['id']=='INFRA-04':
        row['transport_evidence'].append('artifacts/dsp_isp_20260925/identity_inferred_board_01/verdict.json')
        row['progress_note']='External load/replay/raw capture implemented; identity path320 words passed, actual algorithm candidates show physical errors; no blanket harness or algorithm qualification'
path.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('Expanded full-scope tracking; failed physical cases preserved, no acceptance promoted.')
