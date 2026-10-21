"""Actual RAW LSC -> MHC RGB12 -> three lockstep tone LUTs -> RGB888."""
import hashlib
import tempfile
from pathlib import Path
import numpy as np
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json
import test_lens_malvar as base

def tone(value,nodes):
    index=min(7,value*8//4095)
    remainder=value*8-index*4095
    return (nodes[index]*(4095-remainder)+nodes[index+1]*remainder+2047)//4095

def main():
    w,h=9,7
    folder=evidence_dir('lens_malvar_gamma')
    rng=np.random.default_rng(78184)
    nodes=[0,18,83,63,151,174,220,239,255]
    frames=[];meshes=[];middle=[];rgb12=[];rgb8=[];patterns=[0,1,2,3,0,3]
    for f,pattern in enumerate(patterns):
        frame=rng.integers(0,4096,(h,w),dtype=np.int64)
        mesh=rng.integers(1024,14000,(4,3,3),dtype=np.int64)
        if f==4:frame[:]=1377;mesh[:]=4096
        mapped,sat=base.lens_oracle(frame,mesh,pattern)
        color=base.malvar_oracle(mapped,pattern)
        frames.extend(frame.ravel());meshes.extend(mesh.ravel());middle.extend((s<<12)|int(v) for v,s in zip(mapped.ravel(),sat));rgb12.extend(color)
        rgb8.extend((tone((v>>24)&4095,nodes)<<16)|(tone((v>>12)&4095,nodes)<<8)|tone(v&4095,nodes) for v in color)
    tb=base.TB.replace('@W@',str(w)).replace('@H@',str(h))
    tb=tb.replace('wire dsr,mv', 'wire gr,dsr,mv')
    tb=tb.replace('.m_ready(mr),.m_sof(ms)', '.m_ready(gr),.m_sof(ms)')
    tb=tb.replace('held=mv&&!(ce&&mr)', 'held=mv&&!(ce&&gr)')
    tb=tb.replace('if(ce&&mv&&mr)', 'if(ce&&mv&&gr)')
    extra='''reg gb=0,gv=0,gcommit=0,gack=0;reg[3:0]gi=0;reg[7:0]gvalue=0;
wire[2:0]gbready,gwready,gcready,gcdone,gcerror,gactive,gsready,gready,gvalid,gsof,geol,glast,gdone,gerror;
wire[7:0]gpixel[0:2];wire[3:0]gcodes[0:2],gcfgcodes[0:2];
wire[23:0]tone_rgb={gpixel[0],gpixel[1],gpixel[2]};
assign gr=&gready;
reg[7:0]nodes[0:8];reg[23:0]toned_expected[0:F*N-1];integer tone_count=0;reg toneheld=0;reg[26:0]tone_token;
always @(posedge clk)if(rst_n)begin
if(gready!={3{gready[0]}}||gvalid!={3{gvalid[0]}}||gdone!={3{gdone[0]}})$fatal(1,"RGB tone lanes lost lockstep");
if(toneheld&&(!gvalid[0]||{tone_rgb,gsof[0],geol[0],glast[0]}!==tone_token))$fatal(1,"tone output hold");
toneheld=gvalid[0]&&!(ce&&mr);tone_token={tone_rgb,gsof[0],geol[0],glast[0]};
if(ce&&gvalid[0]&&mr)begin
if(tone_rgb!==toned_expected[tone_count]||gsof[0]!==(tone_count%N==0)||geol[0]!==(tone_count%W==W-1)||glast[0]!==(tone_count%N==N-1))$fatal(1,"RGB tone %d got%h expected%h",tone_count,tone_rgb,toned_expected[tone_count]);
tone_count=tone_count+1;end
end
'''
    for ch in range(3):
        high=35-ch*12
        extra+=f'''raw_gamma #(.WIDTH(W),.HEIGHT(H),.BITS(12),.OUT_BITS(8),.INDEX_BITS(3)) gamma{ch}(
.clk(clk),.rst_n(rst_n),.ce(ce),.cfg_begin_valid(gb),.cfg_begin_ready(gbready[{ch}]),.cfg_index(gi),.cfg_value(gvalue),.cfg_valid(gv),.cfg_ready(gwready[{ch}]),
.cfg_commit_valid(gcommit),.cfg_commit_ready(gcready[{ch}]),.cfg_abort(1'b0),.cfg_done_valid(gcdone[{ch}]),.cfg_done_ready(gack),.cfg_error(gcerror[{ch}]),.cfg_error_code(gcfgcodes[{ch}]),.table_active_valid(gactive[{ch}]),
.start_valid(start),.start_ready(gsready[{ch}]),.abort(1'b0),.s_pixel(rgb[{high}:{high-11}]),.s_valid(mv),.s_ready(gready[{ch}]),.s_sof(ms),.s_eol(me),.s_last(ml),
.m_pixel(gpixel[{ch}]),.m_valid(gvalid[{ch}]),.m_ready(mr),.m_sof(gsof[{ch}]),.m_eol(geol[{ch}]),.m_last(glast[{ch}]),.done_valid(gdone[{ch}]),.done_ready(ack),.frame_error(gerror[{ch}]),.error_code(gcodes[{ch}]));
'''
    tb=tb.replace('reg[11:0]pixels',extra+'\nreg[11:0]pixels',1)
    setup='''$readmemh("nodes.mem",nodes);$readmemh("toned.mem",toned_expected);
ce=1;gb=1;#1;if(gbready!=3'b111)$fatal(1,"gamma table begin");@(negedge clk);#1;gb=0;
for(i=0;i<9;i=i+1)begin gv=1;gi=i;gvalue=nodes[i];#1;if(gwready!=3'b111)$fatal(1,"gamma write");@(negedge clk);#1;end
gv=0;gcommit=1;#1;if(gcready!=3'b111)$fatal(1,"gamma commit");@(negedge clk);#1;gcommit=0;
if(gcerror||gcdone!=3'b111||gactive!=3'b111)$fatal(1,"gamma publish");gack=1;@(negedge clk);#1;gack=0;
'''
    tb=tb.replace('for(f=0;f<F;f=f+1)begin',setup+'\nfor(f=0;f<F;f=f+1)begin',1)
    tb=tb.replace('cerror||!lsr||!dsr','cerror||!lsr||!dsr||gsready!=3\'b111')
    tb=tb.replace('while(!ldone||!ddone)', 'while(!ldone||!ddone||gdone!=3\'b111)')
    tb=tb.replace('||lcode||dcode)', '||lcode||dcode||gerror||tone_count!=(f+1)*N)')
    tb=tb.replace('if(!ldone||!ddone)', 'if(!ldone||!ddone||gdone!=3\'b111)')
    tb=tb.replace('PASS LENS_MALVAR','PASS LENS_MALVAR_GAMMA')
    sources=[PACKAGE/'image/lens_shading/lens_shading.sv',PACKAGE/'image/malvar_demosaic/malvar_demosaic.sv',PACKAGE/'image/raw_gamma/raw_gamma.sv']
    with tempfile.TemporaryDirectory(prefix='lens_malvar_gamma_') as tmp:
        p=Path(tmp)
        for name,values in [('pixels',frames),('meshes',meshes),('mid',middle),('expected',rgb12),('patterns',patterns),('nodes',nodes),('toned',rgb8)]:
            (p/(name+'.mem')).write_text('\n'.join(f'{int(v):x}' for v in values))
        (p/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=180)
    write_json(folder/'results.json',dict(status='PASS',frames=6,pixels=6*w*h,output='RGB888',board_tested=False,
        sources={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}))
    print(folder)

if __name__=='__main__':main()
