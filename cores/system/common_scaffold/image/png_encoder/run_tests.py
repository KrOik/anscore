"""Declarative PNG byte oracle + actual Pillow and zlib decoding of RTL bytes."""
from pathlib import Path
import hashlib,io,json,random,re,struct,sys,tempfile,zlib
from PIL import Image,__version__ as pillow_version
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'png_encoder.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def raw_image(pixels,w,h,mode):
    return b''.join(b'\0'+b''.join((p.to_bytes(3,'big') if mode else bytes([p&255])) for p in pixels[y*w:(y+1)*w]) for y in range(h))
def png_oracle(pixels,w,h,mode):
    raw=raw_image(pixels,w,h,mode)
    # Declarative format construction, no simulation of encoder state/timing.
    pieces=[raw[i:i+65535] for i in range(0,len(raw),65535)]
    blocks=b''.join(bytes([int(i==len(pieces)-1)])+struct.pack('<HH',len(block),len(block)^65535)+block for i,block in enumerate(pieces))
    data=b'\x78\x01'+blocks+struct.pack('>I',zlib.adler32(raw))
    def chunk(kind,body):return struct.pack('>I',len(body))+kind+body+struct.pack('>I',zlib.crc32(kind+body))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2 if mode else 0,0,0,0))+chunk(b'IDAT',data)+chunk(b'IEND',b'')
def inspect_actual(actual,pixels,w,h,mode):
    assert actual[:8]==b'\x89PNG\r\n\x1a\n';pos=8;chunks=[];idat=b''
    while pos<len(actual):
        size=struct.unpack('>I',actual[pos:pos+4])[0];kind=actual[pos+4:pos+8];data=actual[pos+8:pos+8+size]
        crc=struct.unpack('>I',actual[pos+8+size:pos+12+size])[0];assert crc==zlib.crc32(kind+data)
        chunks.append(kind.decode());pos+=size+12
        if kind==b'IDAT':idat+=data
    assert pos==len(actual) and chunks==['IHDR','IDAT','IEND']
    raw=raw_image(pixels,w,h,mode);decoder=zlib.decompressobj();decoded=decoder.decompress(idat)+decoder.flush()
    assert decoded==raw and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
    assert struct.unpack('>I',idat[-4:])[0]==zlib.adler32(raw)
    # Independent, mature file reader follows the real chunk/zlib/filter path.
    image=Image.open(io.BytesIO(actual));image.load();assert image.size==(w,h) and image.mode==('RGB' if mode else 'L')
    expected=b''.join(p.to_bytes(3,'big') if mode else bytes([p&255]) for p in pixels)
    assert image.tobytes()==expected
    # Independently parse DEFLATE stored-block lengths/complements/final flags.
    offset=2;blocks=[]
    while True:
        header=idat[offset];length,nlength=struct.unpack('<HH',idat[offset+1:offset+5]);offset+=5
        assert header in (0,1) and nlength==(length^65535) and length>0
        blocks.append(length);offset+=length
        if header==1:break
    assert offset==len(idat)-4 and sum(blocks)==len(raw)
    return dict(file_bytes=len(actual),raw_bytes=len(raw),stored_block_lengths=blocks,pillow_exact=True,zlib_exact=True,crc_adler_exact=True)
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[1:0]cfg_mode=MM;
reg[23:0]s_pixel=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
png_encoder #(.WIDTH(WW),.HEIGHT(HH))dut(.*);
reg[23:0]pixels[0:NN-1];reg[7:0]expected[0:BYTES-1];integer cyc=0,i,rep,got=0,fd;reg stalled=0;reg[9:0]held;
wire[9:0]token={m_last,m_sof,m_data};
task tick;begin @(negedge clk);#1;end endtask
always @(negedge clk)begin cyc=cyc+1;ce=cyc%13>1;m_ready=cyc%9<6;if(cyc>5000000)$fatal(1,"timeout %d",dut.state);end
always @(posedge clk)if(rst_n)begin
 if(stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=2*BYTES||m_data!==expected[got%BYTES])$fatal(1,"byte %d got %h expected %h",got,m_data,expected[got%BYTES]);
 if(m_sof!==(got%BYTES==0)||m_last!==(got%BYTES==BYTES-1))$fatal(1,"output markers");
 if(got<BYTES)$fwrite(fd,"%c",m_data);got=got+1;
 end
 if(done_valid&&!done_error&&(got%BYTES!=0||got==0))$fatal(1,"premature DONE");
end
initial begin $readmemh("PIXFILE",pixels);$readmemh("EXPFILE",expected);fd=$fopen("OUTFILE","wb");repeat(3)tick;rst_n=1;tick;
for(rep=0;rep<2;rep=rep+1)begin
cfg_mode=MM;start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;cfg_mode=3;
for(i=0;i<NN;i=i+1)begin
s_pixel=pixels[i];s_valid=1;s_sof=i==0;s_eol=i%WW==WW-1;s_last=i==NN-1;
while(!s_ready)tick;@(posedge clk);#1;tick;
end s_valid=0;while(!done_valid)tick;
if(done_error||error_code||got!=(rep+1)*BYTES||output_bytes!=BYTES)$fatal(1,"done %h count %d bytes %d",error_code,got,output_bytes);
repeat(11)tick;if(!done_valid||done_error||m_valid)$fatal(1,"held DONE");
done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
end $fclose(fd);$display("PASS png_encoder");$finish;end endmodule
'''
def run_case(name,w,h,mode,pixels):
    expected=png_oracle(pixels,w,h,mode)
    with tempfile.TemporaryDirectory(prefix='png_encode_') as tmp:
        d=Path(tmp);(d/'pix.hex').write_text('\n'.join(f'{v:06x}' for v in pixels)+'\n');(d/'exp.hex').write_text('\n'.join(f'{v:02x}' for v in expected)+'\n')
        replace={'PIXFILE':(d/'pix.hex').as_posix(),'EXPFILE':(d/'exp.hex').as_posix(),'OUTFILE':(d/'actual.png').as_posix(),'MM':mode,'WW':w,'HH':h,'NN':w*h,'BYTES':len(expected)}
        tb=re.sub(r'\b('+'|'.join(replace)+r')\b',lambda m:str(replace[m[0]]),TB);(d/'tb.sv').write_text(tb)
        execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log')
        text=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log',timeout=240);assert 'PASS png_encoder' in text
        actual=(d/'actual.png').read_bytes();assert actual==expected;result=inspect_actual(actual,pixels,w,h,mode)
    return dict(name=name,width=w,height=h,mode='RGB8' if mode else 'GRAY8',frames=2,pixels=2*w*h,**result)
def main():
    frozen=hashes();rng=random.Random(3029);rows=[]
    def run(*args):
        row=run_case(*args);rows.append(row);print(row,flush=True)
    for w,h in [(1,1),(1,7),(7,1),(2,2),(9,7),(16,12),(31,18)]:
        for mode in [0,1]:
            run('random',w,h,mode,[rng.randrange(1<<24) for _ in range(w*h)])
    for mode in [0,1]:
        for value in [0,0xffffff,0x0080ff]:run('constant',8,5,mode,[value]*40)
    for w,h,mode in [(256,255,0),(255,256,0),(257,173,1)]:
        run('stored_block_boundary',w,h,mode,[rng.randrange(1<<24) for _ in range(w*h)])
    assert hashes()==frozen
    (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,pillow_version=pillow_version,zlib_version=zlib.ZLIB_RUNTIME_VERSION,cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
