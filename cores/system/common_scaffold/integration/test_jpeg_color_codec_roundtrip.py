"""Actual RGB encoder byte stream wired into the color JPEG decoder.

Keep the frozen encoder's runtime-table/rejected-config stimulus. Restart is
disabled because the decoder explicitly does not support DRI/RST streams.
"""
import hashlib
import io
import random
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image
from test_jpeg_color_frame import TB as ENCODER_TB, SOURCES as ENCODER_SOURCES
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = ENCODER_SOURCES + [PACKAGE/'image/jpeg_color_decoder/jpeg_color_decoder.sv']


def bench(w,h):
    tb = ENCODER_TB
    tb = tb.replace('reg start_valid=0', 'wire decoder_ready;reg request_ready=0;wire m_ready=request_ready&&decoder_ready;reg start_valid=0')
    tb = tb.replace(',m_ready=0,done_ready=0', ',done_ready=0')
    tb = tb.replace('m_ready=rng[5:3]!=0;', 'request_ready=rng[5:3]!=0;dec_ready=rng[9:7]!=0;')
    tb = tb.replace('configure(frame==1,frame==1?1:(frame==3?2:0),frame==2);',
                    'configure(frame==1,0,frame==2);')
    tb = tb.replace('while(!start_ready)tick;start_valid=1;',
                    'while(!dec_start_ready)tick;dec_start=1;tick;dec_start=0;\n  while(!start_ready)tick;start_valid=1;')
    tb = tb.replace('while(!done_valid)tick;', 'while(!done_valid||!dec_done)tick;')
    tb = tb.replace('repeat(3)tick;while(!ce)tick;done_ready=1;',
                    '''if(dec_error||dec_code||dec_count!=(frame+1)*N||dec_width!=W||dec_height!=H)
   $fatal(1,"decoder completion frame=%0d pixels=%0d error=%h",frame,dec_count,dec_code);
  repeat(3)tick;while(!ce)tick;done_ready=1;''')
    insertion = r'''
reg dec_start=0,dec_ready=0;wire dec_start_ready,dec_done,dec_error,dec_valid;
wire[23:0]dec_pixel;wire[7:0]dec_code;wire dec_sof,dec_eol,dec_last;
wire[15:0]dec_width,dec_height;
integer pixelout,dec_count=0;reg stalled=0;reg[26:0]held_pixel;
jpeg_color_decoder #(.COEFF_FILE("@COEFF@")) decoder(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(dec_start),.start_ready(dec_start_ready),.abort(1'b0),
 .s_data(m_data),.s_valid(m_valid&&request_ready),.s_last(m_last),.s_ready(decoder_ready),
 .m_data(dec_pixel),.m_valid(dec_valid),.m_sof(dec_sof),.m_eol(dec_eol),.m_last(dec_last),.m_ready(dec_ready),
 .width(dec_width),.height(dec_height),.done_valid(dec_done),.done_ready(done_ready),
 .done_error(dec_error),.error_code(dec_code),.busy());
initial pixelout=$fopen("decoded.hex","w");
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!dec_valid||{dec_pixel,dec_sof,dec_eol,dec_last}!==held_pixel))$fatal(1,"decoder stalled payload");
 stalled=dec_valid&&!(ce&&dec_ready);held_pixel={dec_pixel,dec_sof,dec_eol,dec_last};
 if(ce&&dec_valid&&dec_ready)begin
  if(dec_sof!==(dec_count%N==0)||dec_eol!==(dec_count%W==W-1)||dec_last!==(dec_count%N==N-1))
   $fatal(1,"decoder raster markers");
  $fdisplay(pixelout,"%06x",dec_pixel);dec_count=dec_count+1;
 end
end
'''
    tb = tb.replace('always @(negedge clk)if(rst_n)begin',insertion+'\nalways @(negedge clk)if(rst_n)begin',1)
    tb = tb.replace('$display("JPEG_COLOR_FRAME PASS', '$fclose(pixelout);$display("JPEG_COLOR_FRAME PASS')
    return tb.replace('@W@',str(w)).replace('@H@',str(h)).replace(
        '@COEFF@',(PACKAGE/'image/jpeg_color_decoder/idct_coeff.hex').as_posix())


def main():
    folder = evidence_dir('jpeg_color_codec_roundtrip')
    rng = random.Random(0x434f4445)
    rows = []
    with tempfile.TemporaryDirectory(prefix='jpeg_color_codec_') as tmp:
        td = Path(tmp)
        for w,h in ((1,1),(9,7),(17,9)):
            images = []
            for f in range(4):
                if f == 3:
                    image = [tuple(rng.randrange(256) for _ in range(3)) for _ in range(w*h)]
                else:
                    image = [((x*7+f*19)%256,(y*13+f*29)%256,(x*3+y*5+f*37)%256)
                             for y in range(h) for x in range(w)]
                images.append(image)
            (td/'pixels.hex').write_text(''.join(f'{r:02x}{g:02x}{b:02x}\n' for im in images for r,g,b in im),encoding='ascii')
            (td/'tb.sv').write_text(bench(w,h),encoding='utf-8')
            label = f'{w}x{h}'
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,folder/f'{label}_compile.log')
            output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=300)
            assert 'JPEG_COLOR_FRAME PASS' in output,output
            words = [int(v,16) for v in (td/'decoded.hex').read_text().split()]
            assert len(words) == 4*w*h
            for frame in range(4):
                data = bytes(int(v,16) for v in (td/f'file_{frame}.hex').read_text().split())
                ref = np.asarray(Image.open(io.BytesIO(data))).astype(int)
                values = words[frame*w*h:(frame+1)*w*h]
                actual = np.asarray([[(v >> 16)&255,(v >> 8)&255,v&255] for v in values]).reshape(h,w,3)
                error = np.abs(actual-ref)
                # IDCT rounding, interpolation and RGB rounding can differ by a
                # few levels; a large chroma-phase mismatch must never pass.
                assert int(error.max()) <= 5,(label,frame,int(error.max()))
                rows.append(dict(width=w,height=h,frame=frame,sampling='420' if frame in (1,2) else '444',
                                 bytes=len(data),pixels=w*h,max_pillow_error=int(error.max()),
                                 mean_pillow_error=float(error.mean()),status='PASS'))
    write_json(folder/'results.json',dict(status='PASS',cases=rows,board_tested=False,
        rtl_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}))
    print(folder,flush=True)


if __name__ == '__main__':
    main()
