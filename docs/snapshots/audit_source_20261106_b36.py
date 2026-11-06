"""SPDX-License-Identifier: Apache-2.0. B36 source-only additive snapshot audit.

Run from any directory. Does not launch HDL, synthesis or inherited regression.
Reads inherited declarations from committed B35, never mutable legacy checkout.
"""
from pathlib import Path
import copy,hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[2]
BASE='8ba6835fe51ad285b926cd24e3ba4d172aefce26'
PARENT='docs/snapshots/source_20261106_b35.json'
OLD_AUDIT='docs/snapshots/source_20261106_b35_structure.json'
NEW=[('cores/storage/itch_order_state','itch_order_state','itch_receiver_state8','itch_receiver_state8.sv'),
     ('cores/signal_processing/paired_spectral_coherence','paired_spectral_coherence','dual_fft_coherence64','dual_fft_coherence64.sv'),
     ('cores/image_processing/three_field_deinterlace','three_field_deinterlace','deinterlace_rgb_preview','deinterlace_rgb_preview.sv'),
     ('cores/acceleration/int4_key_attention','int4_key_attention','two_token_attention','two_token_attention.sv')]
SUPPORT=['cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv',
 'cores/system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v',
 'cores/system/ip_series/src/ips_softmax_fixed.v',
 'cores/acceleration/integer_divider/rtl/integer_divider.v']
DIV_ALIAS='cores/image_processing/grayscale_anisotropic_diffusion/rtl/deps/integer_divider.v'
DIV_CANONICAL='cores/acceleration/integer_divider/rtl/integer_divider.v'
DIV_ATTRIBUTES='cores/acceleration/integer_divider/rtl/.gitattributes'

def sha(data):return hashlib.sha256(data).hexdigest()
def hfile(path):return sha(path.read_bytes())
def reference(package,name):
    # Independent delivery schemas use package-relative or repository-relative
    # identifiers. Never double-prefix a repository path.
    return ROOT/name if name.replace('\\','/').startswith('cores/') else package/name
def git(*args):return subprocess.run(['git',*args],cwd=ROOT,check=True,capture_output=True,timeout=20).stdout
def write(path,data):(ROOT/path).write_bytes((json.dumps(data,indent=2)+'\n').encode())
def package_files(path):
    return {f.relative_to(path).as_posix():hfile(f)for f in sorted(path.rglob('*'))
      if f.is_file()and not set(f.relative_to(path).parts)&{'.work','.build','__pycache__'}}
def main():
    raw_parent=git('show',BASE+':'+PARENT);parent=json.loads(raw_parent)
    old=json.loads(git('show',BASE+':'+OLD_AUDIT));assert len(parent['packages'])==140
    snapshot=copy.deepcopy(parent);sources=set(old['canonical_source_paths']);sources.remove(DIV_ALIAS);sources.update(SUPPORT);new_summary=[];new_files={}
    total_checks=total_sims=0
    for path,top,example,example_file in NEW:
        p=ROOT/path;d=json.loads((p/'B36_DELIVERY.json').read_bytes());files=package_files(p)
        assert files['.gitattributes']==sha(b'* -text\n'),path
        assert 'HW_UNVERIFIED'in d.get('maturity',d.get('status',[]))or d.get('hardware')=='HW_UNVERIFIED',path
        receipt=d.get('receipt',d.get('qualification'))
        receipt_path=reference(p,receipt)
        assert receipt and hfile(receipt_path)==d.get('receipt_sha256',d.get('qualification_sha256')),path
        r=json.loads(receipt_path.read_bytes());assert r['status']=='PASS',path
        executable=d.get('current_executable_sources',r['source_sha256'])
        for name,digest in executable.items():assert hfile(reference(p,name))==digest,(path,name)
        for mapping in d.get('source_mapping',[]):
            assert hfile(p/mapping['source'])==mapping['sha256']==hfile(p/mapping['exact_checked_copy']),(path,mapping['source'])
        for name,digest in r['source_sha256'].items():
            archived=r.get('archived_sources',{}).get(name)
            if archived:assert hfile(reference(p,archived))==digest,(path,name)
            elif name in r.get('exact_checked_copies',{}):
                assert hfile(receipt_path.parent/r['exact_checked_copies'][name])==digest,(path,name)
            else:assert hfile(receipt_path.parent/'sources'/name.replace('../','parent/'))==digest,(path,name)
        for field in('files','metadata_sha256','metadata_hashes','package_files','package_sha256','documentation_sha256',
                     'source_archive','numerical_vectors','raw_streams'):
            value=d.get(field,{})
            if isinstance(value,dict):
                for name,digest in value.items():assert hfile(reference(p,name))==digest,(path,name)
        if d.get('plan'):assert hfile(reference(p,d['plan']))==d['plan_sha256'],path
        records=r.get('checks',r.get('records',[]))
        checks=d.get('effective_finite_checks',len(records))
        sims=d.get('successful_simulations',sum(c['name'].startswith('sim_')for c in records))
        total_checks+=checks;total_sims+=sims
        # Report names differ between independent finite runners; their bridge
        # supplies the count. Every selected child must be a real PASS record.
        assert len(records)==checks and all(c['status']=='PASS'for c in records),path
        for record in records:
            for stream in('stdout','stderr'):
                assert hfile(receipt_path.parent/(record['name']+'.'+stream+'.txt'))==record[stream+'_sha256'],(path,record['name'],stream)
        report_dir=receipt_path.parent
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
        risk=d.get('architecture_risk',d.get('resource_risk',d.get('risk','UNKNOWN')))
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
        entry=dict(path=path,top=top,baseline_commit=BASE,evidence='B36_DELIVERY.json',
          evidence_kind='explicit_finite_rules',hardware_status='HW_UNVERIFIED',
          architecture_risk=risk,additional_source_lists=['example/files.f'],
          examples=[dict(file='example/'+example_file,top=example)],sha256=files)
        snapshot['packages'].append(entry)
        new_summary.append(dict(path=path,files=len(files),effective_checks=checks,
          successful_simulations=sims,architecture_risk=risk,source_lists=package_source_lists))
        new_files.update({path+'/'+name:digest for name,digest in files.items()})
    assert snapshot['packages'][:140]==parent['packages']
    # Batch-query all old HDL content at immutable BASE in one finite subprocess.
    old_paths=sorted(set(old['canonical_source_paths'])|(set(SUPPORT)-{DIV_CANONICAL}))
    query=''.join(BASE+':'+p+'\n'for p in old_paths).encode()
    packed=subprocess.run(['git','cat-file','--batch'],input=query,cwd=ROOT,capture_output=True,check=True,timeout=20).stdout
    contents={};offset=0
    for path in old_paths:
        end=packed.index(b'\n',offset);header=packed[offset:end].split();assert header[1]==b'blob',(path,header)
        size=int(header[2]);contents[path]=packed[end+1:end+1+size];offset=end+size+2
    # The original divider path existed only in the legacy checkout. Its bytes
    # are proven by the already committed package-local alias and are exported
    # at the original calling path without importing the unrelated legacy tree.
    contents[DIV_CANONICAL]=contents[DIV_ALIAS]
    for package in new_summary:
        for paths in package['source_lists'].values():
            for path in paths:
                if path in contents:assert hfile(ROOT/path)==sha(contents[path]),('shared_source_changed',path)
    assert contents[DIV_ALIAS]==contents[DIV_CANONICAL]
    additions={}
    for path in SUPPORT:
        digest=sha(contents[path]);assert digest==hfile(ROOT/path)
        origin=DIV_ALIAS if path==DIV_CANONICAL else path
        oid=git('rev-parse',BASE+':'+origin).decode().strip()
        additions[path]=dict(sha256=digest,baseline_blob_oid=oid,baseline_source_path=origin,
          reason=('Exact-byte original-path export of committed package-local dependency' if path==DIV_CANONICAL else
                  'Existing committed unmodified dependency added to canonical offline export closure'))
        snapshot['support_files'][path]=digest
        snapshot['support_file_additions'][path]=additions[path]
    attr_bytes=(ROOT/DIV_ATTRIBUTES).read_bytes()
    assert attr_bytes==b'/integer_divider.v -text\n'
    additions[DIV_ATTRIBUTES]=dict(sha256=sha(attr_bytes),
      reason='Scoped attribute preserves exact CRLF dependency bytes at the original path')
    snapshot['support_files'][DIV_ATTRIBUTES]=sha(attr_bytes)
    snapshot['support_file_additions'][DIV_ATTRIBUTES]=additions[DIV_ATTRIBUTES]
    alias=dict(canonical=DIV_CANONICAL,alias=DIV_ALIAS,sha256=sha(contents[DIV_CANONICAL]),
      bytes=len(contents[DIV_CANONICAL]),module='integer_divider',
      combined_source_rule='Use canonical path once; inherited package-local copy remains available for standalone files.f.',new_capability=False)
    snapshot['exact_byte_dependency_aliases'].append(alias)
    declarations={}
    for path in sorted(sources):
        raw=contents[path]if path in contents else(ROOT/path).read_bytes()
        code=re.sub(rb'/\*.*?\*/|//[^\n]*',b'',raw,flags=re.S)
        for name in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)',code):
            declarations.setdefault(name.decode(),[]).append(path)
    collisions={k:v for k,v in declarations.items()if len(v)>1};assert not collisions,collisions
    snapshot.update(date='2026-11-06',baseline_commit=BASE,batch_baseline_commit=BASE,
      source_freeze=f'B36 cumulative144 packages; persistent ITCH orders, paired spectral coherence, three-field deinterlacing and INT4-key attention. {total_checks} finite PASS children/{total_sims} successful simulations. No synthesis/PnR/STA/board/merged compile/inherited regression. Goal active.',
      previous_snapshot=PARENT,parent_snapshot=dict(path=PARENT,sha256=sha(raw_parent),
        worktree_sha256=hfile(ROOT/PARENT),hash_kind='committed_git_blob',commit=BASE),batch_support_file_additions=additions)
    scope='Additive source-list closure, exact delivered/evidence hashes, inherited declarations from committed B35. No merged compile or inherited qualification replay.'
    audit=dict(schema='anscore-b36-static-audit-v1',status='PASS',baseline_commit=BASE,packages=144,
      parent_snapshot_sha256=sha(raw_parent),parent_snapshot_worktree_sha256=hfile(ROOT/PARENT),
      inherited_package_objects_exact=140,new_packages=new_summary,new_package_files=len(new_files),
      effective_finite_checks=total_checks,successful_finite_simulations=total_sims,
      source_files=len(sources),module_declarations=sum(map(len,declarations.values())),
      canonical_source_paths=sorted(sources),new_support_sources=SUPPORT,exact_byte_canonical_relocations=[alias],unresolved_module_collisions=collisions,
      qualification_limit='Static additive integrity only; finite package evidence is explicit in each delivery bridge.',
      scope=scope,combined_compile='NOT_RUN',inherited_checker='NOT_RUN',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    write('docs/snapshots/source_20261106_b36.json',snapshot)
    write('docs/snapshots/source_20261106_b36_structure.json',audit)
    print(json.dumps({k:audit[k]for k in('status','packages','new_package_files','effective_finite_checks','successful_finite_simulations','source_files','module_declarations')}))
if __name__=='__main__':main()
