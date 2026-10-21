"""GW5A-25A synthesis/route, resource and timing gated SRAM artifacts."""
import argparse
import json
import hashlib
import re
from collections import Counter
from common import ROOT,SUITE,CORES,evidence,hashes,run
from board_sim import sources

def metrics(netlist,top):
    cells=Counter(c['type'] for c in json.loads(netlist.read_text())['modules'][top]['cells'].values())
    lut=sum(n for t,n in cells.items() if re.fullmatch(r'LUT[1-9]|ALU',t))
    dsp=sum(n for t,n in cells.items() if re.search(r'MULT|PADD|ALU54|MULTALU|MULTADD',t))
    ram=sum(n for t,n in cells.items() if re.fullmatch(r'(?:SP|SDP|DP|ROM)(?:X9)?B?',t))
    ff=sum(n for t,n in cells.items() if t.startswith('DFF'))
    return dict(lut_class=lut,dsp_class=dsp,bram_blocks=ram,ff_class=ff,cells=dict(cells),
                under_budget=lut<=15000 and dsp<=4 and ram<=46)

def routed_metrics(netlist,top,route_log):
    """GW5A wide logical RAM primitives can pack into multiple physical BSRAMs."""
    m=metrics(netlist,top)
    packed={a:dict(used=int(b),available=int(c)) for a,b,c in
            re.findall(r'Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+\d+%',route_log)}
    assert all(k in packed for k in ['LUT4','DFF','BSRAM','MULT12X12','MULTALU27X18','MULTADDALU12X12']), 'missing device utilization'
    assert 'ERROR:' not in route_log, 'route contains error'
    physical_dsp=sum(packed[k]['used'] for k in packed if re.search(r'MULT|PADD|ALU54',k))
    logical_ram=m['bram_blocks']
    m.update(synthesis_bram_primitives=logical_ram,
             bram_blocks=packed['BSRAM']['used'],
             lut_class=max(m['lut_class'],packed['LUT4']['used']+packed.get('ALU',{}).get('used',0)),
             dsp_class=max(m['dsp_class'],physical_dsp),packed_utilization=packed,
             resource_basis='physical nextpnr utilization; conservative LUT/DSP maximum with synthesis')
    m['under_budget']=m['lut_class']<=15000 and m['dsp_class']<=4 and m['bram_blocks']<=46
    return m

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--profiles',default='0,1,2,3,4,5,6,7')
    ap.add_argument('--isolated',action='store_true'); ap.add_argument('--synth-only',action='store_true'); ap.add_argument('--auto',action='store_true'); ap.add_argument('--pnr-seed',type=int,default=1); ap.add_argument('--half-cycle-rom',action='store_true'); ap.add_argument('--no-wide-lut',action='store_true'); ap.add_argument('--phase-capture',action='store_true'); ap.add_argument('--no-clock-enable-ff',action='store_true'); a=ap.parse_args()
    out=evidence('build'); summary={'status':'IN_PROGRESS','sources':hashes(),'profiles':[],'isolated':[],
            'device':'GW5A-LV25MG121NES','family':'GW5A-25A','clock_mhz':50,'clock_enable':1,'no_wide_lut':a.no_wide_lut,'transport':'JTAG-loaded-raw-UART' if a.auto else 'UART-command'}
    synth_options='-noalu'+(' -nowidelut' if a.no_wide_lut else '')+(' -nodffe -strict-gw5a-dffs' if a.no_clock_enable_ff else '')
    def save(): (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    try:
        if a.isolated:
            for name,_,_ in CORES:
                top='sys_'+name; net=out/(name+'.json'); script=out/(name+'.ys')
                script.write_text(f'read_verilog rtl/{top}.v\nsynth_gowin -family gw5a {synth_options} -top {top} -json {net.as_posix()}\nstat\n')
                run(['yosys','-s',script],out/(name+'.log'),600)
                m=metrics(net,top); assert m['under_budget'],name
                summary['isolated'].append(dict(core=name,status='PASS',**m)); save()
                print('ISOLATED '+name+' '+str({k:m[k] for k in ['lut_class','dsp_class','bram_blocks']}),flush=True)
        for p in [int(x) for x in a.profiles.split(',') if x]:
            files=sources(p,a.half_cycle_rom,a.phase_capture); net=out/f'profile_{p}.json'; script=out/f'profile_{p}.ys'
            tracked=files+[ROOT/'vectors'/f'auto_{p}.mem'] if a.auto else files
            input_hashes={f.relative_to(ROOT.parent.parent).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked}
            top='sys_auto_top' if a.auto else 'sys_top'
            script.write_text('read_verilog '+' '.join(f.as_posix() for f in files)+'\n'+
               f'chparam -set PROFILE {p} {top}\nsynth_gowin -family gw5a {synth_options} -top {top} -json {net.as_posix()}\nstat\n')
            run(['yosys','-s',script],out/f'profile_{p}_yosys.log',600)
            m=metrics(net,top); assert m['under_budget'],('budget',p,m)
            assert input_hashes=={f.relative_to(ROOT.parent.parent).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in tracked},'source changed during synthesis'
            r=dict(profile=p,synthesis='PASS',route='NOT_RUN',pnr_seed=a.pnr_seed,half_cycle_rom=a.half_cycle_rom,no_wide_lut=a.no_wide_lut,phase_capture=a.phase_capture,no_clock_enable_ff=a.no_clock_enable_ff,**m,input_sha256=input_hashes)
            summary['profiles'].append(r); save()
            print(f'PROFILE {p}: LUT={m["lut_class"]} DSP={m["dsp_class"]} BSRAM={m["bram_blocks"]}',flush=True)
            if a.synth_only: continue
            routed=out/f'profile_{p}_pnr.json'
            t=run(['nextpnr-himbaechel','--json',net,'--write',routed,'--device',summary['device'],
               '--vopt','family=GW5A-25A','--vopt','cst=board/tang25k.cst','--vopt','sspi_as_gpio','--freq','50','--seed',str(a.pnr_seed)],out/f'profile_{p}_nextpnr.log',600)
            fmax=re.findall(r'Max frequency.*?:\s*([0-9.]+) MHz',t)
            assert fmax and min(map(float,fmax))>=50,('timing',p,fmax)
            physical=routed_metrics(net,top,t)
            assert physical['under_budget'],('physical resource budget',p,physical)
            r.update(physical,route='PASS',fmax_mhz=min(map(float,fmax)))
            fs=out/f'profile_{p}.fs'
            run([SUITE/'lib/python3.exe',SUITE/'bin/gowin_pack-script.py','-d','GW5A-25A','--sspi_as_gpio','-o',fs,routed],out/f'profile_{p}_pack.log',120)
            r.update(bitstream=fs.relative_to(ROOT).as_posix(),bitstream_sha256=hashlib.sha256(fs.read_bytes()).hexdigest(),bitstream_bytes=fs.stat().st_size)
            save(); print(f'PACK {p} PASS Fmax={r["fmax_mhz"]}',flush=True)
        summary['status']='PASS'
    except Exception as e: summary['status']='FAIL'; summary['reason']=str(e); raise
    finally: save(); print('Evidence='+str(out),flush=True)

if __name__=='__main__': main()
