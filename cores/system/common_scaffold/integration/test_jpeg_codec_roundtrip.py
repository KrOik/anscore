"""Wire real grayscale raster encoder/header outputs directly into the decoder.

The frozen encoder transport bench is reused; decoded pixels are independently
compared with Pillow decoding the exact same emitted JPEG bytes.
"""
import hashlib
import io
import random
import tempfile
from pathlib import Path

from PIL import Image
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json
from test_jpeg_frame import TB as ENCODER_TB, SOURCES as ENCODER_SOURCES

SOURCES = ENCODER_SOURCES + [PACKAGE/'image/jpeg_gray_decoder/jpeg_gray_decoder.sv']


def bench(w,h):
    tb = ENCODER_TB
    tb = tb.replace('reg accepted=0', 'wire decoder_ready;reg accepted=0')
    tb = tb.replace('wire htr,hcr,hdone,herr,cmdr,cmdd,cmde,hv;',
                    'wire htr,hcr,hdone,herr,cmdr,cmdd,cmde,hv,hlast;')
    tb = tb.replace('.m_data(hd),.m_valid(hv),.m_last()',
                    '.m_data(hd),.m_valid(hv),.m_last(hlast)')
    tb = tb.replace('.m_ready(ready&&phase', '.m_ready(ready&&decoder_ready&&phase')
    tb = tb.replace('if(ce&&ready)begin','if(ce&&ready&&decoder_ready)begin')
    tb = tb.replace('ready=1;command(0);', '''dec_start=1;
@(posedge clk);while(!dec_start_ready)@(posedge clk);
@(negedge clk);#1;dec_start=0;ready=1;command(0);''')
    tb = tb.replace('command(1);run=0;', '''command(1);run=0;ce=1;
while(!dec_done)begin
 @(negedge clk);#1;decode_cycles=decode_cycles+1;
 ce=decode_cycles%11>1;dec_ready=decode_cycles%7>1;
end
if(dec_error||dec_code||dec_count!=WIDTH*HEIGHT||dec_width!=WIDTH||dec_height!=HEIGHT)
 $fatal(1,"decoder completion err=%h pixels=%d",dec_code,dec_count);
$fclose(pixelout);''')
    insertion = r'''
reg dec_start=0,dec_ready=0;wire dec_start_ready,dec_done,dec_error,dec_valid;
wire[7:0]dec_pixel,dec_code;wire dec_sof,dec_eol,dec_last;
wire[15:0]dec_width,dec_height;
integer pixelout,dec_count=0,decode_cycles=0;reg stalled=0;reg[10:0]held;
jpeg_gray_decoder decoder(.clk(clk),.rst_n(rst),.ce(ce),.start_valid(dec_start),
 .start_ready(dec_start_ready),.abort(1'b0),
 .s_data(phase==1?scan_data:hd),.s_valid(ready&&(phase==1?scan_valid:hv)),
 .s_last(phase==2&&hlast),.s_ready(decoder_ready),
 .m_data(dec_pixel),.m_valid(dec_valid),.m_sof(dec_sof),.m_eol(dec_eol),.m_last(dec_last),
 .m_ready(dec_ready),.width(dec_width),.height(dec_height),
 .done_valid(dec_done),.done_ready(1'b0),.done_error(dec_error),.error_code(dec_code),.busy());
initial pixelout=$fopen("decoded.txt","w");
always @(posedge clk)if(rst)begin
 if(stalled&&(!dec_valid||{dec_pixel,dec_sof,dec_eol,dec_last}!==held))$fatal(1,"decode stall");
 stalled=dec_valid&&!(ce&&dec_ready);held={dec_pixel,dec_sof,dec_eol,dec_last};
 if(ce&&dec_valid&&dec_ready)begin
  if(dec_sof!==(dec_count==0)||dec_eol!==(dec_count%WIDTH==WIDTH-1)||dec_last!==(dec_count==WIDTH*HEIGHT-1))
   $fatal(1,"decode raster markers");
  $fdisplay(pixelout,"%d",dec_pixel);dec_count=dec_count+1;
 end
end
'''
    tb = tb.replace('always @(posedge clk)if(rst)begin',insertion+'\nalways @(posedge clk)if(rst)begin',1)
    return tb.replace('WW',str(w)).replace('HH',str(h)).replace('RI','0')


def main():
    folder = evidence_dir('jpeg_codec_roundtrip')
    rng = random.Random(0x4a504547)
    rows = []
    with tempfile.TemporaryDirectory(prefix='jpeg_codec_') as tmp:
        td = Path(tmp)
        for w,h in ((1,1),(8,8),(13,9),(16,16)):
            pixels = [rng.randrange(256) for _ in range(w*h)]
            (td/'pixels.hex').write_text(''.join(f'{v:02x}\n' for v in pixels),encoding='ascii')
            (td/'tb.sv').write_text(bench(w,h),encoding='utf-8')
            name = f'{w}x{h}'
            # Decoder ROM has a repository-relative path, so vvp runs from root;
            # other fixture files use a scoped absolute path in the bench.
            text = (td/'tb.sv').read_text(encoding='utf-8')
            for filename in ('pixels.hex','file.hex','decoded.txt'):
                text = text.replace('"'+filename+'"','"'+(td/filename).as_posix()+'"')
            (td/'tb.sv').write_text(text,encoding='utf-8')
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,folder/f'{name}_compile.log')
            log = execute(['vvp',td/'sim'],ROOT,folder/f'{name}_simulation.log',timeout=180)
            assert 'JPEG_FRAME PASS' in log,log
            data = bytes(int(v,16) for v in (td/'file.hex').read_text().split())
            actual = [int(v) for v in (td/'decoded.txt').read_text().split()]
            decoded = Image.open(io.BytesIO(data))
            assert decoded.size == (w,h)
            reference = list(decoded.tobytes())
            assert len(actual) == len(reference) == w*h
            delta = max(abs(a-b) for a,b in zip(actual,reference))
            source_delta = max(abs(a-b) for a,b in zip(actual,pixels))
            assert delta <= 2,(name,delta)
            assert source_delta <= 18,(name,source_delta)
            rows.append(dict(width=w,height=h,bytes=len(data),pixels=len(actual),
                             max_pillow_delta=delta,max_original_delta=source_delta,status='PASS'))
    write_json(folder/'results.json',dict(status='PASS',cases=rows,board_tested=False,
        rtl_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}))
    print(folder,flush=True)


if __name__ == '__main__':
    main()
