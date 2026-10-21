"""Record the reviewed first batch. One-shot, retains previous ledger snapshot."""
import json
from pathlib import Path

here=Path(__file__).resolve().parent
root=here.parents[1]
ledger_path=here/'requirements.json'
archive=root/'artifacts/dsp_isp_20260925/initial_tracking'
archive.mkdir(parents=True,exist_ok=False)
(archive/'requirements_before.json').write_bytes(ledger_path.read_bytes())
ledger=json.loads(ledger_path.read_text(encoding='utf-8'))
base='cores/signal_processing/dsp_isp_library/'
for row in ledger['requirements']:
    domain=row['id'].split('-')[0]
    if domain in ['DSP','ISP']:
        row['reuse_audit']=base+domain.lower()+'/REUSE_AUDIT.md'
        row['inventory_status']='audited candidates; full requirement not yet accepted'
    if row['id']=='DSP-09':
        row.update(status='仿真通过',configurations=['signed Q1.15; DC blocker, sliding power-of-two window 1..256, baseline; pole 0..65535'],
                   specification=[base+'dsp/dc/SPEC.md'],implementation=[base+'dsp/dc/rtl/dc_stream.sv'],
                   float_model=[base+'dsp/dc/models/dc_reference.py'],bit_exact_model=[base+'dsp/dc/models/dc_reference.py'],
                   simulation=[base+'dsp/dc/evidence/rtl_20260925_022245_535434/summary.json'],
                   checker_negative=[base+'dsp/dc/evidence/rtl_20260925_022245_535434/summary.json'],
                   synthesis=[base+'dsp/dc/evidence/synth_20260925_0223/resources.json'],documentation=[base+'dsp/dc/SPEC.md'],
                   limitations=['Core synthesis only; P&R, raw external board data, reprogram, production packaging pending'])
    if row['id']=='ISP-01':
        row.update(status='仿真通过',configurations=['8/10bit; BT601/709; Full/Limited; RGB-to-YCbCr, inverse, grayscale (24 configurations)'],
                   specification=[base+'isp/CSC_SPEC.md'],implementation=[base+'isp/csc_stream.v',base+'isp/csc_coeffs.vh'],
                   float_model=[base+'isp/csc_model.py'],bit_exact_model=[base+'isp/csc_model.py'],
                   simulation=[base+'isp/evidence/20260925_022517_183931/summary.json'],
                   checker_negative=[base+'isp/evidence/20260925_022517_183931/summary.json'],
                   synthesis=[base+'isp/evidence/synth_20260925_022451_543991/summary.json'],documentation=[base+'isp/CSC_SPEC.md',base+'isp/CSC_STATUS.md'],
                   limitations=['Core synthesis only; combination matrix path requires timing qualification; no physical acceptance'])
    if row['id']=='INFRA-01':
        row.update(status='RTL完成',configurations=['elastic width1/8/32; FIFO RAM_DEPTH1/2/3/16; synthesis 16-bit payload+2 side bits at depth16/256'],
                   specification=[base+'infra/stream/README.md'],
                   implementation=[base+'infra/stream/stream_elastic.v',base+'infra/stream/stream_sync_fifo.v'],
                   bit_exact_model=[base+'infra/stream/model.py'],
                   simulation=[base+'infra/stream/evidence/20260925_021944_226830/summary.json'],
                   checker_negative=[base+'infra/stream/evidence/20260925_021944_226830/summary.json'],
                   synthesis=[base+'infra/stream/evidence/synth_20260925_022055_314233/summary.json'],documentation=[base+'infra/stream/README.md'],
                   not_applicable={'float_model':'Opaque stream storage: no numerical algorithm'},
                   limitations=['Partial item: shared configuration/status/error-counter block still pending', 'No route or board acceptance'])
    if row['id']=='INFRA-02':
        row.update(status='RTL完成',configurations=['VALID 3x3/5x5; eight dimension/8/10bit test combinations'],
                   specification=[base+'infra/window/README.md'],implementation=[base+'infra/window/stream_window.v'],
                   bit_exact_model=[base+'infra/window/test_window.py'],
                   simulation=['artifacts/dsp_isp_20260925/window_sim_01/results.json'],
                   checker_negative=['artifacts/dsp_isp_20260925/window_sim_01/results.json'],
                   synthesis=['artifacts/dsp_isp_20260925/window_synth_01/k3/resources.json','artifacts/dsp_isp_20260925/window_synth_01/k5/resources.json'],
                   documentation=[base+'infra/window/README.md'],not_applicable={'float_model':'Exact sample rearrangement; no numerical approximation'},
                   limitations=['Padding extension being developed; current physical bank count K includes current-row scratch', 'No route or board acceptance'])
    if row['id']=='INFRA-04':
        row['progress_note']='Fresh external transport probe passed twice; reusable load/replay/capture algorithm harness in development'
        row['transport_evidence']=['artifacts/dsp_isp_20260925/uart_external_01/verdict.json','artifacts/dsp_isp_20260925/uart_external_02/verdict.json']
        row['limitations']=['Transport qualification does not complete vector tools, algorithm replay, or per-result physical acceptance']
ledger_path.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('Recorded first batch; full objective remains active, no production-accepted items.')
