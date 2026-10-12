"""Host-selected variable inputs for JTAG initialization; no expected outputs in RTL."""
import sys
import json
import hashlib
from common import ROOT
sys.path.insert(0,str(ROOT/'models'))
from board_reference import vectors

def main():
    (ROOT/'vectors').mkdir(exist_ok=True)
    for p in range(9):
        cases=[vectors(p,k,s) for k in range(16 if p==0 else (1 if p==8 else 8)) for s in [1,2]]
        offsets=[]; rows=[]
        for c in cases: offsets.append(len(rows)); rows+=c['rows']
        depth=1<<(len(rows)-1).bit_length()
        mem=ROOT/'vectors'/f'auto_{p}.mem'
        mem.write_text('\n'.join(f'{x:024x}' for x in rows+[0]*(depth-len(rows)))+'\n')
        lines=[f'module sys_auto_vectors_{p}(input wire clk,input wire [15:0] address,input wire [7:0] case_id,output reg [95:0] data,output reg [47:0] descriptor,output wire [7:0] cases);',f'assign cases=8\'d{len(cases)};',f'(* ram_style="block" *) reg [95:0] mem[0:{depth-1}];', f'initial $readmemh("vectors/auto_{p}.mem",mem);',f'always @(posedge clk) data<=mem[address[{depth.bit_length()-2}:0]];', 'always @* begin descriptor=0; case(case_id)']
        for i,c in enumerate(cases): lines.append(f'8\'d{i}: descriptor={{16\'d{offsets[i]},16\'d{len(c["expected"])},16\'d{len(c["rows"])}}};')
        lines+=['default: descriptor=0; endcase end','endmodule']
        (ROOT/'board'/f'sys_auto_vectors_{p}.v').write_text('\n'.join(lines)+'\n')
        if p==8:
            # Capture the short ROM address at the opposite clock edge to
            # meet RAM hold time. Loading uses two full cycles per row, so
            # this changes physical phase without changing loaded values.
            safe='\n'.join(lines)+'\n'
            safe=safe.replace('always @(posedge clk) data<=mem[address[7:0]];',
                'reg [7:0] stable_address;\nalways @(negedge clk) stable_address<=address[7:0];\nalways @(posedge clk) data<=mem[stable_address];')
            (ROOT/'diagnostics/auto_8_hold_safe.v').write_text(safe)
        (ROOT/'vectors'/f'auto_{p}.json').write_text(json.dumps(dict(profile=p,cases=[dict(case_id=i,core=i//2,seed=i%2+1,stall=i%2,name=c['name'],offset=offsets[i],inputs=len(c['rows']),outputs=len(c['expected'])) for i,c in enumerate(cases)],input_mem_sha256=hashlib.sha256(mem.read_bytes()).hexdigest()),indent=2)+'\n')
    print('9 profiles of JTAG stimuli generated; no golden output ROM')

if __name__=='__main__': main()
