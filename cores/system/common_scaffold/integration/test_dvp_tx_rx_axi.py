"""Fixed-tick DVP TX -> DVP RX -> AXI Video -> pixels, independent quantization oracle."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB = r'''module tb;
localparam W=@W@,H=@H@,N=W*H,F=6,NB=@NB@,FAST=@FAST@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,ack=0; wire sv,vs,hr;
wire[7:0]data_;reg[15:0]cw=W,ch=H;reg mode=0,be=0,vpol=1,hpol=1;
reg[23:0]source_pixel=0;reg source_valid=0,source_sof=0,source_eol=0,source_last=0;
wire tsr,tr,td,terr;wire[7:0]tec;wire[15:0]tw,th;wire tm;
dvp_tx #(.MAX_WIDTH(W),.MAX_HEIGHT(H),.FIFO_DEPTH(32))transmit(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(tsr),.abort(1'b0),
.cfg_width(cw),.cfg_height(ch),.cfg_mode(mode),.cfg_big_endian(be),.cfg_vsync_active_high(vpol),.cfg_href_active_high(hpol),
.cfg_hblank(16'd3),.cfg_vblank_lines(16'd2),.cfg_byte_period(FAST?16'd1:16'd8),
.s_pixel(source_pixel),.s_valid(source_valid),.s_ready(tr),.s_sof(source_sof),.s_eol(source_eol),.s_last(source_last),
.data(data_),.vsync(vs),.href(hr),.sample_valid(sv),.done_valid(td),.done_ready(ack),.frame_error(terr),.error_code(tec),
.image_width(tw),.image_height(th),.image_mode(tm));
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
reg[23:0]sensor[0:NB-1];reg[23:0]expected[0:F*N-1];
integer cyc=0,di=0,ai=0,mi=0,off=0,f,y,x,bbase=0,bpp;reg actual_vpol,actual_hpol,actual_mode,actual_be,take;
reg ha=0,hm=0;reg[25:0]pa;reg[26:0]pm;
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>20000000)$fatal(1,"timeout");
if(ha&&(!av||{au,al,ad}!==pa))$fatal(1,"AXI hold");
if(hm&&(!mv||{ms,me,ml,mp}!==pm))$fatal(1,"pixel hold");
ha=av&&!ar;pa={au,al,ad};hm=mv&&!(ce&&mr);pm={ms,me,ml,mp};
if(terr||derr||perr||merr)$fatal(1,"chain error %d %d %d",dec,pec,mec);
if(ce&&dv&&dr)begin
if(di>=F*N||dp!==expected[di]||ds!==(di%N==0)||de!==(di%W==W-1)||dl!==(di%N==N-1))$fatal(1,"DVP pixel %d",di);di=di+1;end
if(av&&ar)begin
if(ai>=F*N||ad!==expected[ai]||au!==(ai%N==0)||al!==(ai%W==W-1))$fatal(1,"AXI pixel %d",ai);ai=ai+1;if(!ce)off=off+1;end
if(ce&&mv&&mr)begin
if(mi>=F*N||mp!==expected[mi]||ms!==(mi%N==0)||me!==(mi%W==W-1)||ml!==(mi%N==N-1))$fatal(1,"output pixel %d",mi);mi=mi+1;end
end
task tick;begin @(negedge clk);#1;ce=FAST||cyc%13>3;mr=FAST||cyc%17>5;end endtask
initial begin
$readmemh("sensor.hex",sensor);$readmemh("expected.hex",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
actual_mode=f>=2;actual_be=f>=4;actual_vpol=f%2;actual_hpol=!(f%2);bpp=actual_mode?2:1;
cw=W;ch=H;mode=actual_mode;be=actual_be;vpol=actual_vpol;hpol=actual_hpol;
if(!tsr||!dsr||!psr||!asr)$fatal(1,"start ready");start=1;take=0;
while(!take)begin @(posedge clk);take=ce&&tsr&&dsr&&psr&&asr;tick;end
start=0;
for(x=0;x<N;x=x+1)begin
source_pixel=sensor[f*N+x];source_valid=1;source_sof=x==0;source_eol=x%W==W-1;source_last=x==N-1;
take=0;while(!take)begin @(posedge clk);take=ce&&tr;tick;end
end
source_valid=0;
while(!td||!dd||!pd||!md)tick;

if(iw!=W||ih!=H||im!=actual_mode||di!=(f+1)*N||ai!=(f+1)*N||mi!=(f+1)*N)$fatal(1,"completion");
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!td||!dd||!pd||!md)$fatal(1,"done hold");
ce=1;@(negedge clk);#1;ack=0;
end
if(!FAST&&N>1&&off==0)$fatal(1,"no CEoff AXI transactions");
$display("PASS DVP_TX_RX_AXI frames=%d pixels=%d CEoff_AXIS=%d",F,mi,off);$finish;
end endmodule'''


def run(width, height, fast=False):
    folder = evidence_dir('dvp_tx_rx_axi')
    rng = random.Random(width*71+height)
    sensor = []
    expected = []
    for f in range(6):
        for _ in range(width*height):
            value = rng.randrange(256 if f < 2 else 1<<24)
            sensor.append(value)
            if f < 2:
                expected.append(value)
            else:
                r,g,b=value>>19,(value>>10)&63,(value>>3)&31
                expected.append((((r<<3)|(r>>2))<<16)|(((g<<2)|(g>>4))<<8)|((b<<3)|(b>>2)))
    sources = [PACKAGE/'image/dvp_tx/dvp_tx.sv', PACKAGE/'image/dvp_rx/dvp_rx.sv',
               PACKAGE/'image/axi_video_bridge/video_stream_to_axis.sv',
               PACKAGE/'image/axi_video_bridge/axis_to_video_stream.sv']
    frozen = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    with tempfile.TemporaryDirectory(prefix='dvp_tx_rx_axi_') as tmp:
        path = Path(tmp)
        for name, values in [('sensor', sensor), ('expected', expected)]:
            (path/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values))
        (path/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@H@', str(height)).replace('@NB@', str(len(sensor))).replace('@FAST@', str(int(fast))))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        out = execute(['vvp', path/'sim'], path, folder/'simulation.log', timeout=240)
        assert 'PASS DVP_TX_RX_AXI' in out
    assert frozen == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    write_json(folder/'results.json', dict(status='PASS', width=width, height=height,
        frames=6, pixels=len(expected), source_pixels=len(sensor), sample_interval_clocks=1 if fast else 8,
        continuous_input=fast, sources=frozen, board_tested=False,
        scope='Real fixed-tick DVP TX -> DVP RX -> AXI Video -> pixel chain; both polarities, gray8/RGB565, endian, CEoff AXI, FIFO/stalls; no CDC/PHY/board claim'))
    print(folder, flush=True)


if __name__ == '__main__':
    for geometry in ((1, 1), (7, 5), (320, 4), (320, 4, True)):
        run(*geometry)
