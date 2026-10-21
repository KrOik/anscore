"""Physical raster timing -> three parallel TMDS lanes -> recovered RGB/sync.
No serializer, PHY, clock-generation or board certification is implied.
"""
import hashlib
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json


def encode(value, rd):
    ones = value.bit_count()
    use_xnor = ones > 4 or (ones == 4 and value & 1 == 0)
    bits = [value & 1]
    for i in range(1, 8):
        bits.append(bits[-1] ^ ((value >> i) & 1) ^ int(use_xnor))
    low = sum(b << i for i, b in enumerate(bits))
    flag = int(not use_xnor)
    balance = 2 * sum(bits) - 8
    if rd == 0 or balance == 0:
        invert = not flag
        code = (int(invert) << 9) | (flag << 8) | (low ^ (255 if invert else 0))
        rd += balance if flag else -balance
    elif (rd > 0) == (balance > 0):
        code = 512 | (flag << 8) | (low ^ 255)
        rd += 2 * flag - balance
    else:
        code = (flag << 8) | low
        rd += balance - 2 * (1 - flag)
    return code, rd


TB = r'''module tb;
localparam HA=@HA@,HF=@HF@,HS=@HS@,HB=@HB@,VA=@VA@,VF=@VF@,VS=@VS@,VB=@VB@;
localparam TOTAL=(HA+HF+HS+HB)*(VA+VF+VS+VB)+8;
reg clk=0;always #5 clk=~clk;reg rst_n=0,start=0,stop=0;integer phase=0;
wire ready,running,done,err,hs,vs,de,sof,eol,eof,fe;wire[7:0]ec;wire[15:0]x,y;
video_timing_generator timing(.clk(clk),.rst_n(rst_n),.ce(1'b1),.pixel_tick(1'b1),
.start_valid(start),.start_ready(ready),.stop(stop),.abort(1'b0),
.cfg_h_active(16'(HA)),.cfg_h_front(16'(HF)),.cfg_h_sync(16'(HS)),.cfg_h_back(16'(HB)),
.cfg_v_active(16'(VA)),.cfg_v_front(16'(VF)),.cfg_v_sync(16'(VS)),.cfg_v_back(16'(VB)),
.cfg_hsync_positive(1'b0),.cfg_vsync_positive(1'b0),.running(running),.done_valid(done),.done_ready(1'b0),
.frame_error(err),.error_code(ec),.h_count(x),.v_count(y),.hsync(hs),.vsync(vs),.de(de),.sof(sof),.eol(eol),.eof(eof),.frame_end(fe));
wire active=phase==1&&running;
wire valid=phase==0||active||phase==2;
wire [7:0]red=(x*17+y*31)&255,green=(x*7+y*13+71)&255,blue=(x*29+y*3+19)&255;
wire[23:0]rgb=active&&de?{red,green,blue}:24'b0;
wire ide=active&&de;wire[1:0]ctl=active?{vs,hs}:2'b11;
wire[29:0]code;wire[2:0]ev,er,dv,dr,der,dde,lock;wire[23:0]decoded;wire[5:0]control;
genvar g;generate for(g=0;g<3;g=g+1)begin:lane
 tmds_encoder enc(.clk(clk),.rst_n(rst_n),.ce(1'b1),.s_data(rgb[g*8+:8]),.s_de(ide),.s_control(g==0?ctl:2'b0),
 .s_valid(valid),.s_ready(er[g]),.m_symbol(code[g*10+:10]),.m_valid(ev[g]),.m_ready(dr[g]),.running_disparity());
 tmds_decoder dec(.clk(clk),.rst_n(rst_n),.ce(1'b1),.s_symbol(code[g*10+:10]),.s_valid(ev[g]),.s_ready(dr[g]),
 .m_data(decoded[g*8+:8]),.m_de(dde[g]),.m_control(control[g*2+:2]),.m_error(der[g]),.m_valid(dv[g]),.m_ready(1'b1),.synchronized(lock[g]),.running_disparity());
end endgenerate
reg[26:0]expected[0:TOTAL-1];reg[29:0]symbols[0:TOTAL-1];integer si=0,ei=0,di=0,cyc=0;reg source_previous=0,encoded_previous=0;
always @(posedge clk)if(rst_n)begin
if(ev!=={3{source_previous}}||dv!=={3{encoded_previous}})$fatal(1,"physical cadence bubble");
source_previous=valid;encoded_previous=ev[0];
cyc=cyc+1;if(cyc>TOTAL+100)$fatal(1,"timeout");if(err)$fatal(1,"timing error");
if(valid)begin if(er!=7||si>=TOTAL)$fatal(1,"physical source stalled");
if({ctl,ide,rgb}!==expected[si])$fatal(1,"raster source mismatch %0d",si);si=si+1;end
if(ev!=0)begin if(ev!=7||dr!=7||ei>=TOTAL||code!==symbols[ei])$fatal(1,"TMDS symbols %0d",ei);ei=ei+1;end
if(dv!=0)begin if(dv!=7||der!=0||lock!=7||di>=TOTAL)$fatal(1,"decoder state");
if(dde!={3{expected[di][24]}}||decoded!==expected[di][23:0]||control[1:0]!==expected[di][26:25]&& !expected[di][24])$fatal(1,"decoded token %0d",di);
if(control[5:2]!=0)$fatal(1,"reserved channel controls");di=di+1;end
end
initial begin $readmemh("pixels.hex",expected);$readmemh("symbols.hex",symbols);
repeat(3)@(negedge clk);#1;rst_n=1;
wait(si==4);@(negedge clk);#1;phase=1;start=1;
@(negedge clk);#1;start=0;
wait(running);@(negedge clk);#1;stop=1;
wait(done);@(negedge clk);#1;phase=2;
wait(si==TOTAL);@(negedge clk);#1;phase=3;
wait(di==TOTAL);@(negedge clk);#1;if(ei!=TOTAL)$fatal(1,"counts");
$display("PASS RASTER_TMDS_RGB tokens=%0d frame_pixels=%0d",di,HA*VA);$finish;end
endmodule'''


def run(profile):
    ha,hf,hs,hb,va,vf,vs,vb=profile
    rows=[(0,0,3)]*4
    for y in range(va+vf+vs+vb):
        for x in range(ha+hf+hs+hb):
            active=x<ha and y<va
            rgb=(((x*17+y*31)&255)<<16)|(((x*7+y*13+71)&255)<<8)|((x*29+y*3+19)&255) if active else 0
            ctl=(int(not (va+vf<=y<va+vf+vs))<<1)|int(not (ha+hf<=x<ha+hf+hs))
            rows.append((rgb,int(active),ctl))
    rows += [(0,0,3)]*4
    rd=[0,0,0]; golden=[]
    controls=[0b1101010100,0b0010101011,0b0101010100,0b1010101011]
    for rgb,de,ctl in rows:
        value=0
        for lane in range(3):
            if de:
                code,rd[lane]=encode((rgb>>(8*lane))&255,rd[lane])
            else:
                code=controls[ctl if lane==0 else 0];rd[lane]=0
            value|=code<<(10*lane)
        golden.append(value)
    sources=[PACKAGE/'image/video_scanout/video_timing_generator.sv',PACKAGE/'image/tmds_codec/tmds_encoder.sv',PACKAGE/'image/tmds_codec/tmds_decoder.sv']
    frozen={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    folder=evidence_dir('raster_tmds_rgb')
    with tempfile.TemporaryDirectory(prefix='raster_tmds_rgb_') as tmp:
        p=Path(tmp);tb=TB
        for k,v in zip(('HA','HF','HS','HB','VA','VF','VS','VB'),profile):tb=tb.replace('@'+k+'@',str(v))
        (p/'tb.sv').write_text(tb,encoding='utf-8')
        (p/'pixels.hex').write_text(''.join(f'{(ctl<<25)|(de<<24)|rgb:07x}\n' for rgb,de,ctl in rows))
        (p/'symbols.hex').write_text(''.join(f'{v:08x}\n' for v in golden))
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*sources,p/'tb.sv'],p,folder/'compile.log')
        output=execute(['vvp',p/'sim'],p,folder/'simulation.log',timeout=300)
        assert 'PASS RASTER_TMDS_RGB' in output
    assert frozen=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    write_json(folder/'results.json',dict(status='PASS',profile=profile,tokens=len(rows),active_pixels=ha*va,sources=frozen,board_tested=False,scope='Actual fixed raster -> three TMDS lanes -> RGB reconstruction, independent Python symbol oracle; no serializer/PHY/board claim'))
    print(folder,flush=True)

if __name__=='__main__':
    for profile in [(7,2,3,1,5,1,2,1),(640,16,96,48,480,10,2,33)]:run(profile)
