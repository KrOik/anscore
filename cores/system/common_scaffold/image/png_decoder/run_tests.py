from pathlib import Path
import sys,tempfile,json,hashlib,struct,zlib,io
import numpy as np
from PIL import Image
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'png_decoder.sv'
def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
def paeth(a,b,c):
 p=a+b-c;v=[abs(p-a),abs(p-b),abs(p-c)];return [a,b,c][v.index(min(v))]
def filtered(a,filters):
 h,w,bpp=a.shape;out=bytearray();prior=[0]*(w*bpp)
 for y in range(h):
  row=list(map(int,a[y].flat));f=filters[y%len(filters)];out.append(f)
  for x,v in enumerate(row):
   l=row[x-bpp] if x>=bpp else 0;u=prior[x];ul=prior[x-bpp] if x>=bpp else 0
   predictor=[0,l,u,(l+u)//2,paeth(l,u,ul)][f];out.append((v-predictor)&255)
  prior=row
 return bytes(out)
def encode(a,strategy='stored',filters=(0,),split=0,multiblock=False):
 h,w,bpp=a.shape;raw=filtered(a,filters)
 co=zlib.compressobj(0 if strategy=='stored' else 9,zlib.DEFLATED,15,8,zlib.Z_FIXED if strategy=='fixed' else zlib.Z_DEFAULT_STRATEGY)
 if multiblock:
  mid=len(raw)//2;packed=co.compress(raw[:mid])+co.flush(zlib.Z_SYNC_FLUSH)+co.compress(raw[mid:])+co.flush()
 else:packed=co.compress(raw)+co.flush()
 parts=[packed[i:i+split] for i in range(0,len(packed),split)] if split else [packed]
 data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,0 if bpp==1 else 2,0,0,0))+b''.join(chunk(b'IDAT',p) for p in parts)+chunk(b'IEND',b'')
 check=np.array(Image.open(io.BytesIO(data)).convert('RGB'));expected=np.repeat(a,3,axis=2) if bpp==1 else a
 assert np.array_equal(check,expected)
 return data,expected,{'raw_bytes':len(raw),'compressed_bytes':len(packed),'first_block_type':(packed[2]>>1)&3,'strategy':strategy,'filters':list(filters),'idat_chunks':len(parts),'multiblock':multiblock}
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;
reg[7:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[7:0]error_code,image_color_type;wire[15:0]image_width,image_height;wire[23:0]m_rgb;
png_decoder #(.MAX_WIDTH(MW),.MAX_HEIGHT(MH),.MAX_COMPRESSED_BYTES(MC))dut(.*);
reg[7:0]source[0:NB-1];reg[23:0]expectation[0:NP-1];integer cycles=0,got=0,i;reg stalled=0;reg[26:0]held;wire[26:0]token={m_rgb,m_sof,m_eol,m_last};
always @(negedge clk)begin cycles=cycles+1;ce=cycles%13>1;m_ready=cycles%7>1;if(cycles>20000000)$fatal(1,"timeout state %d pos %d raw %d",dut.state,dut.compressed_pos,dut.raw_count);end
always @(posedge clk)if(rst_n)begin
 if(!abort&&stalled&&(!m_valid||token!==held))$fatal(1,"hold");stalled=!abort&&m_valid&&!(ce&&m_ready);held=token;
 if(ce&&m_valid&&m_ready)begin
 if(got>=NP||m_rgb!==expectation[got])$fatal(1,"pixel%d %h expected %h",got,m_rgb,expectation[got]);
 if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))$fatal(1,"markers");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 task send;reg ok;begin ok=0;while(!ok)begin @(posedge clk);ok=ce&&s_ready;end tick;end endtask
 initial begin
 $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;
 start_valid=1;while(!start_ready)tick;@(posedge clk);tick;start_valid=0;
 for(i=0;i<NB;i=i+1)begin s_data=source[i];s_last=i==NB-1;s_valid=1;send;end s_valid=0;s_last=0;
 while(!done_valid)tick;if(frame_error||error_code!=0||got!=NP||image_width!=WW||image_height!=HH)$fatal(1,"outcome err %h got %d expected %d",error_code,got,NP);
 repeat(7)tick;if(!done_valid)$fatal(1,"done hold");$display("PASS PNG %d pixels %d cycles",got,cycles);$finish;end
endmodule'''
def run_case(name,data,expected,mw=16,mh=12,mc=4096):
 h,w,_=expected.shape;tb=TB
 with tempfile.TemporaryDirectory(prefix='png_decode_') as td:
  d=Path(td)
  for token,values in [('SRC',data),('EXP',[(int(r)<<16)|(int(g)<<8)|int(b) for r,g,b in expected.reshape(-1,3)])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  import re
  for a,b in [('MW',mw),('MH',mh),('MC',mc),('WW',w),('HH',h),('NB',len(data)),('NP',w*h)]:tb=re.sub(r'\b'+a+r'\b',str(b),tb)
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/(name+'_compile.log'))
  text=execute(['vvp',str(d/'a.vvp')],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS PNG' in text;print(name,text.splitlines()[0],flush=True)
 return {'name':name,'png_bytes':len(data),'pixels':w*h,'shape':[h,w]}
def main():
 rng=np.random.default_rng(4567);rows=[]
 for strategy in ('stored','fixed','dynamic'):
  for bpp in (1,3):
   for shape in ((1,1),(5,7),(12,16)):
    a=rng.integers(0,256,(*shape,bpp),dtype=np.uint8)
    if strategy=='dynamic':a=rng.integers(0,16,(*shape,bpp),dtype=np.uint8)
    data,expect,meta=encode(a,strategy,(0,1,2,3,4),split=7,multiblock=shape==(5,7));row=run_case(f'{strategy}_{bpp}_{shape[0]}x{shape[1]}',data,expect);row.update(meta);rows.append(row)
 for bpp in (1,3):
  a=rng.integers(0,256,(7,9,bpp),dtype=np.uint8);stream=io.BytesIO();Image.fromarray(a[:,:,0] if bpp==1 else a).save(stream,format='PNG')
  expected=np.repeat(a,3,axis=2) if bpp==1 else a;row=run_case('Pillow_saved_'+str(bpp),stream.getvalue(),expected);row['actual_pillow_file']=True;rows.append(row)
 assert {row.get('first_block_type') for row in rows}>={0,1,2}
 (H/'test_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'cases':rows},indent=2)+'\n')
if __name__=='__main__':main()
