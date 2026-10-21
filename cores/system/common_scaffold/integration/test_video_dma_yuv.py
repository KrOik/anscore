"""Real 2D AXI write/read -> YUV byte pack -> unpack integration.

The AXI model holds response tokens under backpressure. Final simulated RAM
is independently compared in Python, including untouched row-stride holes.
"""
import hashlib
import random
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TB = r'''module tb;
localparam W=@W@,H=@H@,N=W*H/2,F=4,ROW=W*2,STRIDE=ROW+12,EXPECTED_BURSTS=@BURSTS@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,abort=0,start_valid=0,cfg_write=0,done_ready=0;
reg[31:0]cfg_base,cfg_row_bytes=ROW,cfg_stride=STRIDE;
reg[15:0]cfg_rows=H;wire start_ready,done_valid;wire[7:0]error_code;wire[31:0]bytes_done;
reg[31:0]s_data;reg[3:0]s_keep=15;reg s_valid=0,s_eol=0,s_last=0;wire s_ready;
wire[31:0]m_data;wire[3:0]m_keep;wire m_valid,m_ready,m_eol,m_last;
wire[31:0]m_axi_awaddr,m_axi_araddr,m_axi_wdata;
wire[7:0]m_axi_awlen,m_axi_arlen;wire[2:0]m_axi_awsize,m_axi_arsize;
wire[1:0]m_axi_awburst,m_axi_arburst;wire m_axi_awvalid,m_axi_arvalid,m_axi_wvalid,m_axi_wlast;
wire[3:0]m_axi_wstrb;wire m_axi_bready,m_axi_rready;
wire m_axi_awready,m_axi_arready,m_axi_wready;
reg[1:0]m_axi_bresp=0,m_axi_rresp=0;reg m_axi_bvalid=0,m_axi_rvalid=0;
wire[31:0]m_axi_rdata;wire m_axi_rlast;
video_dma_2d_axi32 #(.MAX_BURST(4)) dma(.*);
reg codec_start=0,codec_ack=0;reg[1:0]order;
wire psr,psr_unused,usr,pr,pv,ps,pe,pl,pd,pde,ud,ude;
wire[7:0]pbyte,pec,uec;wire[31:0]macro;wire uv,us,ue,ul;
reg ur=0;reg read_first=1;
assign m_ready=ce&&pr;
yuv422_byte_packer #(.WIDTH(W),.HEIGHT(H)) packer(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(codec_start),.start_ready(psr),.cfg_order(order),.abort(abort),
.s_data(m_data),.s_valid(m_valid),.s_ready(pr),.s_sof(read_first),.s_eol(m_eol),.s_last(m_last),
.m_data(pbyte),.m_valid(pv),.m_ready(usr),.m_sof(ps),.m_eol(pe),.m_last(pl),
.done_valid(pd),.done_ready(codec_ack),.done_error(pde),.error_code(pec));
yuv422_byte_unpacker #(.WIDTH(W),.HEIGHT(H)) unpacker(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(codec_start),.start_ready(psr_unused),.cfg_order(order),.abort(abort),
.s_data(pbyte),.s_valid(pv),.s_ready(usr),.s_sof(ps),.s_eol(pe),.s_last(pl),
.m_data(macro),.m_valid(uv),.m_ready(ur),.m_sof(us),.m_eol(ue),.m_last(ul),
.done_valid(ud),.done_ready(codec_ack),.done_error(ude),.error_code(uec));
reg[7:0]mem[0:65535];reg[31:0]expected[0:F*N-1];
reg wa=0,ra=0;integer wi=0,ri=0,wl=0,rl=0,cycle=0,got=0,f,i,j;
integer k;integer aw_count=0,ar_count=0,byte_count=0;reg take;reg[1:0]mode_snapshot;
assign m_axi_awready=!wa&&!m_axi_bvalid&&cycle%5!=0;
assign m_axi_wready=wa&&cycle%7>1;
assign m_axi_arready=!ra&&!m_axi_rvalid&&cycle%6>1;
assign m_axi_rdata={mem[ri+3],mem[ri+2],mem[ri+1],mem[ri]};
assign m_axi_rlast=rl==1;
always @(posedge clk)begin
cycle<=cycle+1;if(cycle>200000)$fatal(1,"timeout f%0d k%0d err%h write%b state%0d s%0b/%0b aw%0b/%0b w%0b/%0b left%0d wb%0b ra%0b r%0b/%0b m%0b/%0b pd%0b ud%0b got%0d bytes%0d",f,k,error_code,cfg_write,dma.state,s_valid,s_ready,m_axi_awvalid,m_axi_awready,m_axi_wvalid,m_axi_wready,dma.left,dma.wb_valid,ra,m_axi_rvalid,m_axi_rready,m_valid,m_ready,pd,ud,got,byte_count);
if(rst_n)begin
if(done_valid&&error_code)$fatal(1,"DMA early failure f%0d k%0d error%h wr%0b left%0d eol%0b last%0b",f,k,error_code,cfg_write,dma.left,s_eol,s_last);
if(m_axi_awvalid&&m_axi_awready)begin
if(wa||m_axi_awsize!=2||m_axi_awburst!=1||m_axi_awlen>=4||m_axi_awaddr[1:0]||({1'b0,m_axi_awaddr[11:0]}+(m_axi_awlen+1)*4)>4096)$fatal(1,"AW burst");
wa<=1;wi<=m_axi_awaddr;wl<=m_axi_awlen+1;aw_count=aw_count+1;
end
if(m_axi_wvalid&&m_axi_wready)begin
if(!wa||m_axi_wlast!==(wl==1)||m_axi_wstrb!=15)$fatal(1,"write data");
for(j=0;j<4;j=j+1)if(m_axi_wstrb[j])mem[wi+j]<=m_axi_wdata[j*8+:8];
wi<=wi+4;wl<=wl-1;if(wl==1)begin wa<=0;m_axi_bvalid<=1;end
end
if(m_axi_bvalid&&m_axi_bready)m_axi_bvalid<=0;
if(m_axi_arvalid&&m_axi_arready)begin
if(ra||m_axi_arsize!=2||m_axi_arburst!=1||m_axi_arlen>=4||m_axi_araddr[1:0]||({1'b0,m_axi_araddr[11:0]}+(m_axi_arlen+1)*4)>4096)$fatal(1,"AR burst");
ra<=1;ri<=m_axi_araddr;rl<=m_axi_arlen+1;ar_count=ar_count+1;
end
if(ra&&!m_axi_rvalid&&cycle%5>0)m_axi_rvalid<=1;
if(m_axi_rvalid&&m_axi_rready)begin
m_axi_rvalid<=0;ri<=ri+4;rl<=rl-1;if(rl==1)ra<=0;
end
if(m_valid&&m_ready)begin if(m_keep!=15)$fatal(1,"DMA keep");read_first<=0;end
if(ce&&pv&&usr)begin
case(mode_snapshot)
0:case(byte_count%4)0:i=31;1:i=15;2:i=23;3:i=7;endcase
1:case(byte_count%4)0:i=15;1:i=31;2:i=7;3:i=23;endcase
2:case(byte_count%4)0:i=31;1:i=7;2:i=23;3:i=15;endcase
3:case(byte_count%4)0:i=7;1:i=31;2:i=15;3:i=23;endcase
endcase
if(pbyte!==((expected[f*N+byte_count/4]>>(i-7))&255)||ps!==(byte_count==0)||pe!==(byte_count%ROW==ROW-1)||pl!==(byte_count==ROW*H-1))$fatal(1,"packed byte %d",byte_count);
byte_count=byte_count+1;
end
if(ce&&uv&&ur)begin
if(got>=N||macro!==expected[f*N+got]||us!==(got==0)||ue!==(got%(W/2)==W/2-1)||ul!==(got==N-1))$fatal(1,"macro %d",got);
got=got+1;
end
if((pd&&pde)||(ud&&ude))$fatal(1,"YUV error %h %h",pec,uec);
end end
task tick;begin @(negedge clk);#1;ce=cycle%11>1;ur=cycle%7>1;end endtask
task launch_dma;input writing;begin
ce=1;cfg_write=writing;cfg_base=f*8192+4092;cfg_row_bytes=ROW;cfg_stride=STRIDE;cfg_rows=H;
while(!start_ready)tick;start_valid=1;@(posedge clk);tick;start_valid=0;
cfg_base=32'hfffffffe;cfg_row_bytes=0;cfg_stride=0;cfg_rows=0;
end endtask
task ack_dma;begin
done_ready=1;@(posedge clk);tick;done_ready=0;
end endtask
initial begin
$readmemh("macros.mem",expected);for(k=0;k<65536;k=k+1)mem[k]=8'ha5;
repeat(3)@(negedge clk);#1;rst_n=1;
for(f=0;f<F;f=f+1)begin
launch_dma(1);
for(k=0;k<N;k=k+1)begin
s_data=expected[f*N+k];s_valid=1;s_eol=k%(W/2)==W/2-1;s_last=k==N-1;
take=0;while(!take)begin @(posedge clk);take=ce&&s_ready;tick;end s_valid=0;
end
while(!done_valid)tick;if(error_code||bytes_done!=ROW*H)$fatal(1,"write done %h %d",error_code,bytes_done);ack_dma;
got=0;byte_count=0;read_first=1;order=f;mode_snapshot=f;ce=1;
if(!psr||!psr_unused)$fatal(1,"codec start");codec_start=1;@(posedge clk);tick;codec_start=0;order=~f;
launch_dma(0);while(!done_valid||!pd||!ud)tick;
if(error_code||bytes_done!=ROW*H||got!=N||byte_count!=ROW*H)$fatal(1,"read result");
codec_ack=1;while(!ce)tick;@(posedge clk);tick;codec_ack=0;ack_dma;
end
if(aw_count!=EXPECTED_BURSTS||ar_count!=EXPECTED_BURSTS)$fatal(1,"burst count expected%d actual%d/%d",EXPECTED_BURSTS,aw_count,ar_count);
$writememh("ram.hex",mem);$display("PASS VIDEO_DMA_YUV frames=%0d macros=%0d AW=%0d AR=%0d",F,F*N,aw_count,ar_count);$finish;
end endmodule'''


def run(width, height):
    folder = evidence_dir('video_dma_yuv')
    sources = [PACKAGE/'memory/video_dma_2d/video_dma_2d_axi32.v',
               PACKAGE/'image/yuv422_bytes/yuv422_byte_packer.sv',
               PACKAGE/'image/yuv422_bytes/yuv422_byte_unpacker.sv']
    hashes = {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    rng = random.Random(width*101+height)
    macros = [rng.getrandbits(32) for _ in range(4*width*height//2)]
    expected = bytearray([0xa5]*65536)
    for f in range(4):
        for y in range(height):
            for x in range(width//2):
                address = f*8192+4092+y*(width*2+12)+x*4
                value = macros[f*width*height//2+y*width//2+x]
                expected[address:address+4] = value.to_bytes(4, 'little')
    bursts = 0
    for frame in range(4):
        for row in range(height):
            address = frame*8192+4092+row*(width*2+12)
            remaining = width*2
            while remaining:
                count = min((remaining+3)//4, 4, (4096-address%4096)//4)
                address += count*4
                remaining = max(0, remaining-count*4)
                bursts += 1
    with tempfile.TemporaryDirectory(prefix='video_dma_yuv_') as tmp:
        path = Path(tmp)
        (path/'macros.mem').write_text('\n'.join(f'{v:08x}' for v in macros))
        (path/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@H@', str(height)).replace('@BURSTS@', str(bursts)))
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', path/'sim', *sources, path/'tb.sv'], ROOT, folder/'compile.log')
        execute(['vvp', path/'sim'], path, folder/'simulation.log')
        actual = bytes(int(line.strip(), 16) for line in (path/'ram.hex').read_text().splitlines()
                       if line.strip() and not line.startswith('//'))
        assert actual == expected, 'AXI RAM oracle/row stride holes'
    assert hashes == {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    write_json(folder/'results.json', dict(status='PASS', width=width, height=height,
        frames=4, macros=len(macros), modes=['YUYV','UYVY','YVYU','VYUY'],
        memory_oracle_bytes=len(expected), write_bursts=bursts, read_bursts=bursts, sources=hashes, board_tested=False))
    print(folder, flush=True)


if __name__ == '__main__':
    for geometry in ((6, 3), (8, 4), (14, 3)):
        run(*geometry)
