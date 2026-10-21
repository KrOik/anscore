"""Refresh allowlisted function-organized source packages; never import Git history."""
import argparse,hashlib,json,os,re
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace',type=Path,required=True)
    parser.add_argument('--repository',type=Path,required=True)
    args=parser.parse_args();root=args.workspace.resolve();repo=args.repository.resolve()
    packages=json.loads((repo/'docs/package_map.json').read_text())
    packages.update({'buffer_dma_25k':'storage/buffer_dma','cnn_infer_25k':'acceleration/cnn_infer_25k',
        'isp_stream_25k':'image_processing/isp_stream','lockin_dsp_25k':'signal_processing/lockin',
        'ethernet_udp_25k':'communication/ethernet_udp','video_compositor_25k':'image_processing/video_compositor',
        'motor_foc_25k':'control/motor_foc','ip_test_shell_25k':'system/ip_test_shell',
        'common_ip_scaffold':'system/common_scaffold'})
    extensions={'.v','.sv','.vh','.vhd','.vhdl','.py','.ps1','.sh','.md','.json','.f','.txt','.sby','.tcl','.ys','.bat','.yaml','.yml','.cst','.sdc','.mem','.hex','.csv','.c','.h','.S','.ld','.gprj'}
    skips={'.git','__pycache__','node_modules','.venv','venv','artifacts','evidence','source_snapshot','camera_acceptance','releases','captures','_staged','impl'}
    previous={item['path'] for item in json.loads((repo/'docs/third_party_exclusions.json').read_text())}
    changes=[];excluded=[]
    def copy(source,dest):
        raw=source.read_bytes()
        if raw.startswith(b'\xef\xbb\xbf'):raw=raw[3:]
        try:text=raw.decode('utf-8')
        except UnicodeDecodeError:return
        if source.suffix.lower() in {'.v','.sv','.vh','.c','.h','.vhd'} and re.search(r'Gowin Semiconductor|Gisselquist|Secworks Sweden|Claire Xenia Wolf|Copyright[^\n]*Clifford Wolf',text[:12000],re.I):return
        text=text.replace('\r\n','\n')
        for old,new in packages.items():
            text=text.replace('projects/'+old,'cores/'+new).replace('projects\\'+old,'cores\\'+new.replace('/','\\'))
        # Python tools in deeper functional package paths locate repository root.
        text=text.replace('Path(__file__).resolve().parents[3]',"next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())")
        data=text.encode();dest.parent.mkdir(parents=True,exist_ok=True)
        if not dest.exists() or dest.read_bytes()!=data:dest.write_bytes(data);changes.append(dest.relative_to(repo).as_posix())
    for old,new in packages.items():
        source=root/'projects'/old
        for base,dirs,files in os.walk(source):
            dirs[:]=[d for d in dirs if d not in skips and not d.startswith(('build','evidence_','run_','pnr_','synth_'))]
            for name in files:
                p=Path(base)/name;rel=p.relative_to(source);dest=repo/'cores'/new/rel
                if p.suffix not in extensions or p.stat().st_size>2*1024*1024:continue
                if name=='remote.txt' or name.startswith(('.remote','net_st_')) or dest.relative_to(repo).as_posix() in previous:continue
                if p.suffix=='.json':
                    head=p.read_text(errors='replace')[:4096]
                    if '"creator"' in head and ('Yosys' in head or 'Next Generation Place and Route' in head):continue
                copy(p,dest)
    # Update already-published top-level scripts, preserving the existing scope.
    for dest in (repo/'scripts').iterdir():
        src=root/'scripts'/dest.name
        if src.is_file() and src.suffix in extensions and src.name!='import_anscore_history.py':copy(src,dest)
    for name in ['STATUS.md','IP_INDEX.md','DEPENDENCIES.md','ip_catalog.yaml','catalog_audit.json']:
        src=root/'work/ip_asset_25k'/name
        if src.is_file():copy(src,repo/'docs/ip_asset_25k'/name)
    copy(root/'docs/FPGA_IP_ASSET_WORK_ORDER_25K_V3_20261020.md',repo/'docs/FPGA_IP_ASSET_WORK_ORDER_25K_V3_20261020.md')
    (repo/'docs/package_map.json').write_text(json.dumps(packages,indent=2)+'\n')
    print(json.dumps(dict(updated=len(changes),packages=len(packages)),indent=2))
if __name__=='__main__':main()
