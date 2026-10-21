"""CSR adapter regression with real canonical atomic-config dependency."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT/'cores/image_processing/isp_stream'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [ROOT / 'cores/system/common_scaffold/image' / name for name in (
        'pipelines/img_bayer_window_frontend_draft.v','window/img_window3x3_valid_draft.v',
        'isp/img_isp_bayer_interpolate.v','isp/img_isp_awb_gain.v','isp/img_isp_ccm.v','isp/img_isp_gamma_lut.v','isp/img_isp_awb_stats.v',
        'filters/rtl/img_edge_sobel3x3.v','filters/rtl/img_edge_gradient3x3.v','filters/rtl/img_filter_stream_register.v')] + [
        ROOT / 'cores/system/stream_bus_library/rtl/sys_atomic_config.v',
        ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v',
        ROOT / 'cores/storage/buffer_dma/rtl/frame_stream_monitor.v',
        ROOT / 'cores/system/ip_test_shell/rtl/logic_probe8.v',
        ROOT / 'cores/system/stream_bus_library/board/sys_uart.v',
        ROOT / 'cores/system/ip_test_shell/rtl/uart_csr_transport.v', P / 'examples/25k/isp_top.v',P / 'tb/tb_isp_uart.v']
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('uart_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    report={'status':'IN_PROGRESS','sources':{str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources+[Path(__file__).resolve()]}}
    try:
        exe=out/'test.vvp'
        run=subprocess.run(['iverilog','-g2012','-s','tb_isp_uart','-o',str(exe)]+list(map(str,sources)),capture_output=True,text=True)
        (out/'compile.log').write_text(run.stdout+run.stderr)
        if run.returncode:raise RuntimeError(run.stderr)
        run=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=60)
        (out/'run.log').write_text(run.stdout+run.stderr)
        if run.returncode or 'PASS ISP board bit-serial UART' not in run.stdout:raise RuntimeError(run.stdout+run.stderr)
        report['status']='PASS';print(run.stdout.splitlines()[0])
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out))


if __name__=='__main__':main()
