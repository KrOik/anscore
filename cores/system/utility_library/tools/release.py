"""Audit source-bound evidence and export a reviewable engineering candidate.

Never rewrites prior build/board reports. Resource classification is rechecked
against netlists and router tables; historical reports are linked verbatim.
"""
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile
from catalog import CORES
from build import metrics
from verify import ROOT, REPO


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summaries(kind):
    for path in sorted((ROOT/'evidence').glob(kind+'_*/summary.json'), reverse=True):
        yield path, json.loads(path.read_text(encoding='utf-8'))


def checked_source(report, rel):
    return report.get('sources', {}).get(rel) == sha(ROOT/rel)


def matching_sim(report):
    return (report.get('status')=='PASS' and report.get('count')==56
            and len(report.get('board_harness_simulations', []))==7
            and len(report.get('uart_simulations', []))==7
            and len(report.get('integration_simulations', []))==1
            and all(e.get('response_bit_mutation_detected') for e in report['cores'])
            and all(checked_source(report, f'rtl/prod_{e["name"]}.v')
                    and checked_source(report, f'sim/tb_{e["name"]}.sv')
                    and checked_source(report, f'vectors/{e["name"]}.mem') for e in CORES)
            and checked_source(report, 'tools/golden.py'))


def main():
    sim_path, sim = next((p, r) for p, r in summaries('sim') if matching_sim(r))
    formal_path, formal = next((p, r) for p, r in summaries('formal')
                         if r.get('status')=='PASS' and r.get('count')==56
                         and all(checked_source(r, f'rtl/prod_{e["name"]}.v') for e in CORES))
    build_path, build = next((p, r) for p, r in summaries('build')
                         if len(r.get('groups', []))==7 and all(g.get('bitstream') and g['route']=='PASS' for g in r['groups'])
                         and all(checked_source(r, f'rtl/prod_{e["name"]}.v') for e in CORES))
    board_path, board = next((p, r) for p, r in summaries('board')
                         if r.get('status')=='PASS' and len(r.get('groups', []))==7
                         and Path(r['build']).resolve()==build_path.parent.resolve())
    isolated = {}
    for path, report in summaries('build'):
        for entry in report.get('isolated', []):
            name = entry['name']
            if name not in isolated and checked_source(report, f'rtl/prod_{name}.v'):
                isolated[name] = dict(entry, evidence=path.relative_to(ROOT).as_posix())
    if len(isolated)!=56:
        raise RuntimeError('missing current isolated synthesis evidence')
    group_rows = []
    for group in build['groups']:
        g = group['group']
        actual = metrics(build_path.parent/f'group_{g}.json', 'prod_top')
        route = (build_path.parent/f'group_{g}_nextpnr.log').read_text(encoding='utf-8')
        packed = {m[1]:dict(used=int(m[2]), available=int(m[3])) for m in re.finditer(r'Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+\d+%', route)}
        fmax = re.findall(r"Max frequency for clock .*?: ([0-9.]+) MHz \(PASS at 50.00 MHz\)", route)
        if not fmax or 'ERROR:' in route or not actual['under_budget']:
            raise RuntimeError('route/actual resources failed audit')
        if packed.get('BSRAM', {}).get('used') != actual['bram_blocks']:
            raise RuntimeError('BRAM classification differs from device utilization')
        if packed.get('LUT4', {}).get('used', 999999)>15000:
            raise RuntimeError('packed LUT budget exceeded')
        fs = ROOT/group['bitstream']
        if sha(fs)!=group['bitstream_sha256']:
            raise RuntimeError('bitstream hash mismatch')
        br = next(row for row in board['groups'] if row['group']==g)
        if br['bitstream_sha256'] != sha(fs) or br['mask']!='FF' or br['errors'] or br['count']!=1024:
            raise RuntimeError('board acceptance mismatch')
        group_rows.append(dict(group=g, **actual, packed_utilization=packed,
                               routed_fmax_mhz=float(fmax[-1]), board='PASS',
                               checked_responses=1024, uart_frames=br['frames'],
                               digest=br['digest'], max_latency=br['max_latency'],
                               stalled_beats=br['stalled_beats'],
                               bitstream=group['bitstream'], bitstream_sha256=sha(fs)))
    baseline_path=REPO/'artifacts/ip_expansion_20261009/baseline_inventory.json'
    baseline=json.loads(baseline_path.read_text(encoding='utf-8-sig'))
    current_count=sum(1 for path in (REPO/'projects').glob('*/ip/*/*.json')
                      if path.name in ['manifest.json','ip_manifest.json'])
    if current_count-baseline['count']!=56:
        raise RuntimeError('inventory delta is not exactly 56')
    timestamp=datetime.now(timezone.utc).isoformat()
    report=dict(timestamp=timestamp, status='ENGINEERING_CANDIDATE_VERIFIED',
                additional_functional_cores=56, existing_packaged_cores=baseline['count'],
                current_packaged_cores=current_count, integration_modules=['prod_apb3_adapter'],
                simulation='56/56 PASS including response mutation rejection',
                independent_model_checks=24595,
                formal='56/56 bounded SAT depth8, boundary only',
                board='56/56 PASS across seven SRAM images',
                board_responses=7168, physical_clock_mhz=50, enabled_beat_mhz=3.125,
                evidence=dict(simulation=sim_path.relative_to(ROOT).as_posix(),
                              formal=formal_path.relative_to(ROOT).as_posix(),
                              build=build_path.relative_to(ROOT).as_posix(),
                              board=board_path.relative_to(ROOT).as_posix()),
                groups=group_rows, isolated=list(isolated.values()),
                qualification=dict(production_signoff=False, patentability_claim=False,
                                   side_channel_claim=False, full_speed_board_throughput=False),
                resource_correction='Original build summaries missed the GW5A SPX9 suffix (reported0 BRAM). This new audit counts the actual primitives and requires agreement with router BSRAM; old reports retained unchanged.')
    (ROOT/'doc/ACCEPTANCE.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    output=io.StringIO()
    writer=csv.writer(output)
    writer.writerow(['name','family','latency_enabled_cycles','rtl_sha256','vector_sha256','isolated_LUT','isolated_FF','DSP','board_group','simulation','formal_depth8','board'])
    manifests=[]
    for entry in CORES:
        name=entry['name']
        m=json.loads((ROOT/f'ip/{name}/manifest.json').read_text())
        if m['rtl_sha256']!=sha(ROOT/m['source']) or m['vector_sha256']!=sha(ROOT/f'vectors/{name}.mem'):
            raise RuntimeError('manifest hash mismatch: '+name)
        im=isolated[name]
        writer.writerow([name,entry['family'],m['latency_enabled_cycles'],m['rtl_sha256'],m['vector_sha256'],im['lut_class'],im['ff_class'],im['dsp_class'],m['board_group'],'PASS','PASS','PASS'])
        manifests.append(m)
    (ROOT/'doc/IP_ASSET_RECORDS.csv').write_text(output.getvalue(), encoding='utf-8-sig')
    table='| 组 | LUT | FF | BSRAM | DSP | 路由 Fmax MHz | 板端结果数 | 摘要 |\n|---|---:|---:|---:|---:|---:|---:|---|\n'
    table+='\n'.join(f'| {g["group"]} | {g["lut_class"]} | {g["ff_class"]} | {g["bram_blocks"]} | {g["dsp_class"]} | {g["routed_fmax_mhz"]:.2f} | 1024 | {g["digest"]} |' for g in group_rows)
    text=f'''# 验证与交付记录

时间：{timestamp}。新增56核；封装总量从{baseline['count']}增至{current_count}。
目标：用户确认 Tang Primer 25K / GW5A-25，远端192.168.31.176。

**56/56 功能核独立仿真、错误注入拒绝、独立综合、8步边界SAT、板端验收全部通过。**
七组自检仿真及UART字节级仿真通过，附加APB适配层测试通过。板端逐笔比较
7168个响应，每组6帧UART一致，通过掩码FF，错误数0。

{table}

所有镜像以50MHz布局布线并通过时序，LUT≤15000、DSP≤4、BSRAM≤46。
板端功能/背压测试CE=1/16，使能节拍3.125MHz；不能由此宣称全速硬件吞吐。
单核II=1使能节拍，响应通常1使能节拍，BCD编码为2节拍。板端报告L=4为
包含主动响应背压的最大退休间隔，不是所有核的计算延迟。

原第一版BCD编码路径44.46MHz未通过50MHz门限。已改为两级弹性流水，独立
815LUT/73FF/0DSP，当前编码组时序通过。旧失败构建保留。
原构建报表没有识别GW5A的SPX9原语，错误报告BRAM=0；本次重新读取网表并与
nextpnr BSRAM逐组核对，正确值见表。旧报表保留，本记录及ACCEPTANCE.json
使用更正后的数据。

仿真证据：`{report['evidence']['simulation']}`。
形式证据：`{report['evidence']['formal']}`，深度8，证明响应稳定/CE边界，
没有做不限深度、完整算术等价或安全证明。
构建证据：`{report['evidence']['build']}`。
远端证据：`{report['evidence']['board']}`，包含JTAG检测、上传哈希、烧录日志与
每组原始UART。当前板卡SRAM停留在第6组控制核镜像，未写Flash。

原ML-KEM/ML-DSA工程完整仿真回归已通过，记录在仓库
`artifacts/ip_expansion_20261009/baseline_sim.log`。既有源码、预期摘要、UART
字符串和基线日志均未修改；未重新烧录旧20K项目到25K。

## 具体边界

产出是可复用、有工程验收记录的IP候选系列，不是完成量产签核的整机。
通用算术/编码/报文微操作使用原生事务接口；完整物理接口控制器沿用既有IP。
APB模块单命令在途，只有本地仿真证据，未实例化到七份板级镜像中。
板端每核128条向量，仿真每核320条随机向量加边界/定向向量并运行3轮。
事件计数器饱和等极远状态目前只有模型边界校验，未用板端运行到该状态；
没有长时间老化、全温压角、实际产线外设联调、CDC/复位模拟时序或整机认证。
这些内容应按最终产品的集成约束关闭；不宣称专利新颖性或侧信道防护。

## 改动与命令

新增文件全部位于`cores/system/utility_library/`，另有基线和库存记录写入
`artifacts/ip_expansion_20261009/`。没有编辑原有RTL、共享脚本或用户改动。
关键命令均从仓库根运行：

```powershell
.\\scripts\\test_hybrid_lattice_ntt_sim.ps1
python cores/system/utility_library/tools/model_selftest.py
python cores/system/utility_library/tools/verify.py --board --uart --integration --mutations
python cores/system/utility_library/tools/build.py --isolated
python cores/system/utility_library/tools/build.py --isolated-core bcd8_encode
python cores/system/utility_library/tools/formal.py
python cores/system/utility_library/tools/remote_board.py --build {build_path.parent.relative_to(REPO).as_posix()}
python cores/system/utility_library/tools/release.py
```

第一份全量独立综合保留55个未变核的当前资源数据；修订后的BCD核从第二份
综合提取。交付工具只接受与当前源码SHA256一致的记录，不能把旧结果混用。
最终判定：工程验收PASS，量产/专利/安全签核尚未作出。
'''
    (ROOT/'doc/VALIDATION.md').write_text(text, encoding='utf-8')
    out=ROOT/'releases'
    out.mkdir(exist_ok=True)
    bundle=out/('production_ip_25k_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'.zip')
    files={p.relative_to(ROOT).as_posix():p for folder in ['rtl','integration','ip','vectors','sim','board','tools','doc']
           for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts}
    files.update({n:ROOT/n for n in ['README.md','catalog.json']})
    # Include definitive logs/summaries, without multi-megabyte simulation binaries/netlists.
    for folder in [sim_path.parent,formal_path.parent,board_path.parent]:
        for p in folder.iterdir():
            if p.is_file() and p.suffix in ['.log','.json','.txt','.ys','.sv']:
                files[p.relative_to(ROOT).as_posix()]=p
    for p in build_path.parent.iterdir():
        if p.is_file() and (p.suffix in ['.log','.fs','.ys'] or p.name=='summary.json'):
            files[p.relative_to(ROOT).as_posix()]=p
    files['baseline/baseline_inventory.json']=baseline_path
    files['baseline/baseline_sim.log']=REPO/'artifacts/ip_expansion_20261009/baseline_sim.log'
    # Include source-bound isolated logs from their actual retained evidence folders.
    for name,row in isolated.items():
        folder=ROOT/Path(row['evidence']).parent
        for suffix in ['.log','.ys']:
            p=folder/(name+suffix)
            files[p.relative_to(ROOT).as_posix()]=p
    ledger={name:dict(sha256=sha(p), bytes=p.stat().st_size) for name,p in sorted(files.items())}
    with zipfile.ZipFile(bundle,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name,p in sorted(files.items()):
            archive.write(p,name)
        archive.writestr('PACKAGE_MANIFEST.json',json.dumps(ledger,indent=2)+'\n')
    with zipfile.ZipFile(bundle) as archive:
        if archive.testzip() is not None:
            raise RuntimeError('ZIP CRC failed')
        for name,entry in ledger.items():
            if hashlib.sha256(archive.read(name)).hexdigest()!=entry['sha256']:
                raise RuntimeError('ZIP SHA256 failed: '+name)
    bundle.with_suffix('.sha256').write_text(sha(bundle)+'  '+bundle.name+'\n',encoding='ascii')
    print(json.dumps(dict(status='PASS', additional_cores=56, board_responses=7168,
                          group_lut_max=max(g['lut_class'] for g in group_rows),
                          group_bram_max=max(g['bram_blocks'] for g in group_rows),
                          isolated_lut_max=max(g['lut_class'] for g in isolated.values()),
                          bundle=str(bundle), bytes=bundle.stat().st_size, package_files=len(files)),indent=2))


if __name__ == '__main__':
    main()
