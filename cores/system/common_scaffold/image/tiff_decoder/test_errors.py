from run_tests import *
def mutate(data,tag,value=None,typ=None,count=None,newtag=None):
 b=bytearray(data);big=data[:2]==b'MM';e='>' if big else '<';ifd=struct.unpack_from(e+'I',b,4)[0];n=struct.unpack_from(e+'H',b,ifd)[0]
 for i in range(n):
  at=ifd+2+12*i;t,ty,c=struct.unpack_from(e+'HHI',b,at)
  if t==tag:
   if newtag is not None:struct.pack_into(e+'H',b,at,newtag)
   if typ is not None:struct.pack_into(e+'H',b,at+2,typ)
   if count is not None:struct.pack_into(e+'I',b,at+4,count)
   if value is not None:struct.pack_into(e+('H' if ty==3 and c==1 else 'I'),b,at+8,value)
   return bytes(b)
 raise AssertionError(tag)
def cases():
 d,p=fixture(rps=5,short=False)
 rows=[('signature',b'ZZ'+d[2:],1),('bigtiff',d[:2]+b'\x2b\0'+d[4:],1),('short_header',d[:5],4),('short_ifd',d[:25],4),('last_pixel_missing',d[:170],4),('width_zero',mutate(d,256,0),2),('width_over',mutate(d,256,257),2),('height_zero',mutate(d,257,0),2),('compressed',mutate(d,259,5),6),('orientation',mutate(d,274,2),6),('planar',mutate(d,284,2),6),('photo',mutate(d,262,3),6),('bits1',mutate(d,258,1),6),('samples',mutate(d,277,4),6),('rps0',mutate(d,278,0),6),('offset_oob',mutate(d,273,0xfffffff0),4),('bytes_short',mutate(d,279,1),4),('duplicate',mutate(d,274,newtag=256),5),('tag_type',mutate(d,256,typ=2),5),('tag_count',mutate(d,256,count=2),5),('missing_width',mutate(d,256,newtag=65000),5),('predictor',mutate(d,274,2,newtag=317),6),('fillorder',mutate(d,274,2,newtag=266),6),('tile',mutate(d,274,newtag=322),6),('extrasamples',mutate(d,274,newtag=338),6)]
 b=bytearray(d);struct.pack_into('<I',b,16+2+11*12,16);rows.append(('multi_ifd',bytes(b),6))
 b=bytearray(d);struct.pack_into('<H',b,16,65535);rows.append(('entries_overflow',bytes(b),4))
 dr,_=fixture(mode=2,rps=2);b=bytearray(dr);e='<';at=next(18+i*12 for i in range(11) if struct.unpack_from('<H',b,18+i*12)[0]==258);ptr=struct.unpack_from('<I',b,at+8)[0];struct.pack_into('<H',b,ptr+2,16);rows.append(('mixed_bits',bytes(b),6))
 return rows
TBE=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;reg[7:0]s_data=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire[1:0]image_mode;wire[23:0]m_pixel;
tiff_decoder dut(.*);reg[7:0]source[0:NB-1];reg[31:0]starts[0:NF-1],sizes[0:NF-1],errors[0:NF-1];reg[23:0]expected[0:34];integer j,i,got,cycles=0;reg healthy=0;
always @(posedge clk)begin cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout");if(rst_n&&ce&&healthy&&m_valid&&m_ready)begin if(m_pixel!==expected[got])$fatal(1,"recovery pixel");got=got+1;end end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin $readmemh("SRC",source);$readmemh("STARTS",starts);$readmemh("SIZES",sizes);$readmemh("ERRORS",errors);$readmemh("EXP",expected);repeat(3)tick;rst_n=1;tick;
 for(j=0;j<NF;j=j+1)begin got=0;healthy=errors[j]==0;start_valid=1;tick;start_valid=0;
 for(i=0;i<sizes[j]&&!done_valid;i=i+1)begin s_data=source[starts[j]+i];s_valid=1;s_last=i==sizes[j]-1;@(posedge clk);tick;end s_valid=0;s_last=0;
 while(!done_valid)tick;if(error_code!=errors[j]||frame_error!=(errors[j]!=0)||(healthy&&got!=35))$fatal(1,"file %d error %h expected %h got %d",j,error_code,errors[j],got);
 repeat(3)tick;done_ready=1;tick;done_ready=0;tick;
 end $display("PASS TIFF ERRORS files=%d",NF);$finish;end
endmodule"""
def main():
 good,pix=fixture(rps=5);fs=[];starts=[];sizes=[];errors=[];rows=cases()
 for name,data,err in rows:
  for chunk,code in [(data,err),(good,0)]:starts.append(len(fs));sizes.append(len(chunk));errors.append(code);fs.extend(chunk)
 tb=TBE.replace('NB',str(len(fs))).replace('NF',str(len(starts)))
 with tempfile.TemporaryDirectory(prefix='tiff_errors_') as td:
  d=Path(td)
  for token,values in [('SRC',fs),('STARTS',starts),('SIZES',sizes),('ERRORS',errors),('EXP',pix)]:
   f=d/(token+'.hex');f.write_text('\n'.join(f'{v:x}' for v in values));tb=tb.replace('"'+token+'"','"'+f.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'errors_compile.log');out=execute(['vvp',d/'a.vvp'],ROOT,H/'errors_simulation.log');assert 'PASS TIFF ERRORS' in out
 report=dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),malformed_files=len(rows),recovery_frames=len(rows),recovery_pixels=len(rows)*35,cases=[dict(name=n,error=e) for n,d,e in rows]);(H/'errors_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(out)
if __name__=='__main__':main()
