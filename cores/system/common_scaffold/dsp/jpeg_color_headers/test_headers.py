"""Parse actual RTL color JPEG bytes and decode software-entropy fixtures with Pillow."""
from pathlib import Path
import sys,tempfile,json,io,hashlib
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
from PIL import Image
Z=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
QY=[8]+[(i*3+7)%255+1 for i in range(1,64)]
QC=[8]+[(i*7+11)%255+1 for i in range(1,64)]
CASES=[(1,1,0,0),(7,5,1,0),(8,8,0,1),(13,17,1,1),(19,10,0,2),(32,23,1,2),(25,19,0,7),(33,35,1,3),(65,49,0,1),(67,51,1,1),(65535,65535,0,65535),(65535,65535,1,65535)]

def parse(header):
    assert header[:2]==b'\xff\xd8'
    offset=2;segments=[]
    while offset<len(header):
        assert header[offset]==255
        marker=header[offset+1];length=int.from_bytes(header[offset+2:offset+4],'big')
        assert length>=2 and offset+length+2<=len(header)
        segments.append((marker,header[offset+4:offset+2+length]));offset+=length+2
    assert offset==len(header)
    return segments

def table_maps(dht):
    result={};offset=0
    while offset<len(dht):
        tid=dht[offset];counts=dht[offset+1:offset+17];n=sum(counts);symbols=dht[offset+17:offset+17+n]
        assert len(counts)==16 and len(symbols)==n and tid not in result
        mapping={};code=0;si=0
        for length,count in enumerate(counts,1):
            for _ in range(count):mapping[symbols[si]]=(code,length);si+=1;code+=1
            assert code<=1<<length
            code<<=1
        result[tid]=mapping;offset+=17+n
    assert offset==len(dht)
    return result

def reference_dht():
    file=io.BytesIO();Image.new('RGB',(8,8),(150,122,100)).save(file,format='JPEG',quality=75,subsampling=0,optimize=False)
    raw=file.getvalue();start=2;data=b''
    while start<len(raw):
        marker=raw[start+1];length=int.from_bytes(raw[start+2:start+4],'big')
        if marker==0xc4:data+=raw[start+4:start+2+length]
        if marker==0xda:break
        start+=length+2
    assert set(table_maps(data))=={0,1,16,17}
    return data

def fixture_entropy(w,h,subsampling,interval,tables,restarts):
    # Software-only coefficient fixture: Y=128,Cb=112,Cr=144 with qDC=8.
    # This validates the RTL headers/markers, not a hardware entropy encoder.
    mx=(w+(15 if subsampling else 7))//(16 if subsampling else 8)
    my=(h+(15 if subsampling else 7))//(16 if subsampling else 8)
    predictors=[0,0,0];buffer='';data=bytearray();rst=0
    def huff(t,symbol):
        code,length=tables[t][symbol];return f'{code:0{length}b}'
    def flush():
        nonlocal buffer
        buffer+='1'*((-len(buffer))%8)
        for i in range(0,len(buffer),8):
            value=int(buffer[i:i+8],2);data.append(value)
            if value==255:data.append(0)
        buffer=''
    for mcu in range(mx*my):
        for component in ([0]*4+[1,2] if subsampling else [0,1,2]):
            value=[0,-16,16][component];delta=value-predictors[component];predictors[component]=value
            category=abs(delta).bit_length();table=0 if component==0 else 1
            amplitude=delta if delta>=0 else ((1<<category)-1+delta)
            buffer+=huff(table,category)+(f'{amplitude:0{category}b}' if category else '')+huff(16+table,0)
        if mcu==mx*my-1 or (interval and (mcu+1)%interval==0):
            flush()
            if mcu!=mx*my-1:data+=restarts[rst%8];rst+=1;predictors=[0,0,0]
    return bytes(data),rst

def main():
    body=''
    for i,v in enumerate(QY):body+=f"write_table(0,6'd{i},8'd{v});\n"
    body+='commit(1);\n' # chroma table still absent
    for i,v in enumerate(QC):body+=f"write_table(1,6'd{i},8'd{v});\n"
    body+='w=0;commit(1);w=1;h=0;commit(1);h=1;\n'
    for ci,(w,h,sampling,dri) in enumerate(CASES):
        if ci==6:body+="write_table(0,17,255);write_table(1,23,1);\n"
        body+=f"w=16'd{w};h=16'd{h};sampling={sampling};interval=16'd{dri};commit(0);\n"
        # Failed commit must preserve dimensions, sampling, interval, both tables.
        body+='write_table(1,63,0);w=0;commit(1);w=1;commit(1);write_table(1,63,8\'d'+str(QC[63])+');\n'
        body+='command(0,0);for(j=0;j<8;j=j+1)command(2,j);command(1,0);\n'
    # Busy config/table/cmd inputs are backpressured and do not corrupt bytes.
    body+='while(!ready)tick;op=3;valid=1;tick;valid=0;if(!error||mv)$fatal(1,"illegal opcode");\n'
    # Reset while output is stalled must discard stream and configuration.
    body+='while(!ready)tick;op=0;valid=1;tick;valid=0;mr_override=1;while(!mv)tick;repeat(4)tick;ce_override=1;rst_n=0;tick;if(mv||busy||tr||cr||ready)$fatal(1,"reset");rst_n=1;ce_override=0;mr_override=0;tick;while(!ready)tick;valid=1;tick;valid=0;if(!error)$fatal(1,"reset configured");\n'
    tb=TB.replace('@BODY@',body)
    with tempfile.TemporaryDirectory(prefix='jpeg_color_headers_') as temporary:
        td=Path(temporary);(td/'tb.sv').write_text(tb,encoding='utf-8')
        execute(['iverilog','-g2012','-s','tb','-o',td/'sim',HERE/'jpeg_color_headers.sv',td/'tb.sv'],td,td/'compile.log')
        output=execute(['vvp',td/'sim'],td,td/'simulation.log',timeout=180)
        assert 'JPEG_COLOR_HEADERS PASS' in output,output
        commands=[];current=[]
        for line in (td/'bytes.txt').read_text().splitlines():
            value,last=map(lambda x:int(x,16),line.split());current.append(value)
            if last:commands.append(bytes(current));current=[]
        assert len(commands)==len(CASES)*10 and not current
    expected_tables=table_maps(reference_dht());results=[]
    for ci,(w,h,sampling,dri) in enumerate(CASES):
        header=commands[ci*10];restarts=commands[ci*10+1:ci*10+9];eoi=commands[ci*10+9]
        assert len(header)==613
        assert restarts==[bytes([255,208+i]) for i in range(8)] and eoi==b'\xff\xd9'
        segments=parse(header);assert [m for m,p in segments]==[0xe0,0xdb,0xc0,0xc4,0xdd,0xda]
        d=dict(segments)
        assert d[0xe0]==b'JFIF\0\x01\x01\x00\x00\x01\x00\x01\x00\x00'
        qy=QY.copy();qc=QC.copy()
        if ci>=6:qy[17]=255;qc[23]=1
        assert d[0xdb]==bytes([0]+[qy[i] for i in Z]+[1]+[qc[i] for i in Z])
        assert d[0xc0]==bytes([8,h>>8,h&255,w>>8,w&255,3,1,0x22 if sampling else 0x11,0,2,0x11,1,3,0x11,1])
        assert table_maps(d[0xc4])==expected_tables
        assert d[0xdd]==dri.to_bytes(2,'big')
        assert d[0xda]==bytes([3,1,0,2,0x11,3,0x11,0,63,0])
        decoded=False;restart_count=0;maxerror=None
        if w<100:
            entropy,restart_count=fixture_entropy(w,h,sampling,dri,expected_tables,restarts)
            image=Image.open(io.BytesIO(header+entropy+eoi));image.load();assert image.size==(w,h) and image.mode=='RGB'
            target=Image.new('YCbCr',(1,1),(128,112,144)).convert('RGB').getpixel((0,0))
            maxerror=max(abs(a-b) for pixel in image.get_flattened_data() for a,b in zip(pixel,target));assert maxerror<=2,(target,image.getpixel((0,0)))
            decoded=True
        results.append(dict(width=w,height=h,sampling='420' if sampling else '444',restart_interval=dri,header_bytes=len(header),pillow_decoded=decoded,restart_markers_in_software_entropy=restart_count,max_rgb_error=maxerror))
    evidence=dict(status='PASS',commands=len(commands),bytes=sum(map(len,commands)),cases=results,huffman_comparison='Four canonical tables independently parsed from Pillow/libjpeg default color JPEG',scope='Actual RTL headers and RST/EOI markers; software-only entropy coefficient fixtures validate headers, not a hardware color entropy pipeline.',rtl_sha256=hashlib.sha256((HERE/'jpeg_color_headers.sv').read_bytes()).hexdigest())
    (HERE/'test_evidence.json').write_text(json.dumps(evidence,indent=2)+'\n',encoding='utf-8')
    print(output.strip());print(json.dumps(evidence,indent=2))

TB=r"""
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,tv=0,tid=0,cv=0,valid=0,mr=1,sampling=0,ce_override=0,mr_override=0;
reg [5:0] ti=0;reg [7:0] tq=0;reg [15:0] w=1,h=1,interval=0;reg [1:0] op=0;reg [2:0] ri=0;
wire tr,cr,cd,er,ready,mv,ml,done,error,busy;wire [7:0] md;
jpeg_color_headers dut(.clk(clk),.rst_n(rst_n),.ce(ce),.table_valid(tv),.table_ready(tr),.table_id(tid),.table_index(ti),.table_value(tq),.cfg_valid(cv),.cfg_ready(cr),.cfg_width(w),.cfg_height(h),.cfg_restart_interval(interval),.cfg_sampling_420(sampling),.cfg_done(cd),.cfg_error(er),.cmd_valid(valid),.cmd_ready(ready),.cmd(op),.rst_index(ri),.m_data(md),.m_valid(mv),.m_last(ml),.m_ready(mr),.cmd_done(done),.cmd_error(error),.busy(busy));
integer f,j,cycles=0;reg [31:0] rng=32'ha846127b;reg stalled=0;reg [8:0] held;
reg capture=1;
always @(negedge clk)if(rst_n)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};ce=ce_override?0:rng[2:0]!=0;mr=mr_override?0:rng[6:3]==0;end
always @(posedge clk)begin
 cycles=cycles+1;if(cycles>2000000)$fatal(1,"timeout");
 if(rst_n)begin
  if(stalled&&(!mv||{md,ml}!==held))$fatal(1,"stability");stalled=mv&&(!ce||!mr);held={md,ml};
  if(ce&&mv&&mr&&capture)$fdisplay(f,"%02x %01x",md,ml);
 end else stalled=0;
end
task tick;begin @(posedge clk);#1;@(negedge clk);#1;end endtask
task write_table(input id,input [5:0] index,input [7:0] value);begin
 while(!tr)tick;tid=id;ti=index;tq=value;tv=1;tick;tv=0;
end endtask
task commit(input bad);begin
 while(!cr)tick;cv=1;tv=1;valid=1;#1;if(tr||ready)$fatal(1,"config priority");tick;cv=0;tv=0;valid=0;
 while(!cd&&!er)tick;
 if(bad?(!er||!cd):(!cd||er))$fatal(1,"config result");
 tick;
end endtask
task command(input [1:0] operation,input [2:0] restart);begin
 while(!ready)tick;valid=1;op=operation;ri=restart;tick;valid=0;
 // Hold conflicting requests while busy; their ready signals must stay low.
 cv=1;tv=1;valid=1;
 while(!done)begin if(cr||tr||ready)$fatal(1,"busy ready");tick;end
 cv=0;tv=0;valid=0;if(error||busy)$fatal(1,"command result");tick;
end endtask
initial begin
 f=$fopen("bytes.txt","w");@(negedge clk);tick;rst_n=1;tick;
 while(!ready)tick;valid=1;op=0;tick;valid=0;if(!error||mv)$fatal(1,"unconfigured command");commit(1);
 @BODY@
 $fclose(f);$display("JPEG_COLOR_HEADERS PASS");$finish;
end
endmodule
"""
if __name__=='__main__':main()
