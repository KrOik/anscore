"""Collect source-checked accepted profiles without altering original evidence."""
import argparse
import hashlib
import json
from pathlib import Path
from common import ROOT,REPO,evidence,hashes
from build import routed_metrics

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--builds',nargs='+',type=Path,required=True)
    ap.add_argument('--isolated-from',type=Path);a=ap.parse_args()
    out=evidence('build_accepted');rows={};origins=[];transport=None
    for path in a.builds:
        path=path.resolve()
        s=json.loads((path/'summary.json').read_text())
        assert transport is None or transport==s['transport'];transport=s['transport']
        origins.append(dict(path=path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path),
                            original_status=s['status'],accepted_profiles=[r['profile'] for r in s['profiles'] if r.get('route')=='PASS' and r.get('bitstream')],
                            summary_sha256=hashlib.sha256((path/'summary.json').read_bytes()).hexdigest()))
        for r in s['profiles']:
            if r.get('route')!='PASS' or not r.get('bitstream'):continue
            assert r['route']=='PASS' and r['under_budget'] and r['fmax_mhz']>=50
            top='sys_auto_top' if s['transport']=='JTAG-loaded-raw-UART' else 'sys_top'
            physical=routed_metrics(path/f'profile_{r["profile"]}.json',top,
                    (path/f'profile_{r["profile"]}_nextpnr.log').read_text(encoding='utf-8'))
            assert physical['under_budget'],('physical budget',r['profile'],physical)
            r=dict(r,**physical,origin=path.relative_to(ROOT).as_posix())
            for f,h in r['input_sha256'].items():assert hashlib.sha256((REPO/f).read_bytes()).hexdigest()==h,('changed source',f)
            assert hashlib.sha256((ROOT/r['bitstream']).read_bytes()).hexdigest()==r['bitstream_sha256']
            assert r['profile'] not in rows;rows[r['profile']]=r
    assert set(rows)==set(range(9)),('missing profiles',set(range(9))-set(rows))
    isolated=[]
    if a.isolated_from:
        si=json.loads((a.isolated_from/'summary.json').read_text());assert si['status']=='PASS' and len(si['isolated'])==16
        for f,h in si['sources'].items():
            if f.startswith('rtl/'):assert hashlib.sha256((ROOT/f).read_bytes()).hexdigest()==h
        isolated=si['isolated']
    report=dict(status='PASS',transport=transport,device='GW5A-LV25MG121NES',family='GW5A-25A',clock_mhz=50,clock_enable=1,
                origins=origins,profiles=[rows[i] for i in range(9)],isolated=isolated,sources=hashes())
    (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print(out)

if __name__=='__main__':main()
