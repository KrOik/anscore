"""Retry terminal failed ISP placement using frozen synthesis inputs."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('failed_build',type=Path)
    parser.add_argument('--placer',choices=('heap','sa'),default='heap')
    parser.add_argument('--seed',type=int,default=2)
    args=parser.parse_args();old=args.failed_build.resolve()
    original=json.loads((old/'summary.json').read_text())
    if original['status']!='FAIL' or 'pnr failed' not in original.get('reason',''):
        raise ValueError('requires terminal placement/routing failure')
    manifest=json.loads((old/'source_snapshot_manifest.json').read_text())
    for name,digest in manifest.items():
        if hashlib.sha256((old/'source_snapshot'/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('frozen source hash mismatch: '+name)
    out=ROOT/'artifacts/isp_stream_25k'/datetime.now(timezone.utc).strftime('board_retry_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    shutil.copytree(old/'source_snapshot',out/'source_snapshot')
    for name in ('design.json','source_snapshot_manifest.json'):
        shutil.copyfile(old/name,out/name)
    report=dict(status='IN_PROGRESS',target=original['target'],clock_mhz=50,
                board_downloaded=False,sources=manifest,source_snapshot='source_snapshot',
                synthesis_cells=original['synthesis_cells'],parent_build=str(old),placer=args.placer,seed=args.seed,
                synthesis_netlist_sha256=hashlib.sha256((out/'design.json').read_bytes()).hexdigest(),
                retry_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    def run(name,command):
        report[name+'_command']=command
        with (out/(name+'.log')).open('w') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,cwd=ROOT)
        if result.returncode:raise RuntimeError(name+' failed, exit='+str(result.returncode))
    print('Evidence='+str(out),flush=True)
    try:
        cst=out/'source_snapshot/cores/image_processing/isp_stream/examples/25k/isp.cst'
        run('pnr',['nextpnr-himbaechel','--json',str(out/'design.json'),'--write',str(out/'routed.json'),
                   '--device',original['target'],'--freq','50','--report',str(out/'pnr_report.json'),
                   '--placer',args.placer,'--seed',str(args.seed),'--vopt','family=GW5A-25A','--vopt','cst='+str(cst),'--vopt','sspi_as_gpio']
                   +(['--placer-heap-no-ctrl-set'] if args.placer=='heap' else []))
        oss=Path(os.environ['OSS_CAD_PYTHON']).parent.parent/'bin'
        run('pack',[os.environ['OSS_CAD_PYTHON'],str(oss/'gowin_pack-script.py'),'-d','GW5A-25A',
                    '--sspi_as_gpio','-o',str(out/'isp.fs'),str(out/'routed.json')])
        report.update(status='PASS',bitstream_sha256=hashlib.sha256((out/'isp.fs').read_bytes()).hexdigest(),
                      pnr_report=json.loads((out/'pnr_report.json').read_text()))
        print('Route/pack PASS',flush=True)
    except Exception as exc:
        report.update(status='FAIL',reason=str(exc));raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
        print('Evidence='+str(out),flush=True)


if __name__=='__main__':main()
