"""Actual BT.656 TX -> RX -> UYVY unpacker, with independent complete-byte oracle."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

XY = (0x80, 0x9d, 0xab, 0xb6, 0xc7, 0xda, 0xec, 0xf1)
TB = r'''module tb;
localparam W=@W@,L=@L@,TOTAL=2*L+6,LB=2*W+20,NB=TOTAL*LB,NA=W*L*4,NM=W*L;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start=0,sv=0,ss=0,se=0,sl=0,sf=0,ack=0;
reg[7:0]sd=0;reg[15:0]cw=W,cl=L,ct=TOTAL,cf=L+3,ca0=1,ca1=L+4;reg[16:0]cb=LB;
wire tsr,sr,tv,tr,ts,te,tl,td,terr;wire[7:0]tdatum,tec;wire[63:0]obytes;
bt656_tx #(.MAX_WIDTH(W),.MAX_FIELD_LINES(L))tx(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.abort(1'b0),.start_ready(tsr),
.cfg_width(cw),.cfg_field_lines(cl),.cfg_total_lines(ct),.cfg_field1_start(cf),.cfg_active0_start(ca0),.cfg_active1_start(ca1),.cfg_line_bytes(cb),
.s_data(sd),.s_valid(sv),.s_sof(ss),.s_eol(se),.s_last(sl),.s_field(sf),.s_ready(sr),
.m_data(tdatum),.m_valid(tv),.m_ready(tr),.m_sof(ts),.m_eol(te),.m_last(tl),.done_valid(td),.done_ready(ack),.frame_error(terr),.error_code(tec),.output_bytes(obytes));
wire rsr,rr,rv,rmr,rs,re,rl,rf,rfs,rd,rerr;wire[7:0]rdata,rec;
reg link_gate=1,mr=1;
// RX completes at the final active EAV. Remaining formatter blanking is drained
// and independently byte-checked, without reopening or feeding the stopped RX.
assign tr=link_gate&&(rd||rr);
bt656_rx #(.MAX_WIDTH(W),.MAX_FIELD_LINES(L))rx(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.abort(1'b0),.start_ready(rsr),.cfg_width(16'(W)),.cfg_field_lines(16'(L)),
.s_data(tdatum),.s_valid(tv&&link_gate&&!rd),.s_last(1'b0),.s_ready(rr),
.m_data(rdata),.m_valid(rv),.m_ready(rmr),.m_sof(rs),.m_eol(re),.m_last(rl),.m_field(rf),.m_field_sof(rfs),
.done_valid(rd),.done_ready(ack),.frame_error(rerr),.error_code(rec));
wire usr,uv,us,ue,ul,ud,uerr;wire[31:0]macro;wire[7:0]uec;
yuv422_byte_unpacker #(.WIDTH(W),.HEIGHT(2*L))unpack(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start),.start_ready(usr),.cfg_order(2'd1),.abort(1'b0),
.s_data(rdata),.s_valid(rv),.s_ready(rmr),.s_sof(rs),.s_eol(re),.s_last(rl),
.m_data(macro),.m_valid(uv),.m_ready(mr),.m_sof(us),.m_eol(ue),.m_last(ul),
.done_valid(ud),.done_ready(ack),.done_error(uerr),.error_code(uec));
reg[7:0]active[0:NA-1],wirebytes[0:NB-1];reg[31:0]expected[0:NM-1];
integer cyc=0,wi=0,ri=0,mi=0,i;reg take,ht=0,hu=0;reg[10:0]pt;reg[34:0]pu;
always @(posedge clk)if(rst_n)begin
cyc=cyc+1;if(cyc>10000000)$fatal(1,"timeout");
if(ht&&(!tv||{ts,te,tl,tdatum}!==pt))$fatal(1,"TX hold");
if(hu&&(!uv||{us,ue,ul,macro}!==pu))$fatal(1,"unpacker hold");
ht=tv&&!(ce&&tr);pt={ts,te,tl,tdatum};hu=uv&&!(ce&&mr);pu={us,ue,ul,macro};
if(ce&&tv&&tr)begin
if(wi>=NB||tdatum!==wirebytes[wi]||ts!==(wi==0)||te!==(wi%LB==LB-1)||tl!==(wi==NB-1))$fatal(1,"wire byte %d",wi);wi=wi+1;end
if(ce&&rv&&rmr)begin
if(ri>=NA||rdata!==active[ri]||rs!==(ri==0)||re!==(ri%(2*W)==2*W-1)||rl!==(ri==NA-1)||rf!==(ri>=NA/2)||rfs!==(ri==0||ri==NA/2))$fatal(1,"RX active byte %d",ri);ri=ri+1;end
if(ce&&uv&&mr)begin
if(mi>=NM||macro!==expected[mi]||us!==(mi==0)||ue!==(mi%(W/2)==W/2-1)||ul!==(mi==NM-1))$fatal(1,"UYVY %d",mi);mi=mi+1;end
end
task tick;begin @(negedge clk);#1;ce=cyc%13>2;link_gate=cyc%11>2;mr=cyc%17>5;end endtask
initial begin
$readmemh("active.hex",active);$readmemh("wire.hex",wirebytes);$readmemh("macro.hex",expected);
repeat(3)@(negedge clk);#1;rst_n=1;if(!tsr||!rsr||!usr)$fatal(1,"start ready");start=1;
@(posedge clk);tick;start=0;cw=1;cl=0;ct=0;cf=0;ca0=0;ca1=0;cb=0;
for(i=0;i<NA;i=i+1)begin
sd=active[i];ss=i==0;se=i%(2*W)==2*W-1;sl=i==NA-1;sf=i>=NA/2;sv=1;take=0;
while(!take)begin @(posedge clk);take=ce&&sr;tick;end
sv=0;if(i%29==6)repeat(2)tick;
end
while(!td||!rd||!ud)tick;
if(terr||tec||rerr||rec||uerr||uec||wi!=NB||obytes!=NB||ri!=NA||mi!=NM)$fatal(1,"completion counts/error");
ce=0;ack=1;repeat(3)@(negedge clk);#1;if(!td||!rd||!ud)$fatal(1,"DONE CE hold");
ce=1;@(negedge clk);#1;ack=0;
$display("PASS BT656_TX_RX_YUV wire=%d active=%d macros=%d",wi,ri,mi);$finish;
end endmodule'''


def run(width, lines):
    folder = evidence_dir('bt656_tx_rx_yuv')
    rng = random.Random(773*width+lines)
    active = []
    macros = []
    for _ in range(width*lines):
        cb, y0, cr, y1 = [rng.randrange(256) for _ in range(4)]
        active += [cb, y0, cr, y1]
        macros.append((y0<<24)|(y1<<16)|(cb<<8)|cr)
    stream = []
    ai = 0
    for row in range(2*lines+6):
        f = int(row >= lines+3)
        valid = 1 <= row < lines+1 or lines+4 <= row < 2*lines+4
        v = int(not valid)
        stream += [255, 0, 0, XY[f*4+v*2]]
        if valid:
            stream += active[ai:ai+2*width]
            ai += 2*width
        else:
            stream += [128, 16]*width
        stream += [255, 0, 0, XY[f*4+v*2+1]]+[128, 16]*6
    assert ai == len(active) and len(stream) == (2*lines+6)*(2*width+20)
    sources = [PACKAGE/'image/bt656_tx/bt656_tx.sv', PACKAGE/'image/bt656_rx/bt656_rx.sv',
               PACKAGE/'image/yuv422_bytes/yuv422_byte_unpacker.sv']
    frozen = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    with tempfile.TemporaryDirectory(prefix='bt656_tx_rx_yuv_') as tmp:
        path = Path(tmp)
        for name, values in [('active', active), ('wire', stream), ('macro', macros)]:
            (path/(name+'.hex')).write_text(''.join(f'{v:x}\n' for v in values))
        (path/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@L@', str(lines)))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        out = execute(['vvp', path/'sim'], path, folder/'simulation.log', timeout=180)
        assert 'PASS BT656_TX_RX_YUV' in out
    assert frozen == {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    write_json(folder/'results.json', dict(status='PASS', width=width, field_lines=lines,
        wire_bytes=len(stream), active_bytes=len(active), macros=len(macros), sources=frozen,
        scope='Actual TX/RX/UYVY RTL chain, programmable line map; no normative F/V, PHY or board claim', board_tested=False))
    print(folder, flush=True)


if __name__ == '__main__':
    for profile in ((2, 1), (8, 3), (720, 4)):
        run(*profile)
