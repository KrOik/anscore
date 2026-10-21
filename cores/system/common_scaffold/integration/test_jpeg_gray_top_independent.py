"""Independent complete grayscale JFIF wrapper acceptance using Pillow.

No owner testbench, entropy oracle, header generator or saved JPEG is imported.
Two frames run without reset with stalled output and CE; pixel errors are
bounded before execution for the all-one quantization table.
"""
import io
import random
import tempfile
from pathlib import Path
from PIL import Image
from tooling import PACKAGE, evidence_dir, execute, write_json
from preflight_sensor_extensions import digest

RELATIVE = (
    'dsp/dct8x8/dct8x8_serial.sv',
    'dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv',
    'dsp/jpeg_entropy/jpeg_baseline_symbols.v',
    'dsp/jpeg_huffman/jpeg_default_huffman.sv',
    'dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv',
    'dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v',
    'dsp/jpeg_grayscale/jpeg_grayscale_scan.sv',
    'dsp/jpeg_headers/jpeg_gray_headers.sv',
    'image/raster_blocks/img_raster_blocks.v',
    'image/jpeg_gray_encoder/jpeg_gray_encoder.sv',
)

TB = r'''
`timescale 1ns/1ps
module tb;
localparam W=@W@,H=@H@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,table_valid=0,cfg_valid=0,start_valid=0,abort=0;
reg[5:0]table_index=0;reg[7:0]table_value=1;
reg[15:0]cfg_restart_interval=1;
wire table_ready,cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_last,done_valid,busy;
reg[7:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
wire[7:0]m_data,error_code;reg[7:0]pixels[0:2*N-1];
jpeg_gray_encoder #(.WIDTH(W),.HEIGHT(H))dut(.*);
integer cycles=0,frame=0,fd,bytes=0,lasts=0;
reg held=0;reg[8:0]previous;
always @(negedge clk)begin
 cycles=cycles+1;ce=(cycles%11!=3)&&(cycles%11!=4);
 m_ready=(cycles%7<4);
end
always @(posedge clk)if(rst_n)begin
 if(held&&(!m_valid||{m_last,m_data}!==previous))$fatal(1,"stalled output changed");
 held=m_valid&&!(ce&&m_ready);previous={m_last,m_data};
 if(ce&&m_valid&&m_ready)begin
  $fdisplay(fd,"%02x",m_data);bytes=bytes+1;
  if(m_last)lasts=lasts+1;
 end
 if(ce&&s_ready&&s_valid&&frame>1)$fatal(1,"extra frame accepted");
end
task cycle;begin @(negedge clk);#1;end endtask
task accept_table;begin
 table_valid=1;while(!(ce&&table_ready))cycle;
 @(posedge clk);#1;cycle;table_valid=0;
end endtask
integer i;
initial begin
 $readmemh("pixels.hex",pixels);fd=$fopen("frame0.hex","w");
 repeat(5)cycle;rst_n=1;cycle;
 for(i=0;i<64;i=i+1)begin table_index=i;accept_table;end
 cfg_valid=1;while(!(ce&&cfg_ready))cycle;
 @(posedge clk);#1;cycle;cfg_valid=0;
 while(!(ce&&cfg_done))cycle;if(cfg_error)$fatal(1,"configure");
 for(frame=0;frame<2;frame=frame+1)begin
  start_valid=1;while(!(ce&&start_ready))cycle;
  @(posedge clk);#1;cycle;start_valid=0;
  for(i=0;i<N;i=i+1)begin
   s_data=pixels[frame*N+i];s_sof=i==0;s_eol=i%W==W-1;s_valid=1;
   while(!(ce&&s_ready))cycle;
   @(posedge clk);#1;cycle;s_valid=0;
  end
  // Offer an unwanted next frame during encoding tail; it must remain blocked.
  s_valid=1;s_sof=1;s_eol=W==1;s_data=8'hde;
  while(!done_valid)begin if(s_ready)$fatal(1,"extra raster pixel");cycle;end
  if(error_code||lasts!=1)$fatal(1,"frame completion %h last%0d",error_code,lasts);
  s_valid=0;repeat(13)begin cycle;if(!done_valid||error_code)$fatal(1,"done not held");end
  $fclose(fd);done_ready=1;while(!ce)cycle;@(posedge clk);#1;cycle;done_ready=0;
  if(frame==0)begin fd=$fopen("frame1.hex","w");lasts=0;end
 end
 $display("PASS JPEG GRAY TOP INDEPENDENT W=%0d H=%0d frames2 bytes%0d",W,H,bytes);$finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
'''


def main():
    folder = evidence_dir('jpeg_gray_top_independent')
    paths = [PACKAGE / name for name in RELATIVE]
    sources = {name: digest(path) for name, path in zip(RELATIVE, paths)}
    profiles = []
    for width, height in ((1, 1), (13, 9), (16, 16)):
        rng = random.Random(width * 123 + height)
        frames = [[(x*13+y*7+23) % 256 for y in range(height) for x in range(width)],
                  [rng.randrange(256) for _ in range(width*height)]]
        label = f'{width}x{height}'
        with tempfile.TemporaryDirectory(prefix='jpeg_gray_top_independent_') as tmp:
            work = Path(tmp)
            (work/'pixels.hex').write_text('\n'.join(f'{p:x}' for f in frames for p in f)+'\n', encoding='utf-8')
            (work/'tb.sv').write_text(TB.replace('@W@', str(width)).replace('@H@', str(height)), encoding='utf-8')
            execute(['iverilog', '-g2012', '-s', 'tb', '-o', work/'sim', *paths, work/'tb.sv'], work, folder/f'compile_{label}.log')
            output = execute(['vvp', work/'sim'], work, folder/f'simulation_{label}.log', timeout=120)
            if 'PASS JPEG GRAY TOP INDEPENDENT' not in output:
                raise RuntimeError('missing success marker')
            for index, original in enumerate(frames):
                data = bytes.fromhex((work/f'frame{index}.hex').read_text(encoding='ascii'))
                if not data.startswith(b'\xff\xd8\xff\xe0\x00\x10JFIF\x00') or not data.endswith(b'\xff\xd9'):
                    raise RuntimeError('JFIF/EOI mismatch')
                with Image.open(io.BytesIO(data)) as image:
                    image.load()
                    if image.size != (width, height) or image.mode != 'L':
                        raise RuntimeError('decoded image dimensions/mode mismatch')
                    errors = [abs(a-b) for a, b in zip(original, image.tobytes())]
                maximum, mean = max(errors), sum(errors)/len(errors)
                if maximum > 6 or mean > 2:
                    raise RuntimeError(f'predeclared q=1 pixel error bound exceeded: {maximum}, {mean}')
                profiles.append(dict(geometry=label, frame=index, status='PASS', bytes=len(data), max_error=maximum, mean_error=mean))
    if sources != {name: digest(path) for name, path in zip(RELATIVE, paths)}:
        raise RuntimeError('sources changed during test')
    write_json(folder/'results.json', dict(status='PASS', sources=sources,
        script_sha256=digest(Path(__file__)), profiles=profiles,
        logs={p.name:digest(p) for p in folder.glob('*.log')}, board_tested=False))
    print('PASS '+str(folder))


if __name__ == '__main__':
    main()
