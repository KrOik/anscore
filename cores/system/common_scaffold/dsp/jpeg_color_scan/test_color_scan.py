from pathlib import Path
import sys,tempfile,json,random,math,io,hashlib
from PIL import Image
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
from integration.tooling import execute
BASE=HERE.parents[1]
SOURCES=[BASE/p for p in ('dsp/dct8x8/dct8x8_serial.sv','dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv','dsp/jpeg_entropy/jpeg_baseline_symbols.v','dsp/jpeg_huffman/jpeg_default_huffman.sv','dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv','dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v')]+[HERE/'jpeg_color_scan.sv']
QY=[5+i%9 for i in range(64)];QC=[11+(i*3)%13 for i in range(64)]
def header(width,height,sampling,interval):
 im=Image.new('RGB',(width,height),(128,128,128));f=io.BytesIO();im.save(f,format='JPEG',qtables=[QY,QC],subsampling=2 if sampling else 0,optimize=False)
 data=f.getvalue();off=2;tables={}
 while True:
  tag=data[off+1];length=int.from_bytes(data[off+2:off+4],'big');payload=data[off+4:off+2+length]
  if tag==0xc4:
   while payload:
    key=payload[0];counts=payload[1:17];n=sum(counts);values=payload[17:17+n];c=0;k=0;t={}
    for bits,count in enumerate(counts,1):
     for _ in range(count):t[values[k]]=(c,bits);c+=1;k+=1
     c<<=1
    tables[key]=t;payload=payload[17+n:]
  end=off+2+length
  if tag==0xda:
   dri=b'\xff\xdd\x00\x04'+interval.to_bytes(2,'big') if interval else b''
   return data[:off]+dri+data[off:end],tables
  off=end
def coefficients(pixels,quant):
 c=[[math.floor((1/math.sqrt(8) if k==0 else .5)*math.cos((2*n+1)*k*math.pi/16)*16384+.5) for n in range(8)] for k in range(8)]
 rows=[[(sum((pixels[y*8+n]-128)*c[k][n] for n in range(8))+8192)//16384 for k in range(8)] for y in range(8)]
 coeff=[(sum(rows[n][x]*c[k][n] for n in range(8))+8192)//16384 for k in range(8) for x in range(8)]
 q=[(-1 if v<0 else 1)*((abs(v)+quant[i]//2)//quant[i]) for i,v in enumerate(coeff)]
 out=[]
 for diagonal in range(15):
  ys=list(range(max(0,diagonal-7),min(7,diagonal)+1))
  if diagonal%2==0:ys.reverse()
  out.extend(q[y*8+diagonal-y] for y in ys)
 return out
def entropy(blocks,sampling,interval,tables):
 pred=[0,0,0];bits='';out=bytearray();markers=[];bpm=6 if sampling else 3;rst=0
 def flush():
  nonlocal bits
  bits+='1'*((-len(bits))%8)
  for i in range(0,len(bits),8):
   b=int(bits[i:i+8],2);out.append(b);markers.append(0)
   if b==255:out.append(0);markers.append(0)
  bits=''
 def emit(component,dc,sym,value):
  nonlocal bits
  code,n=tables[(0 if dc else 16)+(component!=0)][sym];bits+=format(code,f'0{n}b');size=sym if dc else sym%16
  if size:bits+=format(value if value>=0 else value+(1<<size)-1,f'0{size}b')
 for bi,(component,pixels) in enumerate(blocks):
  coeff=coefficients(pixels,QC if component else QY);diff=coeff[0]-pred[component];pred[component]=coeff[0]
  emit(component,True,abs(diff).bit_length(),diff);run=0
  for v in coeff[1:]:
   if not v:run+=1;continue
   while run>=16:emit(component,False,240,0);run-=16
   emit(component,False,run*16+abs(v).bit_length(),v);run=0
  if run:emit(component,False,0,0)
  if (bi+1)%bpm==0 and interval and (bi+1)//bpm%interval==0 and bi+1<len(blocks):
   flush();out.extend((255,208+rst));markers.extend((1,1));rst=(rst+1)%8;pred=[0,0,0]
 flush();return bytes(out),markers
def run(sampling,mcus,interval,kind):
 rng=random.Random(619+sampling+mcus);components=[0,0,0,0,1,2] if sampling else [0,1,2];blocks=[]
 for mcu in range(mcus):
  for slot,comp in enumerate(components):
   if kind=='constant':pixels=[[160,90,175][comp]]*64
   elif kind=='dc':pixels=[40+(mcu*23+comp*37+slot*11)%170]*64
   else:pixels=[rng.randrange(24,232) for _ in range(64)]
   blocks.append((comp,pixels))
 size=16 if sampling else 8;hdr,tables=header(size*mcus,size,sampling,interval);expected,markers=entropy(blocks,sampling,interval,tables)
 pixels=[p for _,data in blocks for p in data];components=[c for c,_ in blocks for _ in range(64)]
 with tempfile.TemporaryDirectory(prefix='jpeg_color_') as td:
  td=Path(td);(td/'pixels.hex').write_text('\n'.join(f'{p:02x}' for p in pixels)+'\n');(td/'components.hex').write_text('\n'.join(str(c) for c in components)+'\n');(td/'expected.hex').write_text('\n'.join(f'{b|(m<<8)|(int(i==len(expected)-1)<<9):x}' for i,(b,m) in enumerate(zip(expected,markers)))+'\n')
  tb=f'''module tb;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;
 reg table_id=0,table_valid=0,cfg_valid=0,start_valid=0,abort=0,s_valid=0,m_ready=0,done_ready=0;
 reg [5:0]table_index=0;reg [7:0]table_value=0,s_data=0;reg [1:0]s_component=0;
 reg [31:0]cfg_total_mcus={mcus};reg [15:0]cfg_restart_interval={interval};reg cfg_sampling_420={sampling};
 reg s_block_first=0,s_block_last=0,s_frame_last=0;
 wire table_ready,cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_marker,m_scan_last,done_valid,busy;
 wire [7:0]m_data,error_code;jpeg_color_scan dut(.*);
 reg [7:0]pixels[0:{len(pixels)-1}];reg [1:0]components[0:{len(pixels)-1}];reg [9:0]expected[0:{len(expected)-1}];
 integer i,j,k,tx,rx,cycle;reg held=0;reg [9:0]held_data;
 always @(posedge clk)if(rst_n)begin
 if(held&&(!m_valid||{{m_scan_last,m_marker,m_data}}!==held_data))$fatal(1,"held bytes");held=m_valid&&!(ce&&m_ready);held_data={{m_scan_last,m_marker,m_data}};
 end else held=0;
 task load_tables(input integer zero);begin
 for(j=0;j<2;j=j+1)for(i=0;i<64;i=i+1)begin @(negedge clk);ce=1;table_valid=1;table_id=j;table_index=i;table_value=j?(11+(i*3)%13):(5+i%9);if(zero&&i==63&&j==1)table_value=0;end
 @(negedge clk);table_valid=0;cfg_valid=1;@(negedge clk);cfg_valid=0;
 while(!cfg_done&&!cfg_error)@(negedge clk);
 if(zero?!cfg_error:!cfg_done)$fatal(1,"table validation");@(negedge clk);
 end endtask
 initial begin
 $readmemh("pixels.hex",pixels);$readmemh("components.hex",components);$readmemh("expected.hex",expected);
 repeat(3)@(negedge clk);rst_n=1;
 // Incomplete dual table is rejected. Then good config and a rejected zero commit preserve active tables.
 cfg_valid=1;@(negedge clk);cfg_valid=0;if(!cfg_error)$fatal(1,"incomplete accepted");
 load_tables(0);load_tables(1);
 // Repeat two complete scans without reset: initial predictor reset must reset all three components.
 for(k=0;k<2;k=k+1)begin
 @(negedge clk);start_valid=1;if(!start_ready)$fatal(1,"start blocked");@(negedge clk);start_valid=0;tx=0;rx=0;cycle=0;
 while(!done_valid)begin
  @(negedge clk);ce=(cycle%11!=2);m_ready=(cycle%7!=1);s_valid=tx<{len(pixels)}&&cycle%4!=1;
  if(tx<{len(pixels)})begin s_data=pixels[tx];s_component=components[tx];s_block_first=(tx%64==0);s_block_last=(tx%64==63);s_frame_last=(tx=={len(pixels)-1});end
  @(posedge clk);if(ce&&s_valid&&s_ready)tx=tx+1;
  if(ce&&m_valid&&m_ready)begin if(rx>={len(expected)}||{{m_scan_last,m_marker,m_data}}!==expected[rx])$fatal(1,"byte %d got %h expected %h",rx,{{m_scan_last,m_marker,m_data}},expected[rx]);rx=rx+1;end
  #1;if(error_code)$fatal(1,"pipeline error %h",error_code);cycle=cycle+1;if(cycle>1000000)$fatal(1,"timeout");
 end
 if(tx!={len(pixels)}||rx!={len(expected)})$fatal(1,"length");
 repeat(4)begin @(negedge clk);ce=1;if(!done_valid||error_code)$fatal(1,"done held");end
 abort=1;
 repeat(3)begin @(negedge clk);if(!done_valid||error_code)$fatal(1,"terminal abort changed completion");end
 abort=0;
 done_ready=1;@(negedge clk);done_ready=0;s_valid=0;
 end
 $display("JPEG COLOR PASS");$finish;end
 initial begin #1000000000;$fatal(1,"watchdog");end endmodule'''
  (td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
  assert 'JPEG COLOR PASS' in execute(['vvp',td/'sim'],td,td/'sim.log',timeout=300)
 image=Image.open(io.BytesIO(hdr+expected+b'\xff\xd9'));image.load();assert image.size==(size*mcus,size)
 error=None
 if kind=='constant':
  target=Image.new('YCbCr',image.size,(160,90,175)).convert('RGB');error=max(abs(a-b) for a,b in zip(image.convert('RGB').tobytes(),target.tobytes()));assert error<=4,error
 result={'sampling':'420' if sampling else '444','mcus':mcus,'restart_interval':interval,'fixture':kind,'entropy_bytes':len(expected),'restart_markers':sum(markers)//2,'replays':2,'decoder':'Pillow','constant_RGB_max_error':error,'result':'PASS'}
 print(result);return result
if __name__=='__main__':
 results=[run(*cfg) for cfg in ((0,1,0,'constant'),(0,4,1,'dc'),(1,3,2,'random'),(1,2,1,'constant'),(0,10,1,'dc'))]
 (HERE/'evidence.json').write_text(json.dumps({'result':'PASS','cases':results,'board':False,'rtl_sha256':hashlib.sha256((HERE/'jpeg_color_scan.sv').read_bytes()).hexdigest()},indent=2)+'\n')
