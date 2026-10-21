"""Actual RGB -> HSV_FULL -> RGB cascade with independent integer oracle."""
import hashlib
import importlib.util
import random
import tempfile
from pathlib import Path

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCE = PACKAGE/'image/hsv_color/rgb_hsv_full_stream.v'
HELPER = PACKAGE/'image/hsv_color/test_hsv_color.py'


def main():
    spec = importlib.util.spec_from_file_location('hsv_reference', HELPER)
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    frozen = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in (SOURCE, HELPER)}
    folder = evidence_dir('hsv_roundtrip')
    rng = random.Random(29831)
    pixels = [tuple(rng.randrange(256) for _ in range(3)) for _ in range(2048)]
    pixels[:256] = [(k,k,k) for k in range(256)]
    pixels[256:264] = [(r,g,b) for r in (0,255) for g in (0,255) for b in (0,255)]
    expected = [reference.oracle(reference.oracle(v, False), True) for v in pixels]
    maximum = max(abs(a-b) for p,q in zip(pixels,expected) for a,b in zip(p,q))
    assert maximum <= 12, maximum
    tb = r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst=1,ce=1,start_valid=0,done_ready=0;
reg[23:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,m_ready=0;
wire ar,br,ir,iv,iso,iel,av,bv,ad,bd,ae,be,ab,bb;
wire[3:0]ac,bc;wire[23:0]id,md;wire mso,mel;
rgb_hsv_full_stream #(.WIDTH(32),.HEIGHT(16)) forward(
 .clk(clk),.rst(rst),.ce(ce),.start_valid(start_valid),.start_ready(ar),.cfg_inverse(1'b0),
 .s_data(s_data),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(ir),
 .m_data(id),.m_valid(iv),.m_sof(iso),.m_eol(iel),.m_ready(br),
 .done(ad),.error(ae),.busy(ab),.done_valid(av),.done_ready(done_ready),.error_code(ac));
rgb_hsv_full_stream #(.WIDTH(32),.HEIGHT(16)) inverse(
 .clk(clk),.rst(rst),.ce(ce),.start_valid(start_valid),.start_ready(),.cfg_inverse(1'b1),
 .s_data(id),.s_valid(iv),.s_sof(iso),.s_eol(iel),.s_ready(br),
 .m_data(md),.m_valid(bv),.m_sof(mso),.m_eol(mel),.m_ready(m_ready),
 .done(bd),.error(be),.busy(bb),.done_valid(),.done_ready(done_ready),.error_code(bc));
reg[23:0]pixels[0:2047],expected[0:2047];
integer count=0,cycles=0,f,i;reg[23:0]held;reg stalled=0;reg hs,he;
always @(negedge clk)begin
 cycles=cycles+1;ce=(cycles%13!=0&&cycles%13!=1);m_ready=(cycles%7!=0&&cycles%7!=1);
end
always @(posedge clk)if(!rst)begin
 if(stalled&&(!bv||md!==held||mso!==hs||mel!==he))$fatal(1,"unstable cascade output");
 stalled=bv&&!(ce&&m_ready);held=md;hs=mso;he=mel;
 if(ce&&bv&&m_ready)begin
  if(count>=2048||md!==expected[count]||mso!==(count%512==0)||mel!==(count%32==31))
   $fatal(1,"cascade pixel %0d got=%h expected=%h",count,md,expected[count]);
  count=count+1;
 end
end
task tick;begin @(negedge clk);#1;end endtask
initial begin
 $readmemh("pixels.hex",pixels);$readmemh("expected.hex",expected);
 repeat(3)tick;rst=0;
 for(f=0;f<4;f=f+1)begin
  while(!ar)tick;start_valid=1;tick;start_valid=0;
  for(i=0;i<512;i=i+1)begin
   s_data=pixels[f*512+i];s_sof=i==0;s_eol=i%32==31;
   while(!ir)tick;s_valid=1;tick;s_valid=0;
  end
  while(!(ad&&bd))tick;
  if(ae||be||ac||bc||count!=(f+1)*512)$fatal(1,"cascade done");
  repeat(4)begin tick;if(!ad||!bd||!ab||!bb)$fatal(1,"done not held");end
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 if(count!=2048)$fatal(1,"coverage");
 $display("HSV_ROUNDTRIP PASS 4 frames 2048 pixels");$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule'''
    with tempfile.TemporaryDirectory(prefix='hsv_roundtrip_') as temporary:
        td = Path(temporary)
        for name, values in (('pixels',pixels),('expected',expected)):
            (td/f'{name}.hex').write_text(''.join(''.join(f'{c:02x}' for c in v)+'\n'
                                                for v in values),encoding='utf-8')
        (td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',SOURCE,td/'tb.sv'],ROOT,folder/'compile.log')
        output = execute(['vvp',td/'sim'],td,folder/'simulation.log',timeout=120)
        assert 'HSV_ROUNDTRIP PASS' in output
    assert frozen == {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in (SOURCE,HELPER)}
    write_json(folder/'results.json',dict(status='PASS',frames=4,pixels=2048,
        exact_integer_composition=True,max_rgb_roundtrip_error=maximum,sources=frozen,
        scope='Two actual HSV cores, four adjacent frames, CE/backpressure, markers and held completion. FULL forward hue /256 and inverse /255 follow the documented conventions.',board_tested=False))
    print(folder)


if __name__ == '__main__':
    main()
