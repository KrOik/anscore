"""Resource gate for the actual encoder -> decoder RTL composition."""
import hashlib
import re
import tempfile
from pathlib import Path
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

TOP=r'''module bmp_codec_chain(
input clk,rst_n,ce,start_valid,output start_ready,input cfg_top_down,input abort,
input[23:0]s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
output[23:0]m_rgb,output m_valid,input m_ready,output m_sof,m_eol,m_last,
output done_valid,input done_ready,output done_error,output[15:0]error_codes,
output[15:0]image_width,image_height,
output[31:0]output_bytes);
wire er,dr,go,ev,es,el,byte_ready,ed,ee,dd,de;wire[7:0]byte_,ec,dc;
wire abort_all=abort||(ed&&ee)||(dd&&de);
assign start_ready=er&&dr;assign go=start_valid&&start_ready;
assign done_valid=ed&&dd;assign done_error=ee||de;assign error_codes={ec,dc};
bmp_encoder #(.WIDTH(16),.HEIGHT(12)) enc(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(go),.start_ready(er),.cfg_top_down(cfg_top_down),.abort(abort_all),
.s_pixel(s_pixel),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
.m_data(byte_),.m_valid(ev),.m_ready(byte_ready),.m_sof(es),.m_last(el),
.done_valid(ed),.done_ready(done_ready&&dd),.done_error(ee),.error_code(ec),.output_bytes(output_bytes));
bmp_decoder #(.MAX_WIDTH(16),.MAX_HEIGHT(12)) dec(
.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(go),.start_ready(dr),.abort(abort_all),
.s_data(byte_),.s_valid(ev),.s_ready(byte_ready),.s_last(el),
.m_rgb(m_rgb),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),
.done_valid(dd),.done_ready(done_ready&&ed),.frame_error(de),.error_code(dc),
.image_width(image_width),.image_height(image_height));
endmodule'''

TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,done_ready=0,m_ready=0;
reg cfg_top_down;reg[23:0]s_pixel;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error;
wire[23:0]m_rgb;wire[15:0]error_codes,image_width,image_height;wire[7:0]image_color_type;wire[31:0]output_bytes;
bmp_codec_chain dut(.*);
integer cycle=0,got=0,total=0;reg[23:0]expected;reg take,held=0;reg[26:0]token;
always @(posedge clk)begin
cycle=cycle+1;if(cycle>1000000)$fatal(1,"timeout");
if(rst_n)begin
if(held&&(!m_valid||{m_rgb,m_sof,m_eol,m_last}!==token))$fatal(1,"output hold");held=m_valid&&!(ce&&m_ready);token={m_rgb,m_sof,m_eol,m_last};
if(ce&&m_valid&&m_ready)begin
if(m_rgb!==expected||m_sof!==(got==0)||m_eol!==(got%16==15)||m_last!==(got==191))$fatal(1,"pixel %d",got);got=got+1;total=total+1;end
end end
task tick;begin @(negedge clk);#1;ce=cycle%11>1;m_ready=cycle%7>1;end endtask
task frame;input[1:0]mode;input bad_marker,do_abort;integer i;reg broken;
begin
ce=1;cfg_top_down=mode;s_pixel=mode==1?24'habcdef:24'h1a2b5a;expected=mode==1?24'habcdef:24'h1a2b5a;got=0;broken=0;
while(!start_ready)tick;start_valid=1;@(posedge clk);tick;start_valid=0;cfg_top_down=~mode;
i=0;while(i<192&&!done_valid&&!broken)begin
s_valid=1;s_sof=(i==0)||(bad_marker&&i==4);s_eol=i%16==15;s_last=i==191;
@(posedge clk);take=ce&&s_ready;if(take)i=i+1;tick;
if(do_abort&&i==4)begin s_valid=0;abort=1;while(!ce)tick;@(posedge clk);tick;abort=0;broken=1;end
end s_valid=0;
while(!done_valid)tick;
if(done_error!==(bad_marker||do_abort))$fatal(1,"error propagation mode%d bad%d abort%d codes%h",mode,bad_marker,do_abort,error_codes);
if(!done_error&&(got!=192||image_width!=16||image_height!=12))$fatal(1,"completion");
ce=0;done_ready=1;repeat(3)@(negedge clk);#1;if(!done_valid)$fatal(1,"DONE hold");ce=1;@(negedge clk);#1;done_ready=0;
end endtask
initial begin
repeat(3)@(negedge clk);#1;rst_n=1;
frame(0,0,0);frame(1,1,0);frame(1,0,0);frame(0,1,0);frame(0,0,0);frame(1,0,1);frame(1,0,0);
$display("PASS BMP_CODEC_WRAPPER healthy_frames=4 pixels=%d errors=3",total);$finish;
end endmodule'''

def main():
    folder=evidence_dir('bmp_codec_synthesis')
    sources=[PACKAGE/'image/bmp_encoder/bmp_encoder.sv',PACKAGE/'image/bmp_decoder/bmp_decoder.sv']
    hashes={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    with tempfile.TemporaryDirectory(prefix='bmp_codec_synth_') as tmp:
        path=Path(tmp);top=path/'top.sv';top.write_text(TOP)
        (path/'tb.sv').write_text(TB)
        execute(['iverilog','-g2012','-s','tb','-o',path/'sim',*sources,top,path/'tb.sv'],ROOT,folder/'compile.log')
        execute(['vvp',path/'sim'],ROOT,folder/'wrapper_simulation.log',timeout=180)
        script=path/'run.ys'
        script.write_text('read_verilog -sv '+ ' '.join(s.as_posix() for s in sources+[top])+'\nsynth_gowin -top bmp_codec_chain -nodsp\ncheck -assert\nstat\n')
        text=execute(['yosys','-Q','-T','-s',script],ROOT,folder/'synthesis.log',timeout=600)
    stat=text[text.rfind('=== bmp_codec_chain ==='):]
    cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
    assert cells and not any(k.startswith('$') for k in cells)
    lut=sum(v for k,v in cells.items() if k.startswith(('LUT','MUX')) or k=='ALU')+4*cells.get('RAM16SDP4',0)
    dsp=sum(v for k,v in cells.items() if k.startswith(('MULT','DSP','PADD','ALU54')))
    bram=2*sum(v for k,v in cells.items() if k=='SP' or k.startswith(('DPB','DPX','SPX','SDPB','SDPX','SPB')))
    assert 0<lut<=15000 and dsp<=4 and bram<=46,(lut,dsp,bram)
    assert hashes=={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources}
    write_json(folder/'results.json',dict(status='PASS',scope='combined encoder to decoder isolated synthesis; no routed timing or board acceptance',
        width=16,height=12,lut_class=lut,dsp=dsp,conservative_bram9_units=bram,cells=cells,
        sources=hashes,wrapper_sha256=hashlib.sha256(TOP.encode()).hexdigest()))
    print(folder,flush=True)

if __name__=='__main__':main()
