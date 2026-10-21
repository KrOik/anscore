"""Compile the actual image RTL set and run selected bounded group checks.

No synthesis, board programming, old-project modifications, or per-core release
qualification is performed. All output directories are new and timestamped.
"""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def sources():
    # Only declared source directories; generated benches/old artifacts are not RTL.
    paths = []
    for group in ('isp','dehaze','multiframe','window','pipelines'):
        paths.extend(p for p in (ROOT/group).glob('*.v') if not p.name.startswith('tb_'))
    for group in ('filters','histogram','geometry'):
        paths.extend((ROOT/group/'rtl').glob('*.v'))
    return sorted(paths)


def environment():
    env=os.environ.copy()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite'
    if suite.is_dir():
        env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    return env


def audit(rtl):
    modules={}
    entries=0
    errors=[]
    listed=(ROOT/'rtl_sources.f').read_text(encoding='utf-8-sig').splitlines()
    actual=[p.relative_to(REPO).as_posix() for p in rtl]
    if sorted(listed)!=sorted(actual):errors.append('rtl_sources.f differs from actual source directories')
    for p in rtl:
        for name in re.findall(r'^\s*module\s+(\w+)',p.read_text(encoding='utf-8-sig'),re.M):
            if name in modules:errors.append('duplicate module '+name)
            modules[name]=p
    for group in ('isp','dehaze','multiframe','window','pipelines','filters','histogram','geometry'):
        manifest=ROOT/group/'manifest.json'
        for module in json.loads(manifest.read_text(encoding='utf-8-sig')).get('modules',[]):
            entries+=1
            if not (manifest.parent/module['path']).is_file():errors.append('missing manifest path '+module['path'])
            for dep in module.get('dependencies',[]):
                if dep.endswith(('.v','.sv')):
                    if not (manifest.parent/dep).is_file():errors.append('missing dependency '+dep)
                elif dep not in modules:errors.append('unknown dependency '+dep)
    return {'rtl_files':len(rtl),'module_names':len(modules),'manifest_entries':entries,'errors':errors}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--groups',default='core,histogram,dehaze,multiframe,geometry,isp,adaptive,otsu,otsu_frame,adaptive_frame',
                        help='comma-separated group names')
    parser.add_argument('--compile-only',action='store_true')
    args=parser.parse_args()
    env=environment()
    iverilog=shutil.which('iverilog',path=env['PATH'])
    vvp=shutil.which('vvp',path=env['PATH'])
    if not iverilog or not vvp:parser.error('iverilog and vvp required (scripts/env.ps1)')
    out=ROOT/('build_groups_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(exist_ok=False)
    rtl=sources()
    summary={'scope':'bounded_image_development_groups','rtl_files':len(rtl),'runs':[],
             'synthesis':'not_run','board':'not_run','resource_impact':'unknown; isolated from board top',
             'sources':{str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest()for p in rtl}}
    def run(name,cmd):
        print('RUN',name,flush=True)
        try:
            result=subprocess.run(cmd,cwd=REPO,env=env,capture_output=True,text=True,timeout=180)
            transcript=result.stdout+result.stderr
            code=result.returncode
        except subprocess.TimeoutExpired as exc:
            transcript='TIMEOUT: '+str(exc)
            code=124
        (out/(name+'.log')).write_text(transcript,encoding='utf-8')
        summary['runs'].append({'name':name,'command':list(map(str,cmd)),'exit_code':code})
        print(('PASS 'if code==0 else 'FAIL ')+name,flush=True)
        if code:print(transcript[-4000:])
        return code==0
    summary['source_audit']=audit(rtl)
    ok=not summary['source_audit']['errors']
    if not ok:print('FAIL source audit:',summary['source_audit']['errors'])
    else:ok=run('all_rtl_compile',[iverilog,'-g2012','-tnull',*map(str,rtl)])
    groups={
        'adaptive_frame':ROOT/'pipelines/run_adaptive_frame_tests.py',
        'otsu_frame':ROOT/'histogram/run_otsu_frame_tests.py',
        'otsu':ROOT/'histogram/run_otsu_tests.py',
        'adaptive':ROOT/'filters/run_adaptive_tests.py',
        'core':ROOT/'sim/run_image_core_group.py',
        'histogram':ROOT/'histogram/sim/run_histogram_group.py',
        'dehaze':ROOT/'dehaze/check_group_reference.py',
        'geometry':ROOT/'geometry/sim/run_geometry_group.py',
        'isp':ROOT/'pipelines/run_group_regression.py',
    }
    if ok and not args.compile_only:
        for group in args.groups.split(','):
            group=group.strip()
            if group=='multiframe':
                exe=out/'multiframe.vvp'
                mf_rtl=[p for p in rtl if p.parent.name=='multiframe']
                built=run('multiframe_compile',[iverilog,'-g2012','-s','tb_img_mf_frame_group','-o',str(exe),
                    str(ROOT/'multiframe/tb_img_mf_frame_group.v'),*map(str,mf_rtl)])
                checked=built and run('multiframe_simulation',[vvp,str(exe)])
            elif group in groups:
                checked=run(group,[sys.executable,str(groups[group])])
            else:
                print('Unknown group:',group);checked=False
            ok=checked and ok
    summary['pass_result']=ok
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Artifacts:',out)
    return 0 if ok else 1


if __name__=='__main__':
    sys.exit(main())
