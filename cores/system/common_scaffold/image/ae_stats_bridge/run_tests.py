"""End-to-end real ISP statistics RAM -> bridge -> AE regression."""
from pathlib import Path
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'integration'))
from tooling import ROOT, execute, evidence_dir, write_json
import hashlib
import random

def bridge_cases(temp, folder):
    rng = random.Random(325)
    statements = []
    for case in range(45):
        n = (0,65,1,64)[case] if case < 4 else rng.randint(1,64)
        total = count = sat = 0
        bad = n in (0,65)
        for i in range(min(n,64)):
            c = rng.randint(1,15)
            s = rng.randint(0,c)
            value = c*rng.randint(0,65535)
            if case==4 and i==0: c=0;bad=True
            if case==5 and i==0: s=c+1;bad=True
            statements.append(f"mem[{i}]=(77'd{value}<<8) | (77'd{s}<<68) | 77'd{c};")
            total += value;count += c;sat += s
        if n in (0,65): total=count=sat=0
        statements.append(f"request(7'd{n},32'd{case});")
        statements.append(f"check(48'd{total},32'd{count},32'd{sat},32'd{case},1'b{int(bad)});")
    body='\n'.join(statements)
    tb = '''`timescale 1ns/1ps
module tb_bridge;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,rn=0,rb=0,ready=0;reg [6:0] nr=0;reg[31:0]fid=0;
reg[1:0]done=3;reg[76:0]mem[0:63];reg[76:0]data;
wire bank;wire[5:0]addr;wire valid,err,overrun;wire[47:0]sum;wire[31:0]count,sat,id,drops;
always @(posedge clk) data<=mem[addr];
ispstats_ae_bridge #(.CNTW(8),.SUMW(20),.ENW(1)) d(
.clk(clk),.rst_n(rst_n),.res_new(rn),.res_new_bank(rb),.frame_records(nr),.frame_id(fid),
.frame_error(1'b0),.res_done(done),.res_bank(bank),.res_addr(addr),.res_data(data),
.stats_valid(valid),.stats_ready(ready),.stats_luma_sum(sum),.stats_count(count),
.stats_saturated(sat),.stats_frame_id(id),.stats_overflow(err),.overrun(overrun),.dropped_frames(drops));
task request(input[6:0]n,input[31:0]i);begin
@(negedge clk);nr=n;fid=i;rn=1;@(negedge clk);rn=0;
end endtask
task check(input[47:0]s,input[31:0]c,t,f,input e);begin
wait(valid);repeat(5)begin @(negedge clk);
if(!valid||sum!==s||count!==c||sat!==t||id!==f||err!==e) $fatal(1,"bridge numeric/stall frame %d",f);
end
ready=1;@(negedge clk);ready=0;
end endtask
initial begin #1000000;$fatal(1,"timeout");end
initial begin
repeat(3)@(negedge clk);rst_n=1;
BODY
// Bank invalidation and a simultaneous replacement invalidate an active read.
mem[0]=77'd257;request(1,100);request(1,101);
wait(valid);if(!err||!overrun||drops!==1) $fatal(1,"read overrun");
ready=1;@(negedge clk);ready=0;
// A completed snapshot stays stable if a later frame is dropped.
request(1,102);wait(valid);request(1,103);
if(!valid||id!==102||err||drops!==2) $fatal(1,"output overrun stability");
ready=1;@(negedge clk);ready=0;
done=0;request(1,104);wait(valid);if(!err) $fatal(1,"invalid bank");
@(negedge clk);rst_n=0;@(negedge clk);
if(valid||overrun||drops) $fatal(1,"reset abort");
$display("BRIDGE PASS 45 numerical cases + bank/overrun/reset");$finish;
end endmodule
'''.replace('BODY',body)
    path=Path(temp)/'tb_bridge.sv';path.write_text(tb,encoding='utf-8')
    binary=Path(temp)/'bridge.vvp'
    execute(['iverilog','-g2012','-s','tb_bridge','-o',binary,HERE/'ispstats_ae_bridge.sv',path],ROOT,folder/'bridge_compile.log')
    output=execute(['vvp',binary],ROOT,folder/'bridge_simulation.log')
    if 'BRIDGE PASS' not in output: raise RuntimeError('bridge success marker missing')
    print(output.strip())

HERE = Path(__file__).resolve().parent
def main():
    folder = evidence_dir('stats_ae_bridge')
    sources = [ROOT/'cores/signal_processing/dsp_isp_library/isp/ispstats/rtl/ispstats_stream.sv',
               HERE/'ispstats_ae_bridge.sv', HERE.parent/'auto_exposure/img_ae_controller.v',
               HERE/'tb_stats_ae.sv']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    with tempfile.TemporaryDirectory(prefix='stats_ae_') as temp:
        bridge_cases(temp, folder)
        binary = Path(temp)/'sim.vvp'
        execute(['iverilog','-g2012','-s','tb_stats_ae','-o',binary,*sources], ROOT, folder/'compile.log')
        output = execute(['vvp',binary],ROOT,folder/'simulation.log')
        if 'STATS_AE PASS' not in output:
            raise RuntimeError('success marker missing')
    write_json(folder/'result.json', {'status':'PASS','board_tested':False,'sources':hashes})
    print(output.strip())
    print(folder)
if __name__=='__main__': main()
