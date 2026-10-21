"""Freeze and build complete UDP CSR top for25K; never downloads automatically."""
from collections import Counter
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/communication/ethernet_udp'


def main():
    sources=sorted((P/'rtl').glob('*.v'))+[ROOT/'cores/system/stream_bus_library/board/sys_uart.v',
        ROOT/'cores/system/ip_test_shell/rtl/uart_csr_transport.v',P/'examples/25k/udp_top.v']
    sources += [ROOT/n for n in ['projects/net_av_hdmi_20k/src/av_rmii_rx.v','cores/system/stream_bus_library/rtl/sys_timestamp64.v','cores/system/stream_bus_library/rtl/sys_atomic_config.v']]
    cst=P/'examples/25k/udp.cst';inputs=sources+[cst,Path(__file__).resolve()]
    hashes={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    fingerprint=hashlib.sha256(json.dumps(hashes,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
    out=ROOT/'artifacts/ethernet_udp_25k'/datetime.now(timezone.utc).strftime('board_%Y%m%dT%H%M%S%fZ');out.mkdir(parents=True)
    snap=out/'source_snapshot'
    for p in inputs:
        dest=snap/p.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
        if hashlib.sha256(dest.read_bytes()).hexdigest()!=hashes[p.relative_to(ROOT).as_posix()]:raise RuntimeError('source changed')
    (out/'source_snapshot_manifest.json').write_text(json.dumps(hashes,indent=2)+'\n')
    report=dict(status='IN_PROGRESS',target='GW5A-LV25MG121NES',clock_mhz=50,board_downloaded=False,
                hardware_build_id=fingerprint,sources=hashes,source_snapshot='source_snapshot')
    def run(name,command):
        report[name+'_command']=command
        with (out/(name+'.log')).open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,cwd=snap)
        if r.returncode:raise RuntimeError(name+' failed,exit='+str(r.returncode))
    print('Evidence='+str(out),flush=True)
    try:
        # GW5A target database has no RAM16SDP4 BELs. Keep small bias storage
        # out of unsupported distributed RAM; use narrow LUTs for placement.
        script="read_verilog -defer -D UDP_BUILD_ID=64'h"+fingerprint+' '+' '.join(p.relative_to(ROOT).as_posix() for p in sources)+'; synth_gowin -family gw5a -nolutram -nowidelut -top udp_top -json '+(out/'design.json').as_posix()+'; stat'
        (out/'synth.ys').write_text(script+'\n');run('synthesis',['yosys','-Q','-p',script])
        report['synthesis_cells']=dict(Counter(c['type'] for c in json.loads((out/'design.json').read_text())['modules']['udp_top']['cells'].values()))
        print('Synthesis PASS; routing',flush=True)
        run('pnr',['nextpnr-himbaechel','--json',str(out/'design.json'),'--write',str(out/'routed.json'),'--device',report['target'],
            '--freq','50','--report',str(out/'pnr_report.json'),'--vopt','family=GW5A-25A','--vopt','cst='+str(snap/cst.relative_to(ROOT)),'--vopt','sspi_as_gpio'])
        oss=Path(os.environ['OSS_CAD_PYTHON']).parent.parent/'bin'
        run('pack',[os.environ['OSS_CAD_PYTHON'],str(oss/'gowin_pack-script.py'),'-d','GW5A-25A','--sspi_as_gpio','-o',str(out/'udp.fs'),str(out/'routed.json')])
        report.update(status='PASS',bitstream_sha256=hashlib.sha256((out/'udp.fs').read_bytes()).hexdigest(),pnr_report=json.loads((out/'pnr_report.json').read_text()))
        print('Route/pack PASS',flush=True)
    except Exception as exc:report.update(status='FAIL',reason=str(exc));raise
    finally:(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('Evidence='+str(out),flush=True)


if __name__=='__main__':main()
