from pathlib import Path
import hashlib,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'integration'))
from tooling import ROOT,PACKAGE,execute,evidence_dir,write_json
names=('dsp/dct8x8/dct8x8_serial.sv','dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv',
       'dsp/jpeg_entropy/jpeg_baseline_symbols.v','dsp/jpeg_huffman/jpeg_default_huffman.sv',
       'dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv','dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v',
       'dsp/jpeg_grayscale/jpeg_grayscale_scan.sv')
sources=[PACKAGE/name for name in names]
folder=evidence_dir('jpeg_grayscale_synth')
cmd='read_verilog -sv '+' '.join(p.as_posix() for p in sources)+'; synth_gowin -top jpeg_grayscale_scan -noalu -nodsp; check -assert; stat'
output=execute(['yosys','-p',cmd],ROOT,folder/'synthesis.log',timeout=180)
write_json(folder/'result.json',{'status':'PASS','sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},'board_tested':False})
print(output[output.rfind('=== design hierarchy ==='):]);print(folder)
