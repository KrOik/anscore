"""Real chain abort and malformed-block checks; fail-stop until reset."""
from pathlib import Path
import sys,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,execute,evidence_dir,write_json
from test_jpeg_frame import SOURCES,TB

folder=evidence_dir('jpeg_grayscale_errors')
with tempfile.TemporaryDirectory(prefix='jpeg_error_') as temp:
    p=Path(temp);(p/'pixels.hex').write_text('80\n'*64,encoding='utf-8')
    for name,expected in (('markers',0x81),('abort',0x86)):
        tb=TB.replace('WW','8').replace('HH','8').replace('RI','0')
        tb=tb.replace('reg accepted=0,','reg inject_abort=0;reg accepted=0,')
        tb=tb.replace('.abort(1\'b0)', '.abort(inject_abort)')
        tb=tb.replace('rerror||error||qerr','rerror||qerr')
        if name=='markers':tb=tb.replace('.s_block_first(rfirst)', ".s_block_first(!rfirst)")
        else:
            tb=tb.replace('wait(done&&ce);',
                          'wait(encoder.pixel_index==10);@(negedge clk);#1;inject_abort=1;wait(done&&ce);')
        tb=tb.replace('if(sent!=WIDTH*HEIGHT||error||bytecount<300)$fatal(1,"frame incomplete");',
                      f'inject_abort=0;ce=1;#1;if(error!=8\'h{expected:02x}||sr)$fatal(1,"error/fail-stop %h",error);')
        tb=tb.replace('$display("JPEG_FRAME PASS', '$display("JPEG_ERROR PASS')
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,folder/f'{name}_compile.log')
        text=execute(['vvp',p/'sim'],p,folder/f'{name}_simulation.log')
        assert 'JPEG_ERROR PASS' in text
        print(name,text.strip())
write_json(folder/'result.json',{'status':'PASS','cases':['malformed block marker','abort after ten accepted block pixels'],
                               'board_tested':False})
print(folder)
