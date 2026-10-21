from pathlib import Path
import sys,tempfile,json,hashlib,random
H=Path(__file__).resolve().parent;sys.path.insert(0,str(H.parents[1]));from integration.tooling import execute
SOURCES={n:hashlib.sha256((H/n).read_bytes()).hexdigest() for n in ('raw14_pack.sv','raw14_unpack.sv')}
def packed(v):
 low=sum((p&63)<<(6*i) for i,p in enumerate(v));return [p>>6 for p in v]+list(low.to_bytes(3,'little'))
def unpacked(v):
 low=int.from_bytes(bytes(v[4:]),'little');return [(v[i]<<6)|((low>>(6*i))&63) for i in range(4)]
def model(kind,tokens):
 need=4 if kind=='pack' else 7;give=7 if kind=='pack' else 4;buf=[];locked=False;gs=0;output=[];errors=[]
 for data,sof,eol in tokens:
  if eol and (sof or len(buf)!=need-1):buf=[];locked=False;errors.append(2)
  elif sof and buf:buf=[data];locked=True;gs=1;errors.append(3)
  elif not locked and not sof:buf=[];errors.append(4)
  else:
   if not buf:gs=sof;locked=True
   buf.append(data)
   if len(buf)==need:
    out=packed(buf) if kind=='pack' else unpacked(buf);output.extend([(v,int(gs and i==0),int(eol and i==give-1)) for i,v in enumerate(out)]);buf=[]
 return output,errors
TB=r'''module tb;
localparam IW=@IW@,OW=@OW@;reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1;reg[IW-1:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0;wire s_ready;wire[OW-1:0]m_data;wire m_valid,m_sof,m_eol;reg m_ready=0,error_ready=0;wire protocol_error,error_valid;wire[7:0]error_code;wire[31:0]error_count;
@INSTANCE@
reg[15:0]stim[0:@NI@-1],expectation[0:@NE@-1];integer sent=0,got=0,cycles=0;reg[31:0]rng=32'h1234abcd;reg drive=1,held=0;reg[OW+1:0]heldword;
always @(negedge clk)if(rst_n&&drive)begin
 ce=rng[0]||rng[5];m_ready=rng[2]||rng[7];
 s_valid=sent<@NI@;if(sent<@NI@)begin s_data=stim[sent][IW-1:0];s_sof=stim[sent][14];s_eol=stim[sent][15];end
end
always @(posedge clk)if(rst_n)begin
 cycles=cycles+1;if(cycles>3000000)$fatal(1,"watchdog sent%0d got%0d",sent,got);
 rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 if(held&&(!m_valid||{m_sof,m_eol,m_data}!==heldword))$fatal(1,"held output changed");
 held=m_valid&&!(ce&&m_ready);heldword={m_sof,m_eol,m_data};
 if(s_valid&&s_ready)sent=sent+1;
 if(m_valid)begin
 if(got>=@NO@||m_data!==expectation[got][OW-1:0]||m_sof!==expectation[got][14]||m_eol!==expectation[got][15])$fatal(1,"output mismatch got%0d data%h want%h",got,m_data,expectation[got]);
 if(ce&&m_ready)got=got+1;
 end
end
initial begin $readmemh("@STIM@",stim);$readmemh("@EXPECT@",expectation);repeat(3)@(negedge clk);#1;rst_n=1;
while(sent<@NI@||got<@NO@)@(negedge clk);repeat(12)@(negedge clk);#1;drive=0;ce=0;s_valid=0;error_ready=1;
if(error_count!=@ERRORS@||protocol_error!==(@ERRORS@!=0)||error_valid!==(@ERRORS@!=0))$fatal(1,"erroraccount count%0d code%0d",error_count,error_code);
if(@ERRORS@!=0&&error_code!=@FIRST@)$fatal(1,"firsterror held");
repeat(5)@(negedge clk);#1;if(error_valid!==(@ERRORS@!=0))$fatal(1,"CEoff errorack");ce=1;@(negedge clk);#1;if(error_valid)$fatal(1,"errorack");
$display("PASS RAW14 @KIND@ input=%0d output=%0d errors=%0d cycles=%0d",sent,got,error_count,cycles);$finish;end endmodule'''
def run(kind,label,tokens):
 expected,errors=(list(tokens),[]) if kind=='chain' else model(kind,tokens);iw,ow=(14,14) if kind=='chain' else (14,8) if kind=='pack' else (8,14)
 instance=f'raw14_{kind} dut(.*);'
 if kind=='chain':instance=r'''wire[7:0]ld;wire lv,lr,ls,le,pe0,pe1,ev0,ev1;wire[7:0]ec0,ec1;wire[31:0]en0,en1;
 assign protocol_error=pe0||pe1;assign error_valid=ev0||ev1;assign error_code=ev0?ec0:ec1;assign error_count=en0+en1;
 raw14_pack a(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(s_data),.s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),.m_data(ld),.m_valid(lv),.m_sof(ls),.m_eol(le),.m_ready(lr),.protocol_error(pe0),.error_valid(ev0),.error_ready(error_ready),.error_code(ec0),.error_count(en0));
 raw14_unpack b(.clk(clk),.rst_n(rst_n),.ce(ce),.s_data(ld),.s_valid(lv),.s_sof(ls),.s_eol(le),.s_ready(lr),.m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready),.protocol_error(pe1),.error_valid(ev1),.error_ready(error_ready),.error_code(ec1),.error_count(en1));'''

 with tempfile.TemporaryDirectory(prefix='raw14_codec_') as td:
  p=Path(td)
  for name,values in [('stim.hex',tokens),('expect.hex',expected or [(0,0,0)])]:(p/name).write_text('\n'.join(f'{d|(sof<<14)|(eol<<15):04x}' for d,sof,eol in values)+'\n')
  tb=TB
  for k,v in dict(IW=iw,OW=ow,NI=len(tokens),NO=len(expected),NE=max(1,len(expected)),INSTANCE=instance,STIM=(p/'stim.hex').as_posix(),EXPECT=(p/'expect.hex').as_posix(),ERRORS=len(errors),FIRST=errors[0] if errors else 0,KIND=kind).items():tb=tb.replace('@'+k+'@',str(v))
  (p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*(list(H.glob('raw14_*.sv')) if kind=='chain' else [H/f'raw14_{kind}.sv']),p/'tb.sv'],H,H/f'{label}_{kind}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'{label}_{kind}_simulation.log');assert 'PASS RAW14' in out
 print(out.splitlines()[0]);return dict(name=label,module='raw14_'+kind,status='PASS',input_tokens=len(tokens),output_tokens=len(expected),errors=errors,output=out)
def frame(pixels,width):return [(v,int(i==0),int(i%width==width-1)) for i,v in enumerate(pixels)]
def byte_frame(pixels,width):
 b=[]
 for i in range(0,len(pixels),4):
  block=packed(pixels[i:i+4]);b.extend((v,int(i==0 and j==0),int((i+4)%width==0 and j==6)) for j,v in enumerate(block))
 return b
def main():
 assert packed([0x0001,0x0156,0x2aab,0x3fff])==[0,5,0xaa,0xff,0x81,0xb5,0xfe]
 pixels=[v for i in range(16384) for v in (i,i^16383,(i*53)&16383,(i*109)&16383)];rows=[run('pack','all_values',frame(pixels,256)),run('unpack','all_values',byte_frame(pixels,256))]
 rng=random.Random(73)
 for width,height in [(4,1),(12,23),(100,19),(28,31)]:
  pixels=[rng.randrange(16384) for _ in range(width*height)];rows.extend([run('pack',f'random_{width}_{height}',frame(pixels,width)),run('unpack',f'random_{width}_{height}',byte_frame(pixels,width))])
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,standard_fixture=dict(pixels=[1,0x156,0x2aab,0x3fff],bytes=[0,5,0xaa,0xff,0x81,0xb5,0xfe]),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
