"""Real automatic multiscale descriptors wired to exhaustive Hamming matching."""
from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import tempfile
import numpy as np

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from integration.tooling import ROOT, PACKAGE, evidence_dir, execute, write_json

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def metadata(row):
    _, angle, valid, _, _, x, y, level, score = row
    return (level << 46) | (x << 30) | (y << 14) | (score << 6) | (angle << 2) | (valid << 1)

def main():
    folder = evidence_dir('multiscale_match')
    features = load('multiscale_oracle', PACKAGE/'image/multiscale_features/run_tests.py')
    matcher = load('matcher_oracle', PACKAGE/'image/descriptor_match/test_descriptor_match.py')
    w, h, levels, radius, threshold = 35, 33, 2, 3, 15
    rng = np.random.default_rng(5107)
    a = rng.integers(0, 256, (h, w), dtype=np.int64)
    b = rng.integers(0, 256, (h, w), dtype=np.int64)
    flat = np.full((h, w), 127, dtype=np.int64)
    pairs = [(a, a.copy()), (a, np.roll(a, 1, axis=1)), (b, np.rot90(b[:33, :33]).take(range(w), axis=1, mode='wrap')),
             (flat, a), (a, flat)]
    configs = [(256, 0, False, 4, 5), (256, 1, True, 4, 5), (90, 3, True, 3, 4),
               (256, 0, False, 4, 5), (256, 0, False, 4, 5)]
    frames = [frame for pair in pairs for frame in pair]
    descriptor_rows = [features.oracle(frame, levels, radius, threshold)[0] for frame in frames]
    assert max(map(len, descriptor_rows)) <= 256
    assert any(row[7] == 1 for rows in descriptor_rows for row in rows), 'must exercise second scale'
    expected = []
    ends = []
    for i, config in enumerate(configs):
        refs = [(r[0], metadata(r), not r[2]) for r in descriptor_rows[2*i]]
        queries = [(r[0], metadata(r), not r[2]) for r in descriptor_rows[2*i+1]]
        for qi, q in enumerate(queries):
            ri, rm, best, second, reason = matcher.oracle(q, refs, *config)
            value = qi
            for item, bits in ((ri, 16), (q[1], 48), (rm, 48), (best, 9), (second, 9), (reason, 4)):
                value = (value << bits) | item
            expected.append(value)
        ends.append(len(expected))
    with tempfile.TemporaryDirectory(prefix='multiscale_match_') as tmp:
        p = Path(tmp)
        (p/'pixels.mem').write_text('\n'.join(f'{int(v):x}' for frame in frames for v in frame.ravel()))
        (p/'expected.mem').write_text('\n'.join(f'{v:x}' for v in expected) or '0')
        (p/'counts.mem').write_text('\n'.join(f'{len(rows):x}' for rows in descriptor_rows))
        (p/'ends.mem').write_text('\n'.join(f'{v:x}' for v in ends))
        commands = '\n'.join(f"run_pair({i},9'd{c[0]},9'd{c[1]},1'b{int(c[2])},16'd{c[3]},16'd{c[4]});" for i,c in enumerate(configs))
        tb = f'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,cfg_valid=0,s_valid=0,s_sof=0,s_eol=0,done_ready=0;
reg [7:0] cfg_threshold={threshold},s_pixel=0;
wire cfg_ready,s_ready,m_orientation_valid,m_valid,done_valid,frame_error;
wire [255:0]m_descriptor;wire[3:0]m_angle,error_code;
wire[15:0]m_x,m_y,m_original_x,m_original_y;wire[1:0]m_level;wire[7:0]m_score;
wire m_ready;
multiscale_features_frame #(.WIDTH({w}),.HEIGHT({h}),.LEVELS({levels}),.RADIUS({radius}),
.PATTERN_FILE("{(PACKAGE/'image/oriented_brief/pattern_r3.mem').as_posix()}")) front(.*);
reg reference_frame=1,launch=0,release_set=0,result_ready=0;
reg[8:0]limit=256,gap=0;reg ratio=0;reg[15:0]num=4,den=5;
wire load_ready,start_ready,release_ready,result_valid,match_done,match_error;
wire[3:0]match_code,reason;wire[15:0]qc,rc,qi,ri;
wire[47:0]qm,rm;wire[8:0]best,second;
wire[47:0]load_meta={{m_level,m_original_x,m_original_y,m_score,m_angle,m_orientation_valid,1'b0}};
assign m_ready=load_ready;
descriptor_match #(.DESC_BITS(256),.CAPACITY(256)) match_core(
.clk(clk),.rst_n(rst_n),.ce(ce),.load_valid(m_valid),.load_reference(reference_frame),
.load_descriptor(m_descriptor),.load_metadata(load_meta),.load_invalid(!m_orientation_valid),.load_ready(load_ready),
.start_valid(launch),.start_ready(start_ready),.max_distance(limit),.min_gap(gap),.ratio_enable(ratio),.ratio_num(num),.ratio_den(den),
.release_valid(release_set),.release_ready(release_ready),.query_count(qc),.reference_count(rc),
.m_valid(result_valid),.m_ready(result_ready),.m_query_index(qi),.m_reference_index(ri),
.m_query_metadata(qm),.m_reference_metadata(rm),.m_best(best),.m_second(second),.m_reason(reason),
.done(match_done),.error(match_error),.error_code(match_code));
reg[7:0]pixels[0:{len(frames)*w*h-1}];reg[159:0]expected[0:{max(1,len(expected))-1}];
reg[31:0]counts[0:{len(frames)-1}],ends[0:{len(pairs)-1}];
integer cycle=0,got=0,done_count=0,loaded=0,i;reg take,held_valid=0;reg[159:0]held;
reg[31:0]random_state=71823;
wire[159:0]token={{qi,ri,qm,rm,best,second,reason}};
always @(posedge clk)begin
cycle=cycle+1;if(cycle>20000000)$fatal(1,"timeout");
if(rst_n)begin
if(match_error)$fatal(1,"matcher error %d",match_code);
if(held_valid&&(!result_valid||token!==held))$fatal(1,"held match output changed");
held_valid=result_valid&&(!ce||!result_ready);held=token;
if(ce&&m_valid&&m_ready)loaded=loaded+1;
if(ce&&match_done)done_count=done_count+1;
if(ce&&result_valid&&result_ready)begin
if(got>={len(expected)}||token!==expected[got])$fatal(1,"match %d actual=%h expected=%h",got,token,expected[got]);
got=got+1;end
end else held_valid=0;
end
task tick;begin @(negedge clk);random_state=random_state^(random_state<<13);random_state=random_state^(random_state>>17);random_state=random_state^(random_state<<5);
ce=random_state[0]|random_state[1];result_ready=random_state[2];end endtask
task capture(input integer f);integer count_before;begin
count_before=loaded;i=0;
while(i<{w*h})begin s_valid=1;s_pixel=pixels[f*{w*h}+i];s_sof=i==0;s_eol=i%{w}=={w-1};
@(posedge clk);take=ce&&s_ready;if(take)i=i+1;tick;end s_valid=0;
while(!done_valid)tick;
if(frame_error||error_code||loaded-count_before!=counts[f])$fatal(1,"front completion f=%d",f);
repeat(3)tick;if(!done_valid)$fatal(1,"done not held");
ce=1;done_ready=1;@(posedge clk);@(negedge clk);done_ready=0;
end endtask
task run_pair(input integer pairno,input[8:0]lim,g,input rat,input[15:0]n,d);integer old_done;begin
reference_frame=1;capture(2*pairno);reference_frame=0;capture(2*pairno+1);
if(rc!=counts[2*pairno]||qc!=counts[2*pairno+1])$fatal(1,"table count");
limit=lim;gap=g;ratio=rat;num=n;den=d;
ce=1;old_done=done_count;launch=1;#1;if(!start_ready)$fatal(1,"start not ready");@(posedge clk);@(negedge clk);launch=0;
while(!release_ready)tick;
// Empty query transactions pulse done immediately at launch. Others at final acceptance.
while(done_count==old_done)tick;
if(got!=ends[pairno]||done_count!=old_done+1)$fatal(1,"transaction completion %d got=%d done=%d",pairno,got,done_count-old_done);
ce=1;release_set=1;@(posedge clk);@(negedge clk);release_set=0;
if(qc||rc)$fatal(1,"tables not released");
end endtask
initial begin
$readmemh("pixels.mem",pixels);$readmemh("expected.mem",expected);$readmemh("counts.mem",counts);$readmemh("ends.mem",ends);
repeat(3)@(negedge clk);rst_n=1;cfg_valid=1;@(posedge clk);@(negedge clk);cfg_valid=0;
{commands}
$display("PASS automatic multiscale-to-matcher {len(pairs)} pairs {len(expected)} queries");$finish;
end endmodule'''
        (p/'tb.sv').write_text(tb)
        sources = [PACKAGE/'image/multiscale_features/multiscale_features_frame.sv', PACKAGE/'image/descriptor_match/descriptor_match.sv']
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'], ROOT, folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=600)
    write_json(folder/'results.json',dict(status='PASS',pairs=len(pairs),frames=len(frames),queries=len(expected),
        descriptors_per_frame=list(map(len,descriptor_rows)),board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder)

if __name__ == '__main__':
    main()
