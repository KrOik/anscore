"""Audit every retained physical record and package source-bound IP candidates.

Functional failures remain failures. A release requires the new sixteen cores
and acquisition demonstration to pass, and reports legacy full-rate failures.
It never rewrites existing evidence or the original 56-core acceptance.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile
from common import ROOT, REPO, CORES
from build import routed_metrics
sys.path.insert(0, str(ROOT/'models'))
from auto_check import packets, check
from board_reference import vectors


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def source_check(report, files):
    for name in files:
        assert report['sources'].get(name)==sha(ROOT/name), ('source mismatch',name)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--build', required=True, type=Path)
    ap.add_argument('--board-records', nargs='+', required=True, type=Path)
    a=ap.parse_args()
    build_path=a.build.resolve(); build=read(build_path/'summary.json')
    assert build['status']=='PASS' and build['transport']=='JTAG-loaded-raw-UART'
    assert len(build['profiles'])==9 and len(build['isolated'])==16
    rows={r['profile']:r for r in build['profiles']}; board={}
    for folder in a.board_records:
        folder=folder.resolve(); s=read(folder/'summary.json')
        assert Path(s['build']).resolve()==build_path
        assert s['clock_mhz']==50 and s['clock_enable']==1 and s['jtag_freq_hz']==1000000
        for p in range(9):
            raw_path=folder/f'profile_{p}.bin'
            if not raw_path.exists(): continue
            assert p not in board, ('duplicate physical profile',p)
            r=rows[p]; origin=ROOT/r['origin']
            log=(folder/f'profile_{p}_program_uart.log').read_text(encoding='utf-8')
            assert 'DONE' in log, ('missing programming completion',p)
            # Source/hash binding was checked before upload by the capture tool.
            assert 'auto program/capture' not in s.get('reason','')
            raw=raw_path.read_bytes(); fs=packets(raw)
            runs=check(p,fs,collect_failures=True)
            failed=[v for v in runs if v['model_check']!='PASS']
            physical=routed_metrics(origin/f'profile_{p}.json','sys_auto_top',
                                  (origin/f'profile_{p}_nextpnr.log').read_text(encoding='utf-8'))
            assert physical['under_budget'] and r['route']=='PASS' and r['fmax_mhz']>=50
            for name,h in r['input_sha256'].items():
                assert sha(REPO/name)==h, ('stale physical input',name)
            assert sha(ROOT/r['bitstream'])==r['bitstream_sha256']
            # Explicitly bind any originally accepted row to the same raw bytes.
            accepted=next((q for q in s['profiles'] if q['profile']==p),None)
            if accepted:
                assert not failed
                assert accepted['raw_sha256']==sha(raw_path)
                assert accepted['bitstream_sha256']==r['bitstream_sha256']
            mismatches=[]
            for run in failed:
                case=vectors(p,run['core'],run['seed'])
                differences=[dict(index=i,stimulus=f'{case["rows"][i]:024x}' if len(case['rows'])==len(case['expected']) else None,
                                  actual=f'{actual:048x}',expected=f'{expected:048x}')
                         for i,(actual,expected) in enumerate(zip(map(lambda x:int(x,16),run['raw']),case['expected']))
                         if (actual&case['mask'])!=(expected&case['mask'])]
                mismatches.append(dict(case_id=run['case_id'],name=run['name'],seed=run['seed'],
                                       error=run['model_error'],differences=differences))
            board[p]=dict(profile=p,status='FAIL' if failed else 'PASS',cases=len(runs),
                          passing_cases=len(runs)-len(failed),raw_outputs=sum(len(q['raw']) for q in runs),
                          raw_frames=len(fs),raw_sha256=sha(raw_path),
                          raw_path=raw_path.relative_to(ROOT).as_posix(),
                          original_summary_status=s['status'],
                          evidence=(folder/'summary.json').relative_to(ROOT).as_posix(),
                          bitstream=r['bitstream'],bitstream_sha256=r['bitstream_sha256'],
                          fmax_mhz=r['fmax_mhz'],resources=physical,mismatches=mismatches,runs=runs)
    assert set(board)==set(range(9)), 'missing physical profiles'
    assert board[0]['status']==board[8]['status']=='PASS', 'new IP or demo failed'
    assert board[0]['cases']==32 and board[8]['cases']==2
    restored=read(ROOT/'evidence/board_auto_20261009T160212256208Z/summary.json')
    assert restored['status']=='PASS' and restored['profiles'][0]['profile']==8
    assert restored['profiles'][0]['bitstream_sha256']==rows[8]['bitstream_sha256']
    native=ROOT/'evidence/sim_20261009T150748424724Z/summary.json'
    adapters=ROOT/'evidence/adapter_sim_20261009T150748429259Z/summary.json'
    protocol=ROOT/'evidence/board_sim_20261009T160233073848Z/summary.json'
    auto=ROOT/'evidence/auto_sim_20261009T152658141370Z/summary.json'
    auto_half=ROOT/'evidence/auto_sim_20261009T153430631220Z/summary.json'
    base=ROOT/'evidence/baseline_regression_20261009T150711516943Z/summary.json'
    n=read(native); ad=read(adapters); pr=read(protocol); au=read(auto); ah=read(auto_half)
    assert all(s['status']=='PASS' for s in [n,ad,pr,au,ah,read(base)])
    assert len(n['tests'])==18 and {q['core'] for q in n['tests']}=={q[0] for q in CORES}
    assert {q['profile'] for q in ad['profiles']}==set(range(9))
    source_check(n,[f'rtl/sys_{c[0]}.v' for c in CORES]+['sim/native_tests.py','models/reference.py'])
    source_check(ad,[f'rtl/sys_{c[0]}.v' for c in CORES]+['sim/adapter_tests.py','models/board_reference.py','models/reference.py'])
    source_check(ad,['board/sys_native_adapters.v','board/sys_acquisition_demo.v']+[f'board/sys_legacy_{i}.v' for i in range(7)])
    source_check(pr,['board/sys_top.v','board/sys_transport.v','board/sys_uart.v','sim/board_tests.py','models/codec.py'])
    source_check(au,['board/sys_auto_top.v','sim/auto_tests.py','models/board_reference.py'])
    source_check(ah,['board/sys_auto_top.v','diagnostics/auto_8_hold_safe.v','sim/auto_tests.py','models/board_reference.py'])
    for name,h in read(base)['sources'].items(): assert sha(REPO/name)==h, ('baseline changed',name)
    # The strict checker must still reject a functional mutation.
    frames=packets((ROOT/board[0]['raw_path']).read_bytes())
    altered=list(frames); index=next(i for i,f in enumerate(altered) if f[0]==0x84)
    cmd,address,raw=altered[index]; altered[index]=(cmd,address,raw^1)
    try: check(0,altered)
    except AssertionError: pass
    else: raise AssertionError('mutated output accepted by strict checker')
    inventory_path=REPO/'artifacts/ip_expansion_20261009/baseline_inventory.json'
    inventory=read(inventory_path)
    packaged=[p for p in (REPO/'projects').glob('*/ip/*/*.json') if p.name in ['manifest.json','ip_manifest.json']]
    assert inventory['count']==129 and len(packaged)==201
    old_release=REPO/'cores/system/utility_library/releases/production_ip_25k_20261009T134808Z.zip'
    assert sha(old_release)=='abf2e4a2dd03b4aed5564dbfce2dedd9e6acf72a86c8c8bb478c3aa819776c9f'
    failed_names=sorted({q['name'] for p in range(1,8) for q in board[p]['runs'] if q['model_check']=='FAIL'})
    isolated={s['core']:s for s in build['isolated']}
    assets=[]
    for name,family,_ in CORES:
        m=read(ROOT/f'ip/{name}/manifest.json')
        assert m['rtl_sha256']==sha(ROOT/m['source'])
        measured=[q for q in board[0]['runs'] if q['name']==name]
        assert len(measured)==2 and all(q['model_check']=='PASS' for q in measured)
        assets.append(dict(name=name,family=family,rtl_sha256=m['rtl_sha256'],native_simulation='PASS',
                           isolated_synthesis=isolated[name],physical_test='PASS',measured_runs=measured))
    report=dict(timestamp=datetime.now(timezone.utc).isoformat(),status='ENGINEERING_CANDIDATE_WITH_RECORDED_LIMITS',
                new_native_cores=16,previous_new_cores=56,total_new_cores=72,baseline_packaged_cores=129,current_packaged_cores=201,
                inventory_basis='packaged manifests; not a claim that all201 have the same qualification',
                device='GW5A-LV25MG121NES',jtag_id='0x1281b',physical_clock_mhz=50,clock_enable=1,
                native_simulation_configurations=18,new_cores_board='16/16 PASS',acquisition_demo_board='PASS, digital stimuli',
                legacy_full_rate=dict(passing_cores=56-len(failed_names),failing_cores=len(failed_names),failed_names=failed_names,
                                      previous_ce_1_over_16_acceptance_unchanged=True),
                uart_command_physical='BLOCKED: host TX is not visible at FPGA B3 in independent pin diagnostics',
                final_sram_image=dict(profile=8,status='PASS',flash_written=False,
                                      evidence='evidence/board_auto_20261009T160212256208Z/summary.json'),
                board_transport='SRAM JTAG stimulus load at1MHz; CRC UART raw response readback',
                physical_responses_observed=sum(q['raw_outputs'] for q in board.values()),
                new_cores_checked_responses=board[0]['raw_outputs'],demo_checked_responses=board[8]['raw_outputs'],
                core_assets=assets,profiles=[board[p] for p in range(9)],
                evidence={k:p.relative_to(ROOT).as_posix() for k,p in
                         [('native',native),('adapters',adapters),('uart_simulation',protocol),('auto_simulation',auto),('auto_half_rom_simulation',auto_half),('baseline',base),('build',build_path/'summary.json')]},
                qualification=dict(production_signoff=False,patentability_claim=False,side_channel_claim=False,
                                   physical_adc_test=False,independent_clock_cdc_board_test=False),
                resource_note='Physical BSRAM from nextpnr overrides logical primitive count; new16 image34 logical/46 physical. Historical reports kept unchanged.',
                host_checker_mutation_rejection='PASS')
    (ROOT/'doc/ACCEPTANCE.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    csv_text=io.StringIO(); w=csv.writer(csv_text)
    w.writerow(['name','family','rtl_sha256','native_sim','isolated_LUT','isolated_DSP','board_50MHz_CE1','seed1_cycles','seed2_cycles'])
    for row in assets:
        w.writerow([row['name'],row['family'],row['rtl_sha256'],'PASS',row['isolated_synthesis']['lut_class'],
                    row['isolated_synthesis']['dsp_class'],'PASS',*[m['status']['cycles'] for m in row['measured_runs']]])
    (ROOT/'doc/IP_ASSET_RECORDS.csv').write_text(csv_text.getvalue(),encoding='utf-8-sig')
    table='|Profile|受测内容|LUT|物理BSRAM|DSP|路由Fmax MHz|原始响应|板级结果|\n|---:|---|---:|---:|---:|---:|---:|---|\n'
    for p in range(9):
        q=board[p]; m=q['resources']; label='新增16核' if p==0 else ('采集演示' if p==8 else f'原56核第{p}组')
        table+=f'|{p}|{label}|{m["lut_class"]}|{m["bram_blocks"]}|{m["dsp_class"]}|{q["fmax_mhz"]:.2f}|{q["raw_outputs"]}|{q["status"]}|\n'
    failed=', '.join(failed_names)
    validation=f'''# 验证与交付记录

时间：{report['timestamp']}。新增16个独立原生核；与前批56核合计新增72核。
库存清点为129→185→201份封装清单；夹具、ROM、串口、参数变体与旧核复验不计新增核。
201是资产数量，各项目的成熟度须查看自己的验收记录。

**本批16/16核原生仿真、独立综合及25K板级功能验收PASS。** 原生测试18个配置；
9个适配profile的变量输入与背压仿真PASS。新核32个板级案例核对2548个原始响应；
采集演示2个案例核对18个响应。既有NTT标准回归及六条UART合同PASS，未编辑原NTT源码。

{table}

以上9份镜像均通过50MHz布局布线，≤15000 LUT、≤4DSP、≤46物理BSRAM。
路由PASS与功能PASS分别记录。profile0恰好使用46个物理BSRAM；网表34个逻辑RAM
会被GW5A打包拆分，不能把34当作物理块数。profile8也为14逻辑/26物理块。
独立综合默认参数最多{max(s['lut_class'] for s in isolated.values())} LUT，全部0DSP；独立综合未执行物理路由，RAM原语数仅为估算。

## 原56核全速复验发现

本次CE=1复验为52/56核PASS，4核FAIL：`{failed}`。
每核两组变量刺激，各128输入，一组无背压、一组每8周期背压2周期。
失败核保持模型失配，未改写期待值。具体逐拍刺激、实际值、期待值列在
ACCEPTANCE.json的profiles/mismatches中，全部原始UART二进制保留。
仅LUT4映射及下降沿结果采集的隔离实验仍有失配，尚不能确定根因。
原来的56核CE=1/16验收与发布包保持原样；它们不等于通过50MHz连续输入验收。
因此本交付没有将全部72核声明为50MHz量产签核完成。

## 物理链路与采集边界

远端192.168.31.176实测GW5A-25，ID0x1281b，用户确认按25K处理。
UART TX C3正常；主机TX→FPGA B3在独立pin诊断中始终高，无跳变、无接收字节。
用户反馈线路未改动；模式复位、B0位操作和官方IO属性复验未恢复接收。
UART命令协议仿真PASS，物理命令注入BLOCKED，不能由主机写串口成功声称FPGA已收到刺激。
默认JTAG速率曾出现DONE后旧镜像仍输出或新镜像无输出；1MHz配置后读到新镜像完整CRC帧。
该现象未确诊为具体硬件故障；DONE本身不作为验收依据。
所有本次镜像仅SRAM加载，没有写Flash。
诊断结束后恢复profile8采集演示并再次读取完整数据帧通过，记录为
`evidence/board_auto_20261009T160212256208Z/summary.json`；当前SRAM保持该镜像。

通过路径是主机生成输入→JTAG初始化刺激ROM→同步复制到真实replay RAM→
50MHz硬件回放→响应RAM→UART逐条CRC原始输出→独立主机模型核对。
ROM只有输入和长度描述，没有期待输出。每个案例显式复位DUT；UART加载/读回
不计入replay cycles。源文件和MEM、上传镜像、捕获数据均有SHA256绑定。

profile8演示四通道乱序epoch对齐、24位有符号Q2.14校准、64位时间戳、前4/后4触发窗口。
它使用数字样本，没有连接物理ADC。packet CDC板测采用同源同频时钟，独立时钟比仅有仿真证据。
校准为0DSP串行16次移位加法及3个收尾阶段，接受后19周期valid，无停顿时II20。
快核记录II1条件及实测回放周期；不同输入/输出条数不以统一吞吐或统一延迟描述。
stream_metrics只适用顺序1:1、未完成≤16的流；拆分、丢包、聚合、触发子窗口
仅使用输入/输出计数及replay周期，其队列溢出/不匹配显式记为errors，延迟不适用。

## 来源、文件与命令

本批新增与改动限于cores/system/stream_bus_library：rtl、ip规格/清单、模型、
原生/适配/协议测试、板级夹具、构建/远端/交付工具、诊断与验证文档。
原56核源码、前批发布包、原NTT源码/摘要/共享脚本及既有用户改动保持原样。
16核源文件SHA256、原生测试入口、原生参数边界见各manifest/SPEC和IP_ASSET_RECORDS.csv。
“知识产权可用”落实为可追溯可集成的工程源资产；未作出专利新颖性、法律权属或安全认证结论。
完整量产签核、长期温压、实际产线外设联调、CDC物理时序及安全证明不由本组测试替代。

```powershell
python cores/system/stream_bus_library/tools/verify.py
python cores/system/stream_bus_library/tools/board_sim.py --adapters --profiles 0,1,2,3,4,5,6,7,8
python cores/system/stream_bus_library/tools/board_sim.py --profiles 0
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 0,8
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/build.py --isolated --profiles 0,8
python cores/system/stream_bus_library/tools/build.py --profiles 1,2,3,4,5,6,7
python cores/system/stream_bus_library/tools/build.py --auto --profiles 0,1,2,3,4,5,6,7
python cores/system/stream_bus_library/tools/build.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/remote_auto.py --build {build_path.relative_to(REPO).as_posix()} --profiles 0,8 --jtag-freq 1000000
.\\scripts\\test_hybrid_lattice_ntt_sim.ps1
```

命令模式9profile综合/路由PASS，auto的profile8原同边沿ROM版本hold检查FAIL，
因此最终profile8使用下降沿地址寄存的ROM；未跳过时序检查。所有失败日志原样保留。
原生证据：`{report['evidence']['native']}`；适配证据：`{report['evidence']['adapters']}`；
最终资源审计：`{report['evidence']['build']}`；完整验收依据：`doc/ACCEPTANCE.json`。
NTT回归是执行回执并附源码哈希，本轮全控制台输出未另存文件；前批基线全日志仍在原发布包。
主机核对程序已用单比特功能破坏验证严格拒绝；CRC、帧数、完成状态、计数与终止帧均校验。
当前结论：新增16核工程功能验收PASS；保留明确的UART接收阻塞及原4核全速失配。
'''
    (ROOT/'doc/VALIDATION.md').write_text(validation,encoding='utf-8')
    files={}
    def add(path): files[path.relative_to(REPO).as_posix()]=path
    for folder in ['rtl','sim','models','board','tools','ip','doc','vectors','diagnostics']:
        for p in sorted((ROOT/folder).rglob('*')):
            if p.is_file() and '__pycache__' not in p.parts: add(p)
    add(ROOT/'README.md'); add(inventory_path); add(old_release); add(old_release.with_suffix('.sha256'))
    old=REPO/'cores/system/utility_library'
    for folder in ['rtl','ip']:
        for p in (old/folder).rglob('*'):
            if p.is_file(): add(p)
    for name in ['tools/catalog.py','tools/golden.py','doc/PROVENANCE.md','doc/ACCEPTANCE.json','doc/VALIDATION.md']:
        p=old/name
        if p.exists(): add(p)
    directories={native.parent,adapters.parent,protocol.parent,auto.parent,auto_half.parent,base.parent,build_path}
    directories.update((p.resolve() for p in a.board_records))
    directories.update(ROOT/r['origin'] for r in rows.values())
    # Include retained negative diagnostics, but exclude bulky simulator executables.
    for pattern in ['uart_diagnostic_*','usb_uart_*','sram_slow_probe_*','board_auto_*']:
        directories.update((ROOT/'evidence').glob(pattern))
    directories.add(ROOT/'evidence/auto_sim_20261009T155231400970Z')
    # Preserve the build origin of each unsuccessful physical experiment too.
    for d in list(directories):
        summary_file=d/'summary.json'
        if summary_file.exists():
            experiment=read(summary_file).get('build')
            if experiment:
                origin=Path(experiment).resolve()
                if origin.is_relative_to(ROOT/'evidence') and origin.exists(): directories.add(origin)
    for d in directories:
        for p in d.iterdir():
            if p.is_file() and (p.suffix in ['.log','.bin','.txt','.ys','.fs','.xml'] or
                               (p.suffix=='.json' and not p.stem.endswith('_pnr'))): add(p)
    # Isolated netlists/logs are in the retained origin used by collect_builds.
    iso_dir=ROOT/'evidence/build_20261009T150302707701Z'
    add(iso_dir/'summary.json')
    for name,_,_ in CORES:
        for suffix in ['.json','.ys','.log']: add(iso_dir/(name+suffix))
    ledger={name:dict(sha256=sha(p),bytes=p.stat().st_size) for name,p in sorted(files.items())}
    dest=ROOT/'releases'; dest.mkdir(exist_ok=True)
    bundle=dest/('production_system_ip_25k_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'.zip')
    with zipfile.ZipFile(bundle,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for name,p in sorted(files.items()): z.write(p,name)
        z.writestr('PACKAGE_MANIFEST.json',json.dumps(ledger,indent=2)+'\n')
        z.writestr('DELIVERY.md','本包保留仓库目录结构。新增16核及完整记录位于cores/system/stream_bus_library。\n'
                   '先阅读该目录doc/VALIDATION.md。原56核旧发布包未修改；本次全速失配如实保留。\n'
                   'OSS CAD Suite与Python依赖需自行配置。远端密码只通过P25_PASSWORD提供，未打包凭证。\n')
    with zipfile.ZipFile(bundle) as z:
        assert z.testzip() is None
        for name,m in ledger.items(): assert hashlib.sha256(z.read(name)).hexdigest()==m['sha256'],name
    bundle.with_suffix('.sha256').write_text(sha(bundle)+'  '+bundle.name+'\n',encoding='ascii')
    print(json.dumps(dict(status='PASS',new_cores=16,new_board_outputs=board[0]['raw_outputs'],
                         legacy_full_rate_failed=failed_names,files=len(files),bundle=str(bundle),
                         bundle_sha256=sha(bundle),bytes=bundle.stat().st_size),indent=2))


if __name__=='__main__': main()
