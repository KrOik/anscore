"""Actual SGM -> connected-component speckle removal -> general-Q XYZ stream."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json
import test_sgm_reproject as previous

def remove_small(values, invalid, width, height, distance, limit):
    pending = {i for i, bad in enumerate(invalid) if not bad}
    removed = [False] * len(values)
    while pending:
        seed = min(pending)
        pending.remove(seed)
        component = [seed]
        cursor = 0
        while cursor < len(component):
            index = component[cursor]
            cursor += 1
            x, y = index % width, index // width
            neighbors = []
            if x: neighbors.append(index-1)
            if x+1 < width: neighbors.append(index+1)
            if y: neighbors.append(index-width)
            if y+1 < height: neighbors.append(index+width)
            for j in neighbors:
                if j in pending and abs(values[j]-values[index]) <= distance:
                    pending.remove(j)
                    component.append(j)
        if len(component) <= limit:
            for index in component: removed[index] = True
    return removed

def main():
    folder = evidence_dir('sgm_speckle_reproject')
    w, h, d = 11, 7, 5
    rng = random.Random(5102)
    fixtures = []
    removals = []
    for mode, (distance, limit) in enumerate(((0,0),(0,3),(1,5),(4,77),(0,77),(0,2))):
        left = [rng.getrandbits(24) for _ in range(w*h)]
        right = [left[y*w+min(w-1,x+2)] for y in range(h) for x in range(w)]
        lb = [int(mode==5 or mode==2 and i%13==0) for i in range(w*h)]
        rb = [int(mode==5) for _ in left]
        q = [65536,0,0,-5*65536, 0,65536,0,-3*65536, 0,0,0,16*65536, 0,0,32768,0]
        matched, _, _ = previous.sgm_reference.oracle(left,right,lb,rb,w,h,d,3,15)
        disparity = [m[0] for m in matched]
        invalid = [m[2] for m in matched]
        removed = remove_small(disparity,invalid,w,h,distance,limit)
        removals.append(sum(removed))
        xyz = [previous.reproject(i%w,i//w,value,invalid[i] or removed[i],q) for i,value in enumerate(disparity)]
        filtered = [(value & 0xffffff) | (int(invalid[i] or removed[i])<<24) | (int(removed[i])<<25) for i,value in enumerate(disparity)]
        fixtures.append((left,right,lb,rb,q,xyz,filtered,distance,limit))
    assert removals[0] == 0 and removals[1] > 0 and removals[3] > 0 and removals[-1] == 0
    tb = previous.TB
    original = '.s_disparity(signed_disparity),.s_invalid(sg_bad),.s_valid(sgv),.s_ready(pr),\n .s_sof(sg_sof),.s_eol(sg_eol),.s_last(sg_last),'
    assert original in tb
    tb = tb.replace(original, '.s_disparity(filtered_d),.s_invalid(filtered_bad),.s_valid(filtered_valid),.s_ready(filtered_ready),\n .s_sof(filtered_sof),.s_eol(filtered_eol),.s_last(filtered_last),')
    insert = '''integer f;
wire signed[23:0]filtered_d;wire filtered_bad,filtered_removed,filtered_valid,filtered_ready,filtered_sof,filtered_eol,filtered_last;
wire filter_start_ready,filter_done,filter_error;wire[2:0]filter_code;
reg[23:0]ranges[0:F-1];reg[$clog2(N+1)-1:0]sizes[0:F-1];
reg[25:0]filtered_expected[0:F*N-1];integer filtered_count=0;
disparity_speckle #(.WIDTH(W),.HEIGHT(H),.DISP_BITS(24),.DISP_FRAC(0))filter_core(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(filter_start_ready),.cfg_range(ranges[f]),.cfg_max_size(sizes[f]),
.s_disparity(signed_disparity),.s_invalid(sg_bad),.s_valid(sgv),.s_ready(pr),.s_sof(sg_sof),.s_eol(sg_eol),.s_last(sg_last),
.m_disparity(filtered_d),.m_invalid(filtered_bad),.m_removed(filtered_removed),.m_valid(filtered_valid),.m_ready(filtered_ready),
.m_sof(filtered_sof),.m_eol(filtered_eol),.m_last(filtered_last),.done_valid(filter_done),.done_ready(ack),.done_error(filter_error),.error_code(filter_code));
always @(posedge clk)if(rst_n&&ce&&filtered_valid&&filtered_ready)begin
if({filtered_removed,filtered_bad,filtered_d}!==filtered_expected[filtered_count])$fatal(1,"filtered disparity %d",filtered_count);
if(filtered_sof!==(filtered_count%N==0)||filtered_eol!==(filtered_count%W==W-1)||filtered_last!==(filtered_count%N==N-1))$fatal(1,"filtered markers");
filtered_count=filtered_count+1;end
'''
    tb = tb.replace('disparity_reproject #', insert+'\ndisparity_reproject #', 1)
    tb = tb.replace('cy=0,f,i;', 'cy=0,i;')
    tb = tb.replace('!psr||!sg_start_ready', '!psr||!sg_start_ready||!filter_start_ready')
    tb = tb.replace('while(!done||!sg_done)', 'while(!done||!sg_done||!filter_done)')
    tb = tb.replace('||sg_error||sg_code)', '||sg_error||sg_code||filter_error||filter_code||filtered_count!=(f+1)*N)')
    tb = tb.replace('$readmemh("left.hex",ls);', '$readmemh("filtered.hex",filtered_expected);$readmemh("ranges.hex",ranges);$readmemh("sizes.hex",sizes);\n $readmemh("left.hex",ls);')
    tb = tb.replace('SGM_REPROJECT PASS','SGM_SPECKLE_REPROJECT PASS')
    for key,value in dict(W=w,H=h,D=d,F=len(fixtures)).items(): tb=tb.replace('@'+key+'@',str(value))
    sources = previous.SOURCES+[PACKAGE/'image/disparity_speckle/disparity_speckle.sv']
    with tempfile.TemporaryDirectory(prefix='sgm_speckle_reproject_') as tmp:
        p=Path(tmp)
        for filename,index in [('left.hex',0),('right.hex',1),('lb.hex',2),('rb.hex',3),('q.hex',4),('expected.hex',5),('filtered.hex',6)]:
            (p/filename).write_text(''.join(f'{value & ((1<<102)-1):x}\n' for case in fixtures for value in case[index]))
        for filename,index in [('ranges.hex',7),('sizes.hex',8)]: (p/filename).write_text(''.join(f'{case[index]:x}\n' for case in fixtures))
        (p/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=180)
    write_json(folder/'results.json',dict(status='PASS',frames=len(fixtures),pixels=w*h*len(fixtures),removed_per_frame=removals,board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder)

if __name__=='__main__': main()
