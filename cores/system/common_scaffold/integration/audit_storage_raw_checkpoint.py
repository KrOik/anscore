"""Narrow RAW16/EEPROM/NOR frozen resource, peer and final checkpoint audit.

No synthesis, registration, board access or baseline seal changes. Run against a
new checkpoint, then repeat with --finalize after regression and ancestry pass.
"""
import argparse
import re
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, write_json
from audit_common_peripheral_checkpoint import sha, read, require

GROUPS = {
 'image/raw16_codec': ('synthesis.json', {'raw16_pack': 2, 'raw16_unpack': 2},
   ('evidence.json','protocol_evidence.json','roundtrip_evidence.json','parameter_evidence.json','control_evidence.json')),
 'peripherals/i2c_eeprom': ('synthesis.json', {'i2c_eeprom': 3},
   ('case_evidence.json','transaction_evidence.json','boundary_evidence.json','error_evidence.json','parameter_evidence.json','protocol_evidence.json')),
 'peripherals/spi_nor_flash': ('synthesis_evidence.json', {'spi_nor_flash': 2},
   ('simulation_evidence.json',)),
}
PEER_DIRS = ('image/raw16_peer','peripherals/i2c_eeprom_peer')
STATS = {'wires','ports','cells'}
BRAMS = {'SP','SPX9','DPB','DPX9B','SDPB','SDPX9B','ROM','ROMX9'}


def inside(base, name):
 path=(base/name).resolve()
 require(path.is_relative_to(base.resolve()), 'path escapes boundary: '+str(name))
 return path


def resources(cells):
 dspcell=lambda k:'MULT' in k or 'DSP' in k or k in {'ALU54D','PADD9','PADD18'}
 return (sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')) and not dspcell(k))+4*cells.get('RAM16SDP4',0),
         sum(v for k,v in cells.items() if dspcell(k)),2*sum(v for k,v in cells.items() if k in BRAMS))


def cell_table(text,module):
 marker='=== '+module+' ==='
 require(marker in text,'missing top primitive table: '+module)
 require('Executing CHECK pass' in text and 'Found and reported 0 problems.' in text,'full synthesis/check log missing')
 require(not re.search(r'^\s*ERROR:',text,re.M),'synthesis ERROR present')
 require(not re.search(r'Found and reported [1-9][0-9]* problems',text),'nonzero CHECK problems present')
 tail=text[text.rfind(marker)+len(marker):]
 require('===' not in tail,'unexpected module follows final top table')
 raw={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
 cells={k:v for k,v in raw.items() if k not in STATS}
 require(cells and any(k.startswith('LUT') for k in cells),'empty/nonmapped primitive table')
 require(all(re.fullmatch(r'[A-Z][A-Z0-9_]*',k) for k in cells),'unmapped/unknown statistics in primitive table')
 return cells


def bind(path,digest,reports):
 require(sha(path)==digest,'report/input hash mismatch: '+str(path))
 reports[str(path.resolve())]=digest


def profile_pass(obj,label):
 require(obj.get('status')=='PASS','report failed: '+label)
 rows=obj.get('profiles')
 require(isinstance(rows,list) and rows,'empty functional profiles: '+label)
 for row in rows:
  require(row.get('status','PASS')=='PASS','profile failed: '+label)
  if 'output' in row:require('PASS' in row['output'],'missing execution PASS: '+label)
 return rows



def final_report_map(base,obj,required):
 # Absent metadata means owner-relative; the sole explicit base is the
 # repository package. Never infer a base by whichever path happens to exist.
 if 'report_path_base' in obj:
  require(obj['report_path_base']=='cores/system/common_scaffold','unsupported final report_path_base')
  report_base=PACKAGE
 else:report_base=base
 mapping=obj.get('evidence',obj.get('reports'))
 require(isinstance(mapping,dict) and mapping,'owner final reports absent')
 resolved={}
 for name,digest in mapping.items():
  path=inside(report_base,name)
  require(path not in resolved,'duplicate resolved owner report')
  resolved[path]=digest
 require({inside(base,n) for n in required}<=resolved.keys(),'owner final report coverage incomplete')
 additional=obj.get('additional_reports',{})
 require(isinstance(additional,dict),'invalid additional_reports')
 for name,digest in additional.items():
  path=inside(report_base,name)
  require(path not in resolved or resolved[path]==digest,'conflicting additional report hash')
  resolved[path]=digest
 return resolved


def audit_owners(reports):
 frozen={};profiles=[];freezes={}
 for group,(synth_name,expected,evidence) in GROUPS.items():
  base=PACKAGE/group;freeze=read(base/'source_freeze.json');freezes[group]=freeze
  require(isinstance(freeze,dict) and freeze,'empty source freeze')
  for name,digest in freeze.items():
   path=inside(base,name);require(sha(path)==digest,'frozen input changed: '+str(path));frozen[str(path)]=digest
  reports[str(base/'source_freeze.json')]=sha(base/'source_freeze.json')
  rtl={n:h for n,h in freeze.items() if n.endswith(('.v','.sv'))}
  require(rtl,'RTL freeze missing')
  for name in (*evidence,synth_name):
   path=base/name;obj=read(path);require(obj.get('status')=='PASS','owner report failed: '+str(path))
   if group=='image/raw16_codec':require(obj.get('sources')==rtl,'RAW16 source binding: '+name)
   elif group=='peripherals/i2c_eeprom':require(obj.get('sources')==freeze,'EEPROM full source binding: '+name)
   elif name==synth_name:require(obj.get('rtl_sha256')==freeze['spi_nor_flash.sv'],'NOR synth binding')
   else:
    required=('spi_nor_flash.sv','nor_device_model.v','tb_spi_nor_flash.sv','run_tests.py')
    require(obj.get('source_sha256')=={n:freeze[n] for n in required},'NOR functional source binding')
   if name!=synth_name:profile_pass(obj,str(path))
   reports[str(path)]=sha(path)
  synth=read(base/synth_name);rows=synth.get('profiles');require(rows,'empty synthesis profiles');counts={};configs={}
  script=base/('run_synthesis.py' if group.endswith('spi_nor_flash') else 'synth.py')
  require(script.name in freeze and 'check -assert' in script.read_text(encoding='utf-8'),'frozen synthesis script lacks check -assert')
  for row in rows:
   module=row.get('module',next(iter(expected)));require(module in expected,'unexpected top')
   counts[module]=counts.get(module,0)+1
   if group=='image/raw16_codec':
    endian=row['big_endian'];require(endian in (0,1) and row['pixel_bits']==16,'RAW16 illegal synth config')
    log=base/f'synthesis_{module}_e{endian}.log';config=endian
   else:log=inside(base,row.get('log_filename',row.get('log','')));config=str(sorted(row.get('parameters',{}).items()))
   require(config not in configs.setdefault(module,set()),'duplicate synth config');configs[module].add(config)
   digest=row.get('report_sha256',row.get('log_sha256'));require(digest,'synthesis log hash absent');bind(log,digest,reports)
   cells=cell_table(log.read_text(encoding='utf-8'),module)
   claimed={k:v for k,v in row['cells'].items() if k not in STATS}
   require(cells==claimed,'actual primitive table mismatch: '+str(log))
   lut,dsp,bram=resources(cells)
   require((lut,dsp)==(row['lut_class'],row['dsp']),'LUT/DSP recount mismatch')
   if 'bram9' in row:require(bram==row['bram9'],'BRAM9 mismatch')
   else:require(group.endswith('spi_nor_flash') and row.get('bram')==sum(v for k,v in cells.items() if k in BRAMS),'physical BRAM count mismatch')
   require(lut<=15000 and dsp<=4 and bram<=46,'isolated resource budget exceeded')
   profiles.append(dict(group=group,module=module,configuration=config,lut_class=lut,dsp=dsp,bram9=bram,cells=cells,log_sha256=digest))
  require(counts==expected,'synthesis profile coverage mismatch: '+group)
  final=base/'final_validation.json';obj=read(final)
  require(obj.get('status')=='PASS' and obj.get('source_freeze_sha256')==sha(base/'source_freeze.json'),'owner final freeze mismatch')
  require(obj.get('sources',obj.get('frozen_inputs'))==freeze,'owner final input map mismatch')
  for report,digest in final_report_map(base,obj,(*evidence,synth_name)).items():bind(report,digest,reports)
  reports[str(final)]=sha(final)
 return frozen,freezes,profiles


def audit_peers(freezes,reports):
 peers={}
 raw=PACKAGE/'image/raw16_peer';path=raw/'peer_review_raw16.json';obj=read(path)
 require(obj['status']=='PASS' and obj['findings']==[],'RAW16 peer findings')
 require(obj['source_freeze_sha256']==sha(PACKAGE/'image/raw16_codec/source_freeze.json') and obj['owner_frozen_inputs']==freezes['image/raw16_codec'],'RAW16 peer freeze')
 bind(raw/'test_error_recovery.py',obj['reviewer_script_sha256'],reports)
 bind(raw/'recovery_evidence.json',obj['narrow_recovery_evidence_sha256'],reports)
 recovery=read(raw/'recovery_evidence.json');require(recovery['owner_frozen_inputs']==freezes['image/raw16_codec'],'RAW16 recovery inputs');require(len(profile_pass(recovery,'RAW16 recovery'))==4,'RAW16 recovery coverage')
 require(recovery['source_freeze_sha256']==obj['source_freeze_sha256'] and recovery['reviewer_script_sha256']==obj['reviewer_script_sha256'],'RAW16 recovery script/freeze')
 for row in recovery['profiles']:
  log=raw/(row['mode']+'_'+str(row['big_endian'])+'.log')
  require(log.read_text(encoding='utf-8').replace('\r','')==row['output'].replace('\r',''),'RAW16 recovery execution log mismatch')
  reports[str(log)]=sha(log)
 root=obj['root_independent_evidence'];base=inside(ROOT,root['path']);bind(base/'results.json',root['results_sha256'],reports)
 rootrun=read(base/'results.json');rtl={n:h for n,h in freezes['image/raw16_codec'].items() if n.endswith('.sv')}
 require(rootrun['status']=='PASS' and rootrun['sources']==rtl and rootrun['profiles']==4 and rootrun['exhaustive_values']==65536,'RAW16 independent root result')
 bind(PACKAGE/'integration/test_raw16_independent.py',root['reviewer_script_sha256'],reports)
 require(rootrun['reviewer_script_sha256']==root['reviewer_script_sha256'],'RAW16 independent script binding')
 for name,digest in root['logs_sha256'].items():bind(inside(base,name),digest,reports)
 require(len(root['logs_sha256'])==8,'RAW16 root log count')
 peers[str(path)]=sha(path)

 base=PACKAGE/'peripherals/i2c_eeprom_peer';path=base/'peer_review_eeprom.json';obj=read(path);freeze=freezes['peripherals/i2c_eeprom']
 require(obj['status']=='PASS' and obj.get('findings',[])==[] and obj['owner_source_freeze_sha256']==sha(PACKAGE/'peripherals/i2c_eeprom/source_freeze.json') and obj['inputs']==freeze,'EEPROM peer binding')
 bind(base/'test_scripted_pins.py',obj['peer_script_sha256'],reports);bind(base/'pin_evidence.json',obj['pin_evidence_sha256'],reports)
 run=read(base/'pin_evidence.json');require(run['inputs']==freeze and run['owner_source_freeze_sha256']==obj['owner_source_freeze_sha256'] and run['script_sha256']==obj['peer_script_sha256'],'EEPROM pin evidence binding')
 require(len(profile_pass(run,'EEPROM peer pins'))==4 and run['profiles']==obj['profiles'],'EEPROM peer profile coverage')
 for row in run['profiles']:bind(base/('simulation_'+row['label']+'.log'),row['simulation_sha256'],reports)
 require(len(obj['resources'])==3,'EEPROM peer resource coverage')
 for row in obj['resources']:bind(PACKAGE/'peripherals/i2c_eeprom'/row['log'],row['log_sha256'],reports)
 peers[str(path)]=sha(path)

 path=PACKAGE/'integration/peer_review_spi_nor.json';obj=read(path)
 require(obj['status']=='PASS' and obj['findings']==[] and obj['source_freeze_sha256']==sha(PACKAGE/'peripherals/spi_nor_flash/source_freeze.json') and obj['owner_frozen_inputs']==freezes['peripherals/spi_nor_flash'],'NOR peer binding')
 require(obj['peer_input_sha256'] and obj['independent_evidence'],'NOR independent evidence absent')
 for name,digest in obj['peer_input_sha256'].items():bind(inside(path.parent,name),digest,reports)
 for name,digest in obj['independent_evidence'].items():
  file=inside(PACKAGE,name);bind(file,digest,reports);run=read(file)
  require(run.get('rtl_sha256')==freezes['peripherals/spi_nor_flash']['spi_nor_flash.sv'],'NOR peer RTL binding')
  require(run.get('reviewer_script_sha256')==obj['peer_input_sha256']['test_spi_nor_independent.py'],'NOR peer script binding')
  require(len(profile_pass(run,'NOR independent'))==4,'NOR independent coverage')
  for row in run['profiles']:
   label=str(row['mode'])+'_'+str(row['divider'])
   for kind in ('compile','simulation'):
    log=file.parent/(kind+'_'+label+'.log');require(log.is_file(),'NOR independent execution log absent')
    if kind=='simulation':require('PASS NOR_INDEPENDENT' in log.read_text(encoding='utf-8'),'NOR independent log failed')
    reports[str(log)]=sha(log)
 peers[str(path)]=sha(path)
 for name,digest in peers.items():reports[name]=digest
 return peers


def audit(folder):
 require(folder.is_dir(),'checkpoint directory missing');reports={}
 frozen,freezes,profiles=audit_owners(reports);peers=audit_peers(freezes,reports)
 write_json(folder/'resource_audit.json',dict(status='PASS',owner_frozen_inputs=frozen,source_bound_reports=reports,isolated_profiles=profiles,scope='RAW16 two endian configurations per top, EEPROM complete controller+PHY three profiles, NOR two profiles; conservative BRAM9 recount; no route/board claim'))
 write_json(folder/'peer_review.json',dict(status='PASS',review_files_sha256=peers,findings=[]))
 return frozen,reports


def finalize(folder,frozen,reports):
 prefixes=set()
 for group in (*GROUPS,*PEER_DIRS):
  base=PACKAGE/group
  require(not any(p.suffix in {'.pyc','.vvp','.fs','.bin'} or p.name=='__pycache__' for p in base.rglob('*')),'batch binary/cache remains: '+group)
  for script in base.glob('*.py'):prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''',script.read_text(encoding='utf-8')))
 for name in ('test_raw16_independent.py','test_spi_nor_independent.py'):
  prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''',(PACKAGE/'integration'/name).read_text(encoding='utf-8')))
 require(prefixes,'no cleanup prefixes found')
 remaining=[str(p) for p in Path(tempfile.gettempdir()).iterdir() if any(p.name.startswith(n) for n in prefixes)]
 require(not remaining,'batch C-temp artifacts remain: '+str(remaining))
 write_json(folder/'cleanup_check.json',dict(status='PASS',checked_temp_prefixes=sorted(prefixes),remaining=[],scope='Storage/RAW16 batch only; existing baseline cleanup exceptions preserved'))
 for name,digest in {**read(folder/'tested_input_sha256.json'),**frozen,**reports}.items():require(sha(Path(name))==digest,'final hash changed: '+name)
 for name in ('checkpoint_audit.json','ancestry_check.json'):require(read(folder/name)['status']=='PASS','checkpoint/ancestry failed')
 result=read(folder/'results.json');require(result['results'] and result['integrations'],'empty regression results')
 require(all(row['status']=='PASS' for row in result['results']+result['integrations']),'regression failed')
 require(result['source_bundle_compile']['status']==result['input_stability']['status']=='PASS','bundle/stability failed')
 names=('results.json','tested_input_sha256.json','checkpoint_audit.json','ancestry_check.json','resource_audit.json','peer_review.json','cleanup_check.json')
 write_json(folder/'final_readonly_check.json',dict(status='PASS',board_tested=False,tracked_inputs_checked=len(read(folder/'tested_input_sha256.json')),owner_frozen_inputs_checked=len(frozen),sealed_reports={n:sha(folder/n) for n in names},additional_input_sha256={str(p):sha(p) for p in (Path(__file__).resolve(),PACKAGE/'IMAGE_EXTENSIONS.md')},scope='Read-only storage/RAW16 checkpoint signoff; no board or routed timing claim; baseline137 seal unchanged'))


if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('checkpoint',type=Path);parser.add_argument('--finalize',action='store_true');args=parser.parse_args()
 frozen,reports=audit(args.checkpoint.resolve())
 if args.finalize:finalize(args.checkpoint.resolve(),frozen,reports)
 print('STORAGE_RAW_AUDIT_PASS',len(frozen))
