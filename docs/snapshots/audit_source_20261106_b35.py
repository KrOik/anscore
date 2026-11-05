"""SPDX-License-Identifier: Apache-2.0. B35 source-only additive snapshot audit.

Run from any directory. Does not launch HDL, synthesis or inherited regression.
Reads inherited declarations from committed B34, never mutable legacy checkout.
"""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='bbb761eb39c475ed52c7c42414a724e3f1ba6cae'
PARENT='docs/snapshots/source_20261106_b34.json'
OLD_AUDIT='docs/snapshots/source_20261106_b34_structure.json'
NEW=[('cores/communication/moldudp64_itch_rx','moldudp64_itch_rx','itch_order_events','itch_order_events.sv'),
     ('cores/signal_processing/occupied_spectral_bandwidth','occupied_spectral_bandwidth','iq_occupied_bandwidth','iq_occupied_bandwidth.sv'),
     ('cores/image_processing/fragment_rgb_depth_store','fragment_rgb_depth_store','triangle_depth64','triangle_depth64.sv'),
     ('cores/acceleration/price_level_ioc_matcher','price_level_ioc_matcher','quote_ioc16','quote_ioc16.sv')]
def sha(data):return hashlib.sha256(data).hexdigest()
def hfile(path):return sha(path.read_bytes())
def git(*args):return subprocess.run(['git',*args],cwd=ROOT,check=True,capture_output=True,timeout=20).stdout
def write(path,data):(ROOT/path).write_bytes((json.dumps(data,indent=2)+'\n').encode())
def package_files(path):
    return {f.relative_to(path).as_posix():hfile(f)for f in sorted(path.rglob('*'))
      if f.is_file()and not set(f.relative_to(path).parts)&{'.work','.build','__pycache__'}}
def main():
    raw_parent=git('show',BASE+':'+PARENT);parent=json.loads(raw_parent)
    old=json.loads(git('show',BASE+':'+OLD_AUDIT));assert len(parent['packages'])==136
    snapshot=copy.deepcopy(parent);sources=set(old['canonical_source_paths']);new_summary=[];new_files={}
    total_checks=total_sims=0
    for path,top,example,example_file in NEW:
        p=ROOT/path;d=json.loads((p/'B35_DELIVERY.json').read_bytes());files=package_files(p)
        assert files['.gitattributes']==sha(b'* -text\n'),path
        assert 'HW_UNVERIFIED'in d.get('maturity',d.get('status',[]))or d.get('hardware')=='HW_UNVERIFIED',path
        receipt=d.get('receipt',d.get('qualification'))
        assert receipt and hfile(p/receipt)==d.get('receipt_sha256',d.get('qualification_sha256')),path
        r=json.loads((p/receipt).read_bytes());assert r['status']=='PASS',path
        executable=d.get('current_executable_sources',r['source_sha256'])
        for name,digest in executable.items():assert hfile(p/name)==digest,(path,name)
        for mapping in d.get('source_mapping',[]):
            assert hfile(p/mapping['source'])==mapping['sha256']==hfile(p/mapping['exact_checked_copy']),(path,mapping['source'])
        for name,digest in r['source_sha256'].items():
            archived=r.get('archived_sources',{}).get(name)
            if archived:assert hfile(p/archived)==digest,(path,name)
            elif name in r.get('exact_checked_copies',{}):
                assert hfile((p/receipt).parent/r['exact_checked_copies'][name])==digest,(path,name)
            else:assert hfile((p/receipt).parent/'sources'/name.replace('../','parent/'))==digest,(path,name)
        for field in('files','metadata_sha256','package_files','documentation_sha256'):
            value=d.get(field,{})
            if isinstance(value,dict):
                for name,digest in value.items():assert files[name]==digest,(path,name)
        records=r.get('checks',r.get('records',[]))
        checks=d.get('effective_finite_checks',len(records))
        sims=d.get('successful_simulations',sum(c['name'].startswith('sim_')for c in records))
        total_checks+=checks;total_sims+=sims
        # Report names differ between independent finite runners; their bridge
        # supplies the count. Every selected child must be a real PASS record.
        assert len(records)==checks and all(c['status']=='PASS'for c in records),path
        for record in records:
            for stream in('stdout','stderr'):
                assert hfile((p/receipt).parent/(record['name']+'.'+stream+'.txt'))==record[stream+'_sha256'],(path,record['name'],stream)
        report_dir=(p/receipt).parent
        for index,profile in enumerate(r['profiles']):
            if 'vector_sha256'in profile:
                assert hfile(report_dir/profile['vector'])==profile['vector_sha256'],(path,profile)
            elif isinstance(profile.get('vectors_sha256'),dict):
                for name,digest in profile['vectors_sha256'].items():
                    assert hfile(report_dir/profile['name']/name)==digest,(path,profile['name'],name)
            else:
                assert hfile(report_dir/('vectors%d.txt'%index))==profile['vectors_sha256'],(path,index)
        for name,digest in r.get('integration_vectors_sha256',{}).items():
            assert hfile(report_dir/'integration'/name)==digest,(path,'integration',name)
        risk=d.get('architecture_risk',d.get('risk','UNKNOWN'))
        root_lists=['files.f','example/files.f'];package_source_lists={}
        for fl in root_lists:
            resolved=[]
            for line in(p/fl).read_text().splitlines():
                line=line.split('#',1)[0].strip()
                if not line:continue
                assert not line.startswith('-'),(path,line)
                source=(p/line).resolve();canonical=source.relative_to(ROOT).as_posix()
                assert source.is_file()and source.suffix.lower()in('.sv','.v'),canonical
                assert canonical in sources or canonical.startswith(path+'/'),canonical
                assert canonical not in resolved,(path,fl,canonical)
                resolved.append(canonical);sources.add(canonical)
            package_source_lists[fl]=resolved
        entry=dict(path=path,top=top,baseline_commit=BASE,evidence='B35_DELIVERY.json',
          evidence_kind='explicit_finite_rules',hardware_status='HW_UNVERIFIED',
          architecture_risk=risk,additional_source_lists=['example/files.f'],
          examples=[dict(file='example/'+example_file,top=example)],sha256=files)
        snapshot['packages'].append(entry)
        new_summary.append(dict(path=path,files=len(files),effective_checks=checks,
          successful_simulations=sims,architecture_risk=risk,source_lists=package_source_lists))
        new_files.update({path+'/'+name:digest for name,digest in files.items()})
    assert snapshot['packages'][:136]==parent['packages']
    # Batch-query all old HDL content at immutable BASE in one finite subprocess.
    old_paths=sorted(set(old['canonical_source_paths']))
    query=''.join(BASE+':'+p+'\n'for p in old_paths).encode()
    packed=subprocess.run(['git','cat-file','--batch'],input=query,cwd=ROOT,capture_output=True,check=True,timeout=20).stdout
    contents={};offset=0
    for path in old_paths:
        end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob'
        size=int(header[2]);contents[path]=packed[end+1:end+1+size];offset=end+size+2
    for package in new_summary:
        for paths in package['source_lists'].values():
            for path in paths:
                if path in contents:assert hfile(ROOT/path)==sha(contents[path]),('shared_source_changed',path)
    declarations={}
    for path in sorted(sources):
        raw=contents[path]if path in contents else(ROOT/path).read_bytes()
        code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',raw,flags=re.S)
        for name in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):
            declarations.setdefault(name.decode(),[]).append(path)
    collisions={k:v for k,v in declarations.items()if len(v)>1};assert not collisions,collisions
    snapshot.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,
      source_freeze=f'B35 cumulative140 packages; strict market-data packet events, discrete occupied bandwidth, RGB/depth fragments, L2 IOC matching. {total_checks} finite PASS children/{total_sims} successful simulations. No synthesis/PnR/STA/board/merged compile/inherited regression. Goal active.',
      previous_snapshot=PARENT,parent_snapshot=dict(path=PARENT,sha256=sha(raw_parent),
        worktree_sha256=hfile(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),batch_support_file_additions={})
    scope='Additive source-list closure, exact delivered/evidence hashes, inherited declarations from committed B34. No merged compile or inherited qualification replay.'
    audit=dict(schema='anscore-b35-static-audit-v1',status='PASS',baseline_commit=BASE,packages=140,
      parent_snapshot_sha256=sha(raw_parent),parent_snapshot_worktree_sha256=hfile(ROOT/PARENT),
      inherited_package_objects_exact=136,new_packages=new_summary,new_package_files=len(new_files),
      effective_finite_checks=total_checks,successful_finite_simulations=total_sims,
      source_files=len(sources),module_declarations=sum(map(len,declarations.values())),
      canonical_source_paths=sorted(sources),new_support_sources=[],unresolved_module_collisions=collisions,
      qualification_limit='Static additive integrity only; finite package evidence is explicit in each delivery bridge.',
      scope=scope,combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    write('docs/snapshots/source_20261106_b35.json',snapshot)
    write('docs/snapshots/source_20261106_b35_structure.json',audit)
    print(json.dumps({k:audit[k]for k in('status','packages','new_package_files','effective_finite_checks','successful_finite_simulations','source_files','module_declarations')}))
if __name__=='__main__':main()
