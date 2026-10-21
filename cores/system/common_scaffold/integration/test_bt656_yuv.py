"""Real BT.656 field-raster receiver -> UYVY byte-unpacker integration."""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

XY = (0x80, 0x9d, 0xab, 0xb6, 0xc7, 0xda, 0xec, 0xf1)


def trs(field, vertical, horizontal):
    return [255, 0, 0, XY[field*4+vertical*2+horizontal]]


TB = r'''module tb;
localparam W=@W@,L=@L@,NP=W*L,NB=@NB@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,done_ready=0;
reg[15:0]cfg_width=W,cfg_field_lines=L;reg[7:0]s_data;
wire start_ready,s_ready,done_valid,frame_error;wire[7:0]error_code;
wire[7:0]m_data;wire m_valid,m_ready,m_sof,m_eol,m_last,m_field,m_field_sof;
bt656_rx #(.MAX_WIDTH(W),.MAX_FIELD_LINES(L)) rx(.*);
wire[31:0]macro;wire uv,ur,us,ue,ul,ud,ude,usr;
wire[7:0]uec;reg ready_=0;
assign ur=ready_;
yuv422_byte_unpacker #(.WIDTH(W),.HEIGHT(L*2)) unpack(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(usr),.cfg_order(2'd1),.abort(abort),
.s_data(m_data),.s_valid(m_valid),.s_ready(m_ready),.s_sof(m_sof),.s_eol(m_eol),.s_last(m_last),
.m_data(macro),.m_valid(uv),.m_ready(ur),.m_sof(us),.m_eol(ue),.m_last(ul),
.done_valid(ud),.done_ready(done_ready),.done_error(ude),.error_code(uec));
reg[7:0]bytes_[0:NB-1];reg[31:0]expected[0:NP-1];
integer i,got=0,raw_bytes=0,cycle=0;reg take,held=0;reg[34:0]token;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>3000000)$fatal(1,"timeout");
if(rst_n)begin
if(held&&(!uv||{macro,us,ue,ul}!==token))$fatal(1,"macro hold");
held=uv&&!(ce&&ur);token={macro,us,ue,ul};
if(ce&&m_valid&&m_ready)begin
if(m_sof!==(raw_bytes==0)||m_eol!==(raw_bytes%(W*2)==W*2-1)||m_last!==(raw_bytes==W*L*4-1)||m_field!==(raw_bytes>=W*L*2)||m_field_sof!==(raw_bytes==0||raw_bytes==W*L*2))$fatal(1,"field/line byte metadata %d",raw_bytes);
raw_bytes=raw_bytes+1;
end
if(ce&&uv&&ur)begin
if(got>=NP||macro!==expected[got]||us!==(got==0)||ue!==(got%(W/2)==W/2-1)||ul!==(got==NP-1))$fatal(1,"macro %d got%h expected%h",got,macro,expected[got]);
got=got+1;
end
end end
task tick;begin @(negedge clk);#1;ce=cycle%11>1;ready_=cycle%7>2;end endtask
initial begin
$readmemh("bytes.mem",bytes_);$readmemh("macros.mem",expected);
repeat(3)@(negedge clk);#1;rst_n=1;
if(!start_ready||!usr)$fatal(1,"start ready");start_valid=1;@(posedge clk);tick;start_valid=0;
cfg_width=1;cfg_field_lines=0;
for(i=0;i<NB;i=i+1)begin
s_data=bytes_[i];s_last=i==NB-1;s_valid=1;take=0;
while(!take)begin @(posedge clk);take=ce&&s_ready;tick;end
s_valid=0;if(i%13==4)tick;
end
while(!done_valid||!ud)tick;
if(frame_error||error_code||ude||uec||got!=NP||raw_bytes!=W*L*4)$fatal(1,"result got%d bytes%d errors%h/%h",got,raw_bytes,error_code,uec);
ce=0;done_ready=1;repeat(3)@(negedge clk);#1;if(!done_valid||!ud)$fatal(1,"DONE CE hold");
ce=1;@(negedge clk);#1;done_ready=0;
$display("PASS BT656_YUV width=%d fieldlines=%d macro=%d bytes=%d",W,L,got,raw_bytes);$finish;
end endmodule'''


def run(width, lines):
    folder = evidence_dir('bt656_yuv')
    rng = random.Random(width*13+lines)
    stream = []
    macros = []
    for field in range(2):
        for _ in range(2):
            stream += trs(field, 1, 0)+[128, 16, 128, 16]*2+trs(field, 1, 1)+[0x55]*9
        for line in range(lines):
            stream += trs(field, 0, 0)
            for x in range(width//2):
                y0, y1, cb, cr = [rng.randrange(256) for _ in range(4)]
                if line == 0 and x == 0:
                    cb, y0, cr, y1 = 255, 0, 0, 0x80
                macros.append((y0 << 24) | (y1 << 16) | (cb << 8) | cr)
                stream += [cb, y0, cr, y1]
            stream += trs(field, 0, 1)
            if not (field == 1 and line == lines-1):
                stream += [0x55]*12
    sources = [PACKAGE/'image/bt656_rx/bt656_rx.sv',
               PACKAGE/'image/yuv422_bytes/yuv422_byte_unpacker.sv']
    hashes = {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    with tempfile.TemporaryDirectory(prefix='bt656_yuv_') as tmp:
        path = Path(tmp)
        (path/'bytes.mem').write_text('\n'.join(f'{v:02x}' for v in stream))
        (path/'macros.mem').write_text('\n'.join(f'{v:08x}' for v in macros))
        (path/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@L@', str(lines)).replace('@NB@', str(len(stream))))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        execute(['vvp', path/'sim'], path, folder/'simulation.log', timeout=180)
    assert hashes == {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    write_json(folder/'results.json', dict(status='PASS', width=width, field_lines=lines,
        fields=2, macros=len(macros), input_bytes=len(stream), sources=hashes,
        board_tested=False, scope='healthy field-raster RTL integration; no deinterlacing/PHY claim'))
    print(folder, flush=True)


if __name__ == '__main__':
    for geometry in ((2, 1), (8, 3), (720, 4)):
        run(*geometry)
