"""Single 8x8 grayscale scan: actual RTL chain, independent entropy and JPEG decoder."""
import hashlib,io,math,random,sys,tempfile
from pathlib import Path
from PIL import Image
from tooling import ROOT,PACKAGE,execute,evidence_dir,write_json

SOURCES=[PACKAGE/p for p in (
 'dsp/dct8x8/dct8x8_serial.sv', 'dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv',
 'dsp/jpeg_entropy/jpeg_baseline_symbols.v', 'dsp/jpeg_huffman/jpeg_default_huffman.sv',
 'dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv')]

def header_and_tables(pixels):
    image=Image.new('L',(8,8));image.putdata(pixels)
    stream=io.BytesIO();image.save(stream,format='JPEG',qtables=[[8]*64],optimize=False)
    data=stream.getvalue();offset=2;tables={}
    while offset<len(data):
        assert data[offset]==255
        marker=data[offset+1];length=int.from_bytes(data[offset+2:offset+4],'big')
        payload=data[offset+4:offset+2+length]
        if marker==0xc4:
            while payload:
                key=payload[0];counts=payload[1:17];n=sum(counts);values=payload[17:17+n]
                code=0;pos=0;table={}
                for bits,count in enumerate(counts,1):
                    for _ in range(count): table[values[pos]]=(code,bits);code+=1;pos+=1
                    code<<=1
                tables[key]=table;payload=payload[17+n:]
        offset+=2+length
        if marker==0xda:return data[:offset],tables
    raise RuntimeError('SOS missing')

def oracle(pixels,tables,previous_dc=0,return_bits=False):
    c=[[round((1/math.sqrt(8) if k==0 else .5)*math.cos((2*n+1)*k*math.pi/16)*16384)
        for n in range(8)] for k in range(8)]
    rows=[[(sum((pixels[y*8+n]-128)*c[k][n] for n in range(8))+8192)//16384
           for k in range(8)] for y in range(8)]
    coeff=[(sum(rows[n][x]*c[k][n] for n in range(8))+8192)//16384
           for k in range(8) for x in range(8)]
    quant=[(-1 if v<0 else 1)*((abs(v)+4)//8) for v in coeff]
    zig=[]
    for diagonal in range(15):
        ys=list(range(max(0,diagonal-7),min(7,diagonal)+1))
        if diagonal%2==0:ys.reverse()
        zig.extend(quant[y*8+diagonal-y] for y in ys)
    bits=''
    def emit(dc,symbol,value):
        nonlocal bits
        code,width=tables[0 if dc else 0x10][symbol]
        bits+=format(code,f'0{width}b')
        size=symbol if dc else symbol%16
        if size:bits+=format(value if value>=0 else value+(1<<size)-1,f'0{size}b')
    difference=zig[0]-previous_dc
    emit(True,abs(difference).bit_length(),difference)
    run=0
    for value in zig[1:]:
        if not value:run+=1;continue
        while run>=16:emit(False,0xf0,0);run-=16
        emit(False,run*16+abs(value).bit_length(),value);run=0
    if run:emit(False,0,0)
    if return_bits:return bits,zig[0]
    bits+='1'*((-len(bits))%8)
    out=bytearray()
    for i in range(0,len(bits),8):
        value=int(bits[i:i+8],2);out.append(value)
        if value==255:out.append(0)
    return bytes(out)

TB='''`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=1,run=0,sv=0,mready=0,tv=0,qcfg=0;
reg[5:0]ti=0;wire tr,qr,qdone,qerr;
reg signed[15:0]samples[0:63];integer sent=0,qindex=0,outfile,bytes=0;
reg accepted=0;reg[31:0]rnd=32'hbac987;
wire dr,dv,dsat;wire signed[15:0]dd;
dct8x8_serial dct(.clk(clk),.rst_n(rst),.ce(ce),.cfg_valid(1'b0),.cfg_inverse(1'b0),
.cfg_ready(),.cfg_done(),.s_data(samples[sent<64?sent:63]),.s_valid(sv),.s_ready(dr),
.m_data(dd),.m_valid(dv),.m_ready(qr),.busy(),.saturated(dsat));
wire qv,qsat,coeff_ready;wire signed[15:0]qd;
jpeg_quant_zigzag quant(.clk(clk),.rst_n(rst),.ce(ce),.table_valid(tv),.table_ready(tr),
.table_index(ti),.table_value(8'd8),.cfg_valid(qcfg),.cfg_inverse(1'b0),.cfg_ready(),
.cfg_done(qdone),.cfg_error(qerr),.s_data(dd),.s_valid(dv),.s_ready(qr),
.m_data(qd),.m_valid(qv),.m_ready(coeff_ready),.busy(),.saturated(qsat));
wire token_valid,token_ready,tdc,tend,trestart;wire[3:0]trun,tsize,serror;
wire[15:0]tamp;wire[1:0]tcomponent;
jpeg_baseline_symbols symbols(.clk(clk),.rst(!rst),.ce(ce),.s_coefficient(qd),
.s_valid(qv),.s_ready(coeff_ready),.s_first(qindex==0),.s_last(qindex==63),
.s_component(2'd0),.s_restart(1'b0),.token_valid(token_valid),.token_ready(token_ready),
.token_dc(tdc),.token_run(trun),.token_size(tsize),.token_amplitude(tamp),
.token_block_end(tend),.token_restart(trestart),.token_component(tcomponent),.error_code(serror));
wire hv,hr,hend;wire[15:0]hc,ha;wire[4:0]hcb,hab;wire[3:0]herror;
jpeg_default_huffman huff(.clk(clk),.rst_n(rst),.ce(ce),.s_valid(token_valid),.s_ready(token_ready),
.s_dc(tdc),.s_run(trun),.s_size(tsize),.s_amplitude(tamp),.s_block_end(tend),
.s_restart(trestart),.s_component(tcomponent),.m_valid(hv),.m_ready(hr),.m_code(hc),
.m_code_bits(hcb),.m_amplitude(ha),.m_amplitude_bits(hab),.m_block_end(hend),
.m_restart(),.m_component(),.error_code(herror));
wire bv,bl,berr,done;wire[7:0]bd;
// One block is the entire scan; only here does block_end also mean scan flush.
jpeg_entropy_bitpacker packer(.clk(clk),.rst_n(rst),.ce(ce),.s_code(hc),.s_amplitude(ha),
.s_code_bits(hcb),.s_amplitude_bits(hab),.s_flush(hend),.s_valid(hv),.s_ready(hr),
.m_data(bd),.m_valid(bv),.m_last(bl),.m_ready(mready),.input_error(berr),
.flush_done(done),.pending_bits());
always @(posedge clk)if(rst&&run)begin
 accepted=ce&&sv&&dr;if(accepted)sent<=sent+1;
 if(ce&&qv&&coeff_ready)qindex<=(qindex+1)%64;
 if(ce&&bv&&mready)begin $fdisplay(outfile,"%02x",bd);bytes=bytes+1;end
end
always @(negedge clk)if(run)begin
 if(serror||herror||berr||qerr||dsat||qsat)$fatal(1,"chain diagnostics symbols=%d huff=%d bits=%b qerr=%b dsat=%b qsat=%b",serror,herror,berr,qerr,dsat,qsat);
 if(ce&&done)begin if(sent!=64||bytes==0)$fatal(1,"incomplete");
 $fclose(outfile);$display("JPEG_SCAN PASS bytes=%0d",bytes);$finish;end
 rnd={rnd[30:0],rnd[31]^rnd[21]^rnd[1]^rnd[0]};ce=rnd[1]||rnd[3];mready=rnd[7];
 if(!sv||accepted)sv=sent<64&&(rnd[2]||rnd[4]);
end
initial begin #5000000;$fatal(1,"timeout");end
initial begin
$readmemh("pixels.hex",samples);outfile=$fopen("entropy.hex","w");
repeat(3)@(negedge clk);#1;rst=1;
for(integer i=0;i<64;i=i+1)begin @(negedge clk);ti=i;tv=1;end
@(negedge clk);tv=0;qcfg=1;@(negedge clk);qcfg=0;
wait(qdone);@(negedge clk);#1;run=1;
end
endmodule
'''

def main():
    folder=evidence_dir('jpeg_scan');rng=random.Random(182)
    fixtures={'dc':[173]*64,'stripes':[64+((x+y)%4)*40 for y in range(8) for x in range(8)],
              'random':[rng.randrange(256) for _ in range(64)]}
    results=[]
    hashes={str(s.relative_to(ROOT)):hashlib.sha256(s.read_bytes()).hexdigest() for s in SOURCES}
    with tempfile.TemporaryDirectory(prefix='jpeg_scan_') as temp:
        p=Path(temp);(p/'tb.sv').write_text(TB,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,folder/'compile.log')
        for name,pixels in fixtures.items():
            (p/'pixels.hex').write_text(''.join(f'{(v-128)&65535:04x}\n' for v in pixels),encoding='utf-8')
            output=execute(['vvp',p/'sim'],p,folder/f'{name}.log')
            if 'JPEG_SCAN PASS' not in output:raise RuntimeError('success marker missing')
            actual=bytes(int(line,16) for line in (p/'entropy.hex').read_text().split())
            header,tables=header_and_tables(pixels);expected=oracle(pixels,tables)
            if actual!=expected:raise AssertionError(f'{name}: entropy mismatch {actual.hex()} != {expected.hex()}')
            decoded=Image.open(io.BytesIO(header+actual+b'\xff\xd9'));decoded.load()
            error=max(abs(a-b) for a,b in zip(pixels,decoded.tobytes()))
            if decoded.size!=(8,8) or error>16:raise AssertionError(f'{name}: decode error {error}')
            results.append({'fixture':name,'entropy_bytes':len(actual),'max_pixel_error':error,'status':'PASS'})
    for source in SOURCES:
        if hashlib.sha256(source.read_bytes()).hexdigest()!=hashes[str(source.relative_to(ROOT))]:
            raise RuntimeError('source changed during test')
    write_json(folder/'result.json',{'status':'PASS','scope':'one-block grayscale scans with software headers',
                                    'fixtures':results,'sources':hashes,'board_tested':False})
    print(results);print(folder)
if __name__=='__main__':main()
