"""Bounded SAT checks for response stability and CE gating, all 56 kernels.

This is a handshake composition check, not functional or security proof.
"""
from datetime import datetime, timezone
import json
from catalog import CORES
from verify import ROOT, run, source_hashes

HARNESS = '''module formal_{name}(
 input wire clk,rst_n,clk_en,in_valid,out_ready,
 input wire [31:0] a,b,c
);
wire in_ready,out_valid,fault;
wire [31:0] result,aux;
prod_{name} dut(.*);
reg past_valid=0;
always @(posedge clk) begin
 past_valid<=1;
 assert(!in_ready || clk_en);
 if(past_valid && rst_n && $past(rst_n)) begin
   if(!$past(clk_en) || $past(out_valid && !out_ready)) begin
     assert(out_valid==$past(out_valid));
     assert(result==$past(result));
     assert(aux==$past(aux));
     assert(fault==$past(fault));
   end
 end
end
endmodule
'''


def main():
    out = ROOT/'evidence'/('formal_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    out.mkdir(parents=True, exist_ok=False)
    results = []
    for entry in CORES:
        name = entry['name']
        harness = out/(name+'_harness.sv')
        harness.write_text(HARNESS.format(name=name), encoding='utf-8')
        ys = out/(name+'.ys')
        ys.write_text(f'read_verilog -formal -sv rtl/prod_{name}.v {harness.as_posix()}\n'
                      f'prep -top formal_{name} -flatten\n'
                      'async2sync\nopt_clean\n'
                      'sat -verify -prove-asserts -set-assumes -seq 8 -set-init-zero\n')
        text = run(['yosys', '-s', ys], out/(name+'.log'))
        if 'SUCCESS!' not in text:
            raise RuntimeError('missing SAT success: '+name)
        results.append(dict(name=name, status='PASS', depth=8))
        print(f'FORMAL {name} PASS depth=8 boundary assertions', flush=True)
    (out/'summary.json').write_text(json.dumps(dict(status='PASS', count=len(results),
                         proof='bounded SAT, depth8, initial register values zero',
                         properties=['request ready implies CE', 'blocked response stable', 'CE pauses output'],
                         security_proof=False, functional_equivalence_proof=False,
                         cores=results, sources=source_hashes()), indent=2)+'\n', encoding='utf-8')
    print('Formal evidence='+str(out))


if __name__ == '__main__':
    main()
