"""One fixed numerical preparation payload, entered only through prepare_gate."""
import argparse
import importlib.util
import json
import sys
from pathlib import Path
from guards import ROOT,PACKAGE,read,dump,sha,verify_context,fixture_names,file_map,render_child


def materialize(case,profile,solve=True):
    values=pixels(case['recipe'],profile['width'],profile['height'])
    n=len(values);w=profile['width'];c=case['config'];mask=(1<<profile['tag_w'])-1
    inputs=[]
    for i,value in enumerate(values):
        sof=int(i==0);eol=int(i%w==w-1)
        if case.get('marker_error',0)&1 and i==0:sof=0
        if case.get('marker_error',0)&2 and i==n-1:eol^=1
        live=[c['bright'],c['delta'],c['min_area'],c['max_area'],c['p'],c['q']] if i==0 else [1-c['bright'],0,0,0,0,0]
        inputs.append([case['sequence'],i,value,sof,eol,(case['tag']^(i!=0))&mask,*live])
    error=case.get('marker_error',0)
    if c['delta']==0 or c['q']==0 or not 1<=c['min_area']<=c['max_area']<=n:error|=4
    result=compute(values,profile,case) if solve else dict(error=error)
    return dict(case=case,inputs=inputs,**result)


def write_group(output,name,profile,cases,results,reset_ids):
    directory=output/'fixtures'/name;directory.mkdir()
    selected=[results[c] for c in cases]
    input_lines=[str(len(selected))];expected_lines=[str(len(selected))]
    for result in selected:
        c=result['case'];v=c['config']
        input_lines.append('C '+' '.join(map(str,[c['sequence'],v['bright'],v['delta'],v['min_area'],v['max_area'],v['p'],v['q'],c['tag'],result['error']])))
        for i in result['inputs']:input_lines.append('I '+' '.join(map(str,i[1:5])))
        expected_lines.append('C '+' '.join(map(str,[c['sequence'],result['error'],c['tag']&((1<<profile['tag_w'])-1)])))
        expected_lines += ['O '+' '.join(map(str,r)) for r in result['records']]
    input_lines.append('END');expected_lines.append('END')
    (directory/'input.txt').write_text('\n'.join(input_lines)+'\n',encoding='ascii',newline='\n')
    (directory/'expected.txt').write_text('\n'.join(expected_lines)+'\n',encoding='ascii',newline='\n')
    dump(directory/'expected.json',dict(schema=1,group=name,profile=profile,reset_ids=reset_ids,cases=selected),exclusive=True)


def main():
    global pixels,compute,boundary_certificates
    if sys.flags.optimize:raise SystemExit('optimized Python forbidden')
    p=argparse.ArgumentParser();p.add_argument('--authorized-payload',action='store_true',required=True)
    p.add_argument('--output-root',type=Path,required=True);p.add_argument('--context',type=Path,required=True)
    p.add_argument('--context-sha256',required=True);p.add_argument('--lock-sha256',required=True);args=p.parse_args()
    context,author,plan=verify_context(args.context,args.context_sha256,args.lock_sha256)
    output=args.output_root.resolve();copies=Path(context['tested_source_root'])
    if output!=Path(context['output_root']) or ROOT!=copies/PACKAGE or Path.cwd().resolve()!=ROOT:raise SystemExit('copied payload/output/cwd required')
    expected=render_child(plan,args.context.resolve(),args.context_sha256,args.lock_sha256,copies,output)
    if sys.argv!=expected[2:]:raise SystemExit('exact approved payload arguments required')
    def copied_module(name):
        path=ROOT/(name+'.py')
        if sha(path)!=author['sources'][name+'.py']:raise RuntimeError('copied module changed')
        spec=importlib.util.spec_from_file_location('b30_c_copied_'+name,path)
        if spec is None or spec.loader is None:raise RuntimeError('copied module loader missing')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        if Path(module.__file__).resolve()!=path or sha(path)!=author['sources'][name+'.py']:raise RuntimeError('copied module origin changed')
        return module
    reference=copied_module('reference');validator=copied_module('validate')
    pixels,compute,boundary_certificates=reference.pixels,reference.compute,reference.boundary_certificates
    table=read(ROOT/'CASE_TABLE.json');profiles={p['id']:p for p in table['profiles']};results={}
    for case in table['main_cases']+table['fresh_cases']:
        results[case['id']]=materialize(case,profiles[case['profile']])
    certificates=boundary_certificates(results,table)
    (output/'fixtures').mkdir(exist_ok=False)
    for group in table['groups']:
        write_group(output,group['id'],profiles[group['profile']],group['cases'],results,group.get('reset_ids',[]))
        if group.get('reset_ids'):
            lines=[str(len(group['reset_ids']))]
            for rid in group['reset_ids']:
                probe=next(c for c in table['probe_cases'] if c['reset_id']==rid)
                entry=materialize(probe,profiles[group['profile']],solve=False);v=probe['config']
                lines.append('C '+' '.join(map(str,[probe['sequence'],v['bright'],v['delta'],v['min_area'],v['max_area'],v['p'],v['q'],probe['tag'],entry['error']])))
                lines += ['I '+' '.join(map(str,i[1:5])) for i in entry['inputs']]
            lines.append('END')
            (output/'fixtures'/group['id']/'probe.txt').write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')
    dump(output/'fixtures/CERTIFICATES.json',certificates,exclusive=True)
    validator.stored(output)
    fixtures={'fixtures/'+n:h for n,h in file_map(output/'fixtures').items()}
    if set(fixtures)!={'fixtures/'+n for n in fixture_names(plan,table)}:raise RuntimeError('exact34 payload fixtures')
    dump(output/'preparation/payload.json',dict(schema=2,status='FIXED_NUMERICAL_PREPARATION_COMPLETE',
        context_sha256=args.context_sha256,lock_sha256=args.lock_sha256,tested_source_sha256=context['tested_source_sha256'],
        fixture_sha256=fixtures,numerical_reference_calls=40,probe_numerical_reference_calls=0,
        main_frames=30,fresh_frames=10,probe_frames=10,groups=10,automatic_retry=False),exclusive=True)
    verify_context(args.context,args.context_sha256,args.lock_sha256)
    print('PREPARED profiles=5 main=30 fresh=10 reset=10 groups=10 NO_CARTESIAN')

if __name__=='__main__':main()
