"""Full RGB RTL encoder, independent color/entropy oracle and Pillow decoder."""
import hashlib
import io
import math
from pathlib import Path
import random
import tempfile

from PIL import Image
from test_jpeg_scan import SOURCES as PRIMITIVES
from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json

SOURCES = PRIMITIVES+[PACKAGE/p for p in (
    'dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v',
    'dsp/jpeg_color_headers/jpeg_color_headers.sv',
    'dsp/jpeg_color_scan/jpeg_color_scan.sv',
    'image/jpeg_color_mcu/jpeg_color_mcu.v',
    'dsp/jpeg_color_frame/jpeg_color_frame.sv')]
ZIG = []
for diagonal in range(15):
    ys = list(range(max(0,diagonal-7),min(7,diagonal)+1))
    if diagonal % 2 == 0:
        ys.reverse()
    ZIG.extend(y*8+diagonal-y for y in ys)
COS = [[round((1/math.sqrt(8) if k==0 else .5)*math.cos((2*n+1)*k*math.pi/16)*16384)
        for n in range(8)] for k in range(8)]


def segments(data):
    assert data[:2] == b'\xff\xd8'
    offset = 2
    result = []
    while True:
        assert data[offset] == 255
        marker = data[offset+1]
        length = int.from_bytes(data[offset+2:offset+4], 'big')
        assert length >= 2 and offset+2+length <= len(data)
        result.append((marker,data[offset+4:offset+2+length]))
        offset += 2+length
        if marker == 0xda:
            return result,offset


def huffman_tables(parts):
    tables = {}
    for marker,payload in parts:
        if marker != 0xc4:
            continue
        while payload:
            key,counts = payload[0],payload[1:17]
            values = payload[17:17+sum(counts)]
            table = {};code = 0;index = 0
            for width,count in enumerate(counts,1):
                for _ in range(count):
                    table[values[index]] = (code,width)
                    index += 1;code += 1
                code <<= 1
            assert key not in tables
            tables[key] = table
            payload = payload[17+sum(counts):]
    return tables


def standard_tables():
    stream = io.BytesIO()
    Image.new('RGB',(8,8),(83,149,201)).save(stream,format='JPEG',optimize=False,subsampling=0)
    return huffman_tables(segments(stream.getvalue())[0])


def ycc(rgb):
    r,g,b = rgb
    return tuple(max(0,min(255,n>>16)) for n in
                 (19595*r+38470*g+7471*b+32768,
                  -11059*r-21709*g+32768*b+8421376,
                  32768*r-27439*g-5329*b+8421376))


def blocks(pixels,w,h,mode):
    planes = [ycc(p) for p in pixels]
    size = 16 if mode else 8
    def get(x,y,c):
        return planes[min(h-1,y)*w+min(w-1,x)][c]
    for my in range((h+size-1)//size):
        for mx in range((w+size-1)//size):
            bx,by = mx*size,my*size
            group = []
            for c in range(3):
                for sub in range(4 if mode and c==0 else 1):
                    if mode and c:
                        samples = [(sum(get(bx+2*x+dx,by+2*y+dy,c)
                                        for dy in range(2) for dx in range(2))+2)//4
                                   for y in range(8) for x in range(8)]
                    else:
                        samples = [get(bx+(sub%2)*8+x,by+(sub//2)*8+y,c)
                                   for y in range(8) for x in range(8)]
                    group.append((c,samples))
            yield group


def block_bits(samples,quant,tables,component,previous):
    rows = [[(sum((samples[y*8+n]-128)*COS[k][n] for n in range(8))+8192)//16384
             for k in range(8)] for y in range(8)]
    coeff = [(sum(rows[n][x]*COS[k][n] for n in range(8))+8192)//16384
             for k in range(8) for x in range(8)]
    coeff = [(1 if n>=0 else -1)*((abs(n)+q//2)//q) for n,q in zip(coeff,quant)]
    zig = [coeff[i] for i in ZIG]
    codes = []
    def emit(dc,symbol,value):
        key = (0 if dc else 16)+(1 if component else 0)
        code,width = tables[key][symbol]
        size = symbol if dc else symbol&15
        codes.append(f'{code:0{width}b}')
        if size:
            amplitude = value if value>=0 else value+(1<<size)-1
            codes.append(f'{amplitude:0{size}b}')
    diff = zig[0]-previous
    emit(True,abs(diff).bit_length(),diff)
    run = 0
    for n in zig[1:]:
        if n==0:
            run += 1;continue
        while run>=16:
            emit(False,240,0);run -= 16
        emit(False,run*16+abs(n).bit_length(),n);run = 0
    if run:
        emit(False,0,0)
    return ''.join(codes),zig[0]


def entropy(pixels,w,h,mode,interval,quant,tables):
    groups = list(blocks(pixels,w,h,mode))
    predictors = [0,0,0];pending = '';output = bytearray();restart = 0
    def flush():
        nonlocal pending
        pending += '1'*((-len(pending))%8)
        for i in range(0,len(pending),8):
            byte = int(pending[i:i+8],2);output.append(byte)
            if byte==255:
                output.append(0)
        pending = ''
    for i,group in enumerate(groups):
        for component,samples in group:
            bits,predictors[component] = block_bits(samples,quant[int(component!=0)],tables,component,predictors[component])
            pending += bits
        if interval and (i+1)%interval==0 and i+1<len(groups):
            flush();output.extend((255,208+(restart%8)));restart += 1;predictors = [0,0,0]
    flush()
    return bytes(output)


def check_header(data,w,h,mode,interval,quant,tables):
    parts,offset = segments(data)
    assert offset == 613 and data[-2:] == b'\xff\xd9'
    assert huffman_tables(parts) == tables
    found = {}
    for marker,payload in parts:
        if marker==0xdb:
            while payload:
                key = payload[0];assert key in (0,1)
                found[key] = list(payload[1:65]);payload = payload[65:]
        elif marker==0xc0:
            assert payload == bytes([8,h>>8,h&255,w>>8,w&255,3,1,34 if mode else 17,0,2,17,1,3,17,1])
        elif marker==0xdd:
            assert payload == interval.to_bytes(2,'big')
        elif marker==0xda:
            assert payload == bytes([3,1,0,2,17,3,17,0,63,0])
    assert found == {i:[q[z] for z in ZIG] for i,q in enumerate(quant)}
    return data[offset:-2]


TB = r'''`timescale 1ns/1ps
module tb;
localparam W=@W@,H=@H@,N=W*H;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,table_valid=0,table_id=0,cfg_valid=0,cfg_sampling_420=0;
reg[5:0]table_index=0;reg[7:0]table_value=0;reg[15:0]cfg_restart_interval=0;
wire table_ready,cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_last,done_valid,busy;
reg start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;
reg[23:0]s_rgb=0;wire[7:0]m_data,error_code;
jpeg_color_frame #(.WIDTH(W),.HEIGHT(H))dut(.*);
reg[23:0]pixels[0:4*N-1];reg[31:0]rng=32'hbe123482;
integer frame=0,sent=0,fileout,bytes=0,last_count=0,done_count=0;
reg[8:0]held;reg was_held=0;reg was_done=0;reg[7:0]held_error;
always @(negedge clk)if(rst_n)begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=rng[2:0]!=0;m_ready=rng[5:3]!=0;
end
always @(posedge clk)if(rst_n)begin
 if(was_held&&(!m_valid||{m_last,m_data}!==held))$fatal(1,"byte stability");
 if(was_done&&(!done_valid||error_code!==held_error))$fatal(1,"DONE stability");
 was_held=m_valid&&(!ce||!m_ready);held={m_last,m_data};
 was_done=done_valid&&(!ce||!done_ready);held_error=error_code;
 if(ce&&m_valid&&m_ready)begin
  $fdisplay(fileout,"%02x",m_data);bytes=bytes+1;
  if(m_last)last_count=last_count+1;
 end
end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task write_table(input integer id,idx,value);begin
 table_id=id;table_index=idx;table_value=value;
 while(!table_ready)tick;table_valid=1;tick;table_valid=0;
end endtask
task configure(input integer mode,interval,bad);begin
 for(integer t=0;t<2;t=t+1)for(integer k=0;k<64;k=k+1)
  write_table(t,k,(bad&&t==0&&k==0)?0:((t==0)?4+(k+frame)%9:7+(k+2*frame)%7));
 cfg_sampling_420=mode;cfg_restart_interval=interval;
 while(!cfg_ready)tick;cfg_valid=1;tick;cfg_valid=0;
 while(!cfg_done)tick;if(cfg_error!==1'(bad))$fatal(1,"config result");tick;
end endtask
initial begin #2000000000;$fatal(1,"watchdog state %d",dut.state);end
initial begin
 $readmemh("pixels.hex",pixels);tick;rst_n=1;tick;
 for(frame=0;frame<4;frame=frame+1)begin
  configure(frame==1,frame==1?1:(frame==3?2:0),frame==2);
  fileout=$fopen($sformatf("file_%0d.hex",frame),"w");bytes=0;last_count=0;
  while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  for(sent=0;sent<N;sent=sent+1)begin
   s_rgb=pixels[frame*N+sent];s_sof=(sent==0);s_eol=(sent%W==W-1);
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
   if(sent%5==0)tick;
  end
  while(!done_valid)tick;
  if(error_code!=0||last_count!=1||bytes<=615)$fatal(1,"frame completion %d err=%h bytes=%d last=%d",frame,error_code,bytes,last_count);
  repeat(3)tick;while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
  $fclose(fileout);
 end
 $display("JPEG_COLOR_FRAME PASS 4 frames %0dx%0d",W,H);$finish;
end endmodule'''


def main():
    folder = evidence_dir('jpeg_color_frame')
    frozen = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    tables = standard_tables();rng = random.Random(89712);results = []
    with tempfile.TemporaryDirectory(prefix='jpeg_color_frame_') as temporary:
        td = Path(temporary)
        for w,h in ((1,1),(9,7),(17,9),(13,9),(33,17)):
            frames = []
            for frame in range(4):
                if w==h==1:
                    pixels = [[(255,0,0),(0,0,255),(0,255,0),(240,230,20)][frame]]
                elif (w,h)==(13,9):
                    pixels = [tuple(rng.randrange(256) for _ in range(3)) for _ in range(w*h)]
                else:
                    pixels = [((20+x*5+frame*9)%256,(25+y*9+frame*7)%256,(30+x*3+y*4+frame*5)%256)
                              for y in range(h) for x in range(w)]
                frames.append(pixels)
            (td/'pixels.hex').write_text(''.join(f'{r:02x}{g:02x}{b:02x}\n' for pixels in frames for r,g,b in pixels),encoding='utf-8')
            (td/'tb.sv').write_text(TB.replace('@W@',str(w)).replace('@H@',str(h)),encoding='utf-8')
            label = f'{w}x{h}'
            execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],ROOT,folder/f'{label}_compile.log')
            output = execute(['vvp',td/'sim'],td,folder/f'{label}_simulation.log',timeout=300)
            assert 'JPEG_COLOR_FRAME PASS' in output
            for frame,pixels in enumerate(frames):
                mode = int(frame in (1,2));interval = 1 if mode else (2 if frame==3 else 0)
                active_frame = 1 if frame==2 else frame
                quant = [[4+(k+active_frame)%9 for k in range(64)], [7+(k+2*active_frame)%7 for k in range(64)]]
                data = bytes(int(n,16) for n in (td/f'file_{frame}.hex').read_text(encoding='utf-8').split())
                scan = check_header(data,w,h,mode,interval,quant,tables)
                assert scan == entropy(pixels,w,h,mode,interval,quant,tables), (label,frame,'exact color entropy')
                decoded = Image.open(io.BytesIO(data));decoded.load()
                assert decoded.size==(w,h) and decoded.mode=='RGB'
                errors = [abs(a-b) for a,b in zip(bytes(c for rgb in pixels for c in rgb),decoded.tobytes())]
                maximum = max(errors);rmse = math.sqrt(sum(x*x for x in errors)/len(errors))
                if (w,h)!=(13,9):
                    assert maximum<=32 and rmse<12, (label,frame,maximum,rmse)
                (folder/f'{label}_frame{frame}.jpg').write_bytes(data)
                results.append(dict(width=w,height=h,mode='420' if mode else '444',frame=frame,
                    rejected_config_retention=frame==2,restart_interval_mcus=interval,bytes=len(data),
                    max_rgb_error=maximum,rmse_rgb=rmse,status='PASS'))
            print(label,'PASS',flush=True)
    assert frozen == {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
    write_json(folder/'results.json',dict(status='PASS',frames=len(results),results=results,sources=frozen,
        scope='Complete actual RGB raster to baseline YCbCr 444/420 JPEG, exact independent entropy and parsed headers, actual Pillow RGB decode, runtime mode/table changes and rejected-config retention, CE and backpressure. Random-image quality measured without a general quality claim.',board_tested=False))
    print(folder)


if __name__=='__main__':
    main()
