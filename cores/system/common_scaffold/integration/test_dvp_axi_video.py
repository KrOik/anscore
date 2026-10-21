"""Unthrottled DVP sensor -> buffered receiver -> AXI Video -> pixel stream."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB = r'''module tb;
localparam W=@W@,H=@H@,N=W*H,F=6,NB=@NB@,FAST=@FAST@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,ack=0,sv=0,vs=0,hr=0;
reg[7:0]data_=0;reg[15:0]cw=W,ch=H;reg mode=0,be=0,vpol=1,hpol=1;
wire dsr,dv,dr,ds,de,dl,dd,derr;wire[23:0]dp;wire[7:0]dec;
wire[15:0]iw,ih;wire im;
dvp_rx #(.MAX_WIDTH(W),.MAX_HEIGHT(H),.FIFO_DEPTH(32))capture(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.abort(1'b0),.start_ready(dsr),
.cfg_width(cw),.cfg_height(ch),.cfg_mode(mode),.cfg_big_endian(be),.cfg_vsync_active_high(vpol),.cfg_href_active_high(hpol),
.sample_valid(sv),.vsync(vs),.href(hr),.data(data_),.m_pixel(dp),.m_valid(dv),.m_ready(dr),.m_sof(ds),.m_eol(de),.m_last(dl),
.done_valid(dd),.done_ready(ack),.frame_error(derr),.error_code(dec),.image_width(iw),.image_height(ih),.image_mode(im));
wire psr,av,ar,au,al,pd,perr;wire[23:0]ad;wire[7:0]pec;
video_stream_to_axis #(.WIDTH(W),.HEIGHT(H),.DATA_WIDTH(24))to_axis(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.abort(1'b0),.cfg_width(cw),.cfg_height(ch),.start_ready(psr),
.s_pixel(dp),.s_valid(dv),.s_ready(dr),.s_sof(ds),.s_eol(de),.s_last(dl),
.m_axis_tdata(ad),.m_axis_tvalid(av),.m_axis_tready(ar),.m_axis_tuser(au),.m_axis_tlast(al),
.done_valid(pd),.done_ready(ack),.frame_error(perr),.error_code(pec));
wire asr,air,mv,ms,me,ml,md,merr;wire[23:0]mp;wire[7:0]mec;
reg mr=1;assign ar=air;
axis_to_video_stream #(.WIDTH(W),.HEIGHT(H),.DATA_WIDTH(24))from_axis(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.abort(1'b0),.cfg_width(cw),.cfg_height(ch),.start_ready(asr),
.s_axis_tdata(ad),.s_axis_tvalid(av),.s_axis_tready(air),.s_axis_tuser(au),.s_axis_tlast(al),
.m_pixel(mp),.m_valid(mv),.m_ready(mr),.m_sof(ms),.m_eol(me),.m_last(ml),
.done_valid(md),.done_ready(ack),.frame_error(merr),.error_code(mec));
reg[7:0]sensor[0:NB-1];reg[23:0]expected[0:F*N-1];
integer cyc=0,di=0,ai=0,mi=0,off=0,f,y,x,bbase=0,bpp;reg actual_vpol,actual_hpol,actual_mode,actual_be,take;
reg ha=0,hm=0;reg[25:0]pa;reg[26:0]pm;
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>20000000)$fatal(1,"timeout");
if(ha&&(!av||{au,al,ad}!==pa))$fatal(1,"AXI hold");
if(hm&&(!mv||{ms,me,ml,mp}!==pm))$fatal(1,"pixel hold");
ha=av&&!ar;pa={au,al,ad};hm=mv&&!(ce&&mr);pm={ms,me,ml,mp};
if(derr||perr||merr)$fatal(1,"chain error %d %d %d",dec,pec,mec);
if(ce&&dv&&dr)begin
if(di>=F*N||dp!==expected[di]||ds!==(di%N==0)||de!==(di%W==W-1)||dl!==(di%N==N-1))$fatal(1,"DVP pixel %d",di);di=di+1;end
if(av&&ar)begin
if(ai>=F*N||ad!==expected[ai]||au!==(ai%N==0)||al!==(ai%W==W-1))$fatal(1,"AXI pixel %d",ai);ai=ai+1;if(!ce)off=off+1;end
if(ce&&mv&&mr)begin
if(mi>=F*N||mp!==expected[mi]||ms!==(mi%N==0)||me!==(mi%W==W-1)||ml!==(mi%N==N-1))$fatal(1,"output pixel %d",mi);mi=mi+1;end
end
task tick;begin @(negedge clk);#1;ce=FAST||cyc%13>3;mr=FAST||cyc%17>5;end endtask
task sample;input v_,h_;input[7:0]d_;begin
vs=v_;hr=h_;data_=d_;sv=1;@(posedge clk);tick;sv=0;repeat(FAST?0:7)tick;
end endtask
initial begin
$readmemh("sensor.hex",sensor);$readmemh("expected.hex",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
actual_mode=f>=2;actual_be=f>=4;actual_vpol=f%2;actual_hpol=!(f%2);bpp=actual_mode?2:1;
cw=W;ch=H;mode=actual_mode;be=actual_be;vpol=actual_vpol;hpol=actual_hpol;
if(!dsr||!psr||!asr)$fatal(1,"start ready");start=1;take=0;
while(!take)begin @(posedge clk);take=ce&&dsr&&psr&&asr;tick;end
start=0;cw=0;ch=0;mode=!actual_mode;be=!actual_be;vpol=!actual_vpol;hpol=!actual_hpol;
sample(actual_vpol,!actual_hpol,0);sample(actual_vpol,!actual_hpol,0);
sample(!actual_vpol,!actual_hpol,0);
for(y=0;y<H;y=y+1)begin
for(x=0;x<W*bpp;x=x+1)sample(!actual_vpol,actual_hpol,sensor[bbase+y*W*bpp+x]);
sample(!actual_vpol,!actual_hpol,0);
end
sample(actual_vpol,!actual_hpol,0);bbase=bbase+N*bpp;
while(!dd||!pd||!md)tick;
if(iw!=W||ih!=H||im!=actual_mode||di!=(f+1)*N||ai!=(f+1)*N||mi!=(f+1)*N)$fatal(1,"completion");
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!dd||!pd||!md)$fatal(1,"done hold");
ce=1;@(negedge clk);#1;ack=0;
end
if(!FAST&&N>1&&off==0)$fatal(1,"no CEoff AXI transactions");
$display("PASS DVP_AXI_VIDEO frames=%d pixels=%d CEoff_AXIS=%d",F,mi,off);$finish;
end endmodule'''


def run(width, height, fast=False):
    folder = evidence_dir('dvp_axi_video')
    rng = random.Random(width*71+height)
    sensor = []
    expected = []
    for f in range(6):
        for _ in range(width*height):
            value = rng.randrange(256 if f < 2 else 65536)
            if f < 2:
                sensor.append(value)
                expected.append(value)
            else:
                sensor += list(value.to_bytes(2, 'big' if f >= 4 else 'little'))
                r, g, b = value>>11, (value>>5)&63, value&31
                expected.append((((r<<3)|(r>>2))<<16)|(((g<<2)|(g>>4))<<8)|((b<<3)|(b>>2)))
    sources = [PACKAGE/'image/dvp_rx/dvp_rx.sv',
               PACKAGE/'image/axi_video_bridge/video_stream_to_axis.sv',
               PACKAGE/'image/axi_video_bridge/axis_to_video_stream.sv']
    frozen = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    with tempfile.TemporaryDirectory(prefix='dvp_axi_video_') as tmp:
        path = Path(tmp)
        for name, values in [('sensor', sensor), ('expected', expected)]:
            (path/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values))
        (path/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@H@', str(height)).replace('@NB@', str(len(sensor))).replace('@FAST@', str(int(fast))))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        out = execute(['vvp', path/'sim'], path, folder/'simulation.log', timeout=240)
        assert 'PASS DVP_AXI_VIDEO' in out
    assert frozen == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    write_json(folder/'results.json', dict(status='PASS', width=width, height=height,
        frames=6, pixels=len(expected), sensor_bytes=len(sensor), sample_interval_clocks=1 if fast else 8,
        continuous_input=fast, sources=frozen, board_tested=False,
        scope='Real DVP RX -> AXI Video -> pixel chain; both polarities, gray8/RGB565, endian, CEoff AXI, FIFO/stalls; no CDC/PHY/board claim'))
    print(folder, flush=True)


if __name__ == '__main__':
    for geometry in ((1, 1), (7, 5), (320, 4), (320, 4, True)):
        run(*geometry)
