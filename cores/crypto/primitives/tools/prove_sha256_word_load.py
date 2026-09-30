"""Prove one complete arbitrary block loads identically in actual old/new RTL.

This is a bounded symbolic loading proof, not whole-SHA equivalence. The
instrumented copies expose only the message words and compression state.
"""
import argparse
from pathlib import Path
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference',type=Path,required=True)
parser.add_argument('--candidate',type=Path,required=True)
parser.add_argument('--output-dir',type=Path,required=True)
args=parser.parse_args()
args.output_dir.mkdir(parents=True,exist_ok=False)
modules=[]
for name,path in [('sha_reference',args.reference),('sha_candidate',args.candidate)]:
    text=path.read_text()
    marker='output reg          digest_valid\n);'
    assert marker in text
    text=text.replace('module sha256_core (',f'module {name} (',1)
    text=text.replace(marker,'output reg          digest_valid,\n    output wire [511:0] exposed_words,\n    output wire exposed_active\n);',1)
    assignments='assign exposed_words = {'+', '.join(f'm[{i}]' for i in range(16))+'};\nassign exposed_active = (state == S_ROUND);\n'
    text=text.replace('endmodule',assignments+'endmodule',1)
    modules.append(text)
modules.append('''module load_miter(input clk, input rst_n, input [7:0] din,
    output equal, output active);
wire [511:0] old_words,new_words;
wire old_active,new_active;
sha_reference old(.clk(clk),.clk_en(1'b1),.rst_n(rst_n),.init(1'b0),
 .din(din),.din_valid(1'b1),.din_last(1'b0),.exposed_words(old_words),.exposed_active(old_active));
sha_candidate new_dut(.clk(clk),.clk_en(1'b1),.rst_n(rst_n),.init(1'b0),
 .din(din),.din_valid(1'b1),.din_last(1'b0),.exposed_words(new_words),.exposed_active(new_active));
assign equal = old_words == new_words;
assign active = old_active && new_active;
endmodule
''')
(args.output_dir/'miter.v').write_text('\n'.join(modules))
script='''read_verilog -sv miter.v
hierarchy -top load_miter
proc
memory_map
flatten
opt
async2sync
opt
dffunmap
sat -seq 66 -set rst_n 1 -set-at 1 rst_n 0 -set-def-inputs -prove-skip 65 -prove equal 1 -prove active 1 -verify
'''
(args.output_dir/'proof.ys').write_text(script)
with (args.output_dir/'console.log').open('w') as log:
    subprocess.run(['yosys','-Q','-l','proof.log','proof.ys'],cwd=args.output_dir,stdout=log,stderr=subprocess.STDOUT,check=True)
print('PASS symbolic 64-byte block loading: all 16 words equal at first compression')
