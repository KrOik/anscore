"""Fresh isolated fixture with registered ROMs and clocked POR reset."""
from pathlib import Path
import sys,shutil,tempfile,json,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent));sys.path.insert(0,str(HERE.parent/'window_frame_optimized'))
from make_case import execute
from harness_rom_pipeline import register_rom_outputs
def main():
    base=HERE/sys.argv[1];out=HERE/sys.argv[2]
    if out.exists():raise RuntimeError('fresh output required')
    out.mkdir()
    for folder in ('source','verification'):shutil.copytree(base/folder,out/folder)
    for argument in sys.argv[3:]:
        replacement=Path(argument).resolve()
        target=out/'source'/replacement.name
        if not target.is_file():raise RuntimeError('replacement source absent')
        shutil.copy2(replacement,target)
    for name in ('case.json','vectors.json','tang25k.cst','expected_uart.txt'):shutil.copy2(base/name,out/name)
    driver=out/'source/acceptance48_driver.v'
    driver.write_text(driver.read_text().replace('posedge clk or negedge rst_n','posedge clk'))
    for p in (out/'source/acceptance48_top.v',out/'verification/pixel_fault_top.v'):
        text=p.read_text()
        if 'configuration_rom' not in text:text=register_rom_outputs(text)
        p.write_text(text)
    info=json.loads((out/'case.json').read_text())
    with tempfile.TemporaryDirectory(prefix='scalar_harness_') as temporary:
        for kind,cfg in info['verification_cases'].items():
            image=Path(temporary)/(kind+'.vvp')
            execute(['iverilog','-g2012','-s','acceptance48_tb','-o',image,out/cfg['top_source'],*[out/x for x in info['sources'][1:]],out/cfg['testbench']],out,out/(kind+'_compile.log'))
            result=execute(['vvp',image,'+golden='+str(out/cfg['expected_uart'])],out,out/(kind+'_simulation.log'))
            if 'ACCEPTANCE48 UART GOLDEN PASS' not in result:raise RuntimeError(kind)
    paths=[out/x for x in info['sources']]+[out/x for x in ('tang25k.cst','vectors.json','expected_uart.txt')]+list((out/'verification').iterdir())
    hashes={p.relative_to(out).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    info['source_sha256']=hashes
    info['candidate_note']='Isolated registered ROMs require CE_DIV>=3 (actual4); synchronous driver reset requires board clock through POR.'
    (out/'case.json').write_text(json.dumps(info,indent=2)+'\n')
    hashes['case.json']=hashlib.sha256((out/'case.json').read_bytes()).hexdigest()
    (out/'build_status.json').write_text(json.dumps(dict(status='SIMULATION_PASS',simulation='PASS',source_sha256=hashes),indent=2)+'\n')
    print('SEVEN_UART_PASS',out)
if __name__=='__main__':main()
