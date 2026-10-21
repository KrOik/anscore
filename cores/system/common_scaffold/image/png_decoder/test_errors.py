"""Malformed container/zlib errors followed immediately by healthy frame recovery."""
from run_tests import H,RTL,ROOT,TB,execute,chunk,encode
import numpy as np,zlib,struct,tempfile,re,json,hashlib
from pathlib import Path

def unpack(data):
 pos=8;out=[]
 while pos<len(data):n=int.from_bytes(data[pos:pos+4],'big');out.append((data[pos+4:pos+8],data[pos+8:pos+8+n]));pos+=12+n
 return out
def repack(parts):return b'\x89PNG\r\n\x1a\n'+b''.join(chunk(t,d) for t,d in parts)
def cases(good):
 parts=unpack(good);ih=parts[0][1];zz=parts[1][1];rows=[]
 def ihdr(name,index,value,code=0x17):
  data=bytearray(ih);data[index]=value;rows.append((name,repack([(b'IHDR',data)]+parts[1:]),code))
 bad=bytearray(good);bad[0]=0;rows.append(('signature',bytes(bad),0x10))
 for name,index,value in [('depth16',8,16),('indexed',9,3),('rgba',9,6),('interlace',12,1),('compression',10,1),('filter_method',11,1)]:ihdr(name,index,value)
 ihdr('width_oversize',3,17,0x16)
 bad=bytearray(good);bad[32]^=1;rows.append(('IHDR_CRC',bytes(bad),0x15))
 bad=bytearray(good);bad[-13]^=1;rows.append(('IDAT_CRC',bytes(bad),0x15))
 changed=bytearray(zz);changed[0]=0;rows.append(('zlib_header',repack([parts[0],(b'IDAT',changed),parts[-1]]),0x20))
 changed=bytearray(zz);changed[-1]^=1;rows.append(('adler',repack([parts[0],(b'IDAT',changed),parts[-1]]),0x33))
 changed=bytearray(zz);changed[5]^=1;rows.append(('stored_nlen',repack([parts[0],(b'IDAT',changed),parts[-1]]),0x23))
 raw=zlib.decompress(zz)
 for name,r,code in [('invalid_filter',bytes([5])+raw[1:],0x31),('short_raw',raw[:-1],0x32),('excess_raw',raw+b'\x00',0x30)]:rows.append((name,repack([parts[0],(b'IDAT',zlib.compress(r,0)),parts[-1]]),code))
 rows.append(('unknown_critical',repack([parts[0],(b'ABCD',b''),*parts[1:]]),0x13))
 rows.append(('reserved_chunk_bit',repack([parts[0],(b'abcd',b''),*parts[1:]]),0x12))
 rows.append(('PLTE_gray',repack([parts[0],(b'PLTE',bytes(3)),*parts[1:]]),0x12))
 rows.append(('nonconsecutive_IDAT',repack([parts[0],(b'IDAT',zz[:2]),(b'tEXt',b''),(b'IDAT',zz[2:]),parts[-1]]),0x12))
 bad=repack([parts[0],(b'tEXt',b'author\x00test'),*parts[1:]]);bad=bytearray(bad);bad[33+12+11-1]^=1;rows.append(('ancillary_CRC',bytes(bad),0x15))
 rows.append(('early_last',good[:20],0x11))
 rows.append(('chunk_length_high_bit',good[:8]+b'\x80\x00\x00\x00',0x12))
 from test_deflate_limits import Writer,canonical
 def packed_error(name,deflate,code):rows.append((name,repack([parts[0],(b'IDAT',b'\x78\x01'+deflate+b'\x00\x00\x00\x01'),parts[-1]]),code))
 wr=Writer();wr.field(7,3);packed_error('reserved_btype',wr.bytes(),0x22)
 wr=Writer();wr.field(5,3);wr.field(31,5);wr.field(0,5);wr.field(0,4);packed_error('HLIT288',wr.bytes(),0x25)
 for ndist in (31,32):
  wr=Writer();wr.field(5,3);wr.field(0,5);wr.field(ndist-1,5);wr.field(0,4);packed_error('HDIST'+str(ndist),wr.bytes(),0x25)
 wr=Writer();wr.field(5,3);wr.field(0,5);wr.field(0,5);wr.field(0,4)
 for _ in range(4):wr.field(1,3)
 packed_error('oversubscribed_CL',wr.bytes(),0x24)
 incomplete=bytes.fromhex('7801058001080000008004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040400020001')
 try:zlib.decompress(incomplete);raise AssertionError('reference accepted incomplete table')
 except zlib.error:pass
 rows.append(('incomplete_CL',repack([parts[0],(b'IDAT',incomplete),parts[-1]]),0x24))
 lit=canonical([8]*144+[9]*112+[7]*24+[8]*8);dist=canonical([5]*32)
 wr=Writer();wr.field(3,3);wr.symbol(257,lit);wr.symbol(0,dist);packed_error('distance_before_output',wr.bytes(),0x29)
 wr=Writer();wr.field(3,3);wr.symbol(286,lit);packed_error('reserved_literal',wr.bytes(),0x27)
 wr=Writer();wr.field(3,3);wr.symbol(0,lit);wr.symbol(257,lit);wr.symbol(30,dist);packed_error('reserved_distance',wr.bytes(),0x28)
 return rows
BODY=r'''
 task acknowledge;begin done_ready=1;while(!ce)tick;@(posedge clk);tick;done_ready=0;end endtask
 task run;input integer offset,count,expected_error;reg ok;begin
 got=0;check_output=expected_error==0;start_valid=1;while(!start_ready)tick;@(posedge clk);tick;start_valid=0;
 for(i=0;i<count;i=i+1)begin s_data=source[offset+i];s_last=i==count-1;s_valid=1;ok=0;
 while(!ok)begin @(posedge clk);ok=ce&&s_ready||done_valid;end tick;
 if(done_valid)i=count;end s_valid=0;s_last=0;
 while(!done_valid)tick;
 if(frame_error!==(expected_error!=0)||error_code!=expected_error||(!expected_error&&got!=4))$fatal(1,"outcome err%h expected%h got%d",error_code,expected_error,got);
 repeat(4)tick;if(!done_valid)$fatal(1,"DONE hold");acknowledge;
 end endtask
 initial begin $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;
 CALLS
 $display("PASS PNG error recovery");$finish;end
endmodule'''
def main():
 a=np.array([1,8,22,255],dtype=np.uint8).reshape(2,2,1);good,expected,_=encode(a,'stored');bad=cases(good);source=[];calls=[]
 for name,data,code in bad:
  calls.append(f'run({len(source)},{len(data)},{code});');source.extend(data)
  calls.append(f'run({len(source)},{len(good)},0);');source.extend(good)
 tb=TB.split(' initial begin')[0]+BODY.replace('CALLS','\n'.join(calls))
 tb=tb.replace('integer cycles=0,got=0,i;','reg check_output=0;integer cycles=0,got=0,i;')
 tb=tb.replace('if(got>=NP||m_rgb!==expectation[got])','if(check_output&&(got>=NP||m_rgb!==expectation[got]))')
 tb=tb.replace('if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))','if(check_output&&(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1)))')
 for token,value in [('MW',16),('MH',12),('MC',4096),('WW',2),('HH',2),('NB',len(source)),('NP',4)]:tb=re.sub(r'\b'+token+r'\b',str(value),tb)
 with tempfile.TemporaryDirectory(prefix='png_error_') as td:
  d=Path(td)
  for token,values in [('SRC',source),('EXP',[(int(r)<<16)|(int(g)<<8)|int(b) for r,g,b in expected.reshape(-1,3)])]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/'errors_compile.log');text=execute(['vvp',str(d/'a.vvp')],ROOT,H/'errors_simulation.log',timeout=180);assert 'PASS PNG error recovery' in text;print(text)
 (H/'error_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'malformed':[{'name':n,'error':c} for n,d,c in bad],'healthy_recovery_frames':len(bad),'healthy_pixels':4*len(bad)},indent=2)+'\n')
if __name__=='__main__':main()
