from pathlib import Path
import sys,tempfile,json,io
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]));sys.path.insert(0,str(HERE.parent/'jpeg_huffman'))
from integration.tooling import execute
from tables import TABLES,canonical
from PIL import Image
Z=[0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63]
cases=[(1,1,0),(8,8,1),(13,9,2),(65535,65535,65535)]
with tempfile.TemporaryDirectory(prefix='jpeg_headers_') as td:
 p=Path(td)
 tb='''module tb;
 reg clk=0;always #5 clk=~clk;reg rst=0,ce=1,tv=0,cv=0,valid=0,mr=1;
 reg [5:0] ti;reg [7:0] tq;reg [15:0] w,h,dri;reg [1:0] op;reg [2:0] ri;
 wire tr,cr,cd,er,ready,mv,ml,done,error,busy;wire [7:0] md;
 jpeg_gray_headers dut(clk,rst,ce,tv,tr,ti,tq,cv,cr,w,h,dri,cd,er,valid,ready,op,ri,md,mv,ml,mr,done,error,busy);
 integer f,i,j,cycles=0;reg stalled=0;reg [8:0] held;reg [31:0] rng=171;
 always @(posedge clk) begin
 cycles=cycles+1;if(cycles>20000) $fatal(1,"timeout");
 if(rst) begin
 if(stalled&&(!mv||{md,ml}!==held)) $fatal(1,"stability");stalled=mv&&(!ce||!mr);held={md,ml};
 if(ce&&mv&&mr) $fdisplay(f,"%02x %01x",md,ml);
 end else stalled=0;
 end
 task tick;begin @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);ce=rng[0]|rng[1];mr=rng[2]|rng[3];end endtask
 task commit;input bad;begin ce=1;cv=1;@(negedge clk);cv=0;
 while(!cd&&!er) @(negedge clk);if(bad?(!er||cd):(!cd||er)) $fatal(1,"cfg");@(negedge clk);end endtask
 task command;input [1:0] command_op;input [2:0] restart_index;begin
 ce=1;valid=1;op=command_op;ri=restart_index;@(negedge clk);valid=0;
 while(!done) tick;
 ce=1;mr=1;@(negedge clk);if(busy||error) $fatal(1,"command terminal");end endtask
 initial begin
 f=$fopen("bytes.txt","w");repeat(3) @(negedge clk);rst=1;
 // Unconfigured commands and incomplete-table commits are explicit failures.
 valid=1;op=0;@(negedge clk);valid=0;if(!error||mv) $fatal(1,"unconfigured command");
 w=1;h=1;dri=0;commit(1);
 for(i=0;i<64;i=i+1) begin tv=1;ti=i;tq=i==17?255:i+1;@(negedge clk);end tv=0;
 w=0;commit(1);w=1;h=0;commit(1);h=1;
 for(j=0;j<4;j=j+1) begin
 case(j) 0:begin w=1;h=1;dri=0;end 1:begin w=8;h=8;dri=1;end 2:begin w=13;h=9;dri=2;end 3:begin w=65535;h=65535;dri=65535;end endcase
 commit(0);
 // Rejected staging table cannot alter dimensions, DRI or active quantizers.
 tv=1;ti=17;tq=0;@(negedge clk);tv=0;w=w-1;commit(1);w=w+1;
 tv=1;ti=17;tq=255;@(negedge clk);tv=0;
 command(0,0);for(i=0;i<8;i=i+1) command(2,i);command(1,0);
 end
 valid=1;op=3;@(negedge clk);valid=0;if(!error||mv) $fatal(1,"illegal command");
 valid=1;op=0;@(negedge clk);valid=0;mr=0;repeat(4) @(negedge clk);ce=0;rst=0;@(negedge clk);if(mv||busy) $fatal(1,"reset");
 $fclose(f);$display("PASS JPEG headers protocol");$finish;
 end endmodule'''
 (p/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',p/'sim',HERE/'jpeg_gray_headers.sv',p/'tb.sv'],p,p/'compile.log')
 text=execute(['vvp',p/'sim'],p,p/'run.log');assert 'PASS JPEG' in text;print(text.strip())
 commands=[];current=[]
 for line in (p/'bytes.txt').read_text().splitlines():
  data,last=(int(x,16) for x in line.split());current.append(data)
  if last:commands.append(bytes(current));current=[]
 assert len(commands)==40
 results=[]
 for ci,(w,h,dri) in enumerate(cases):
  header=commands[ci*10];rst=commands[ci*10+1:ci*10+9];eoi=commands[ci*10+9]
  assert rst==[bytes([255,208+i]) for i in range(8)] and eoi==b'\xff\xd9'
  assert header[:2]==b'\xff\xd8';i=2;segments={}
  while i<len(header):
   assert header[i]==255;marker=header[i+1];length=int.from_bytes(header[i+2:i+4],'big');assert length>=2
   payload=header[i+4:i+2+length];assert len(payload)==length-2;segments[marker]=payload;i+=2+length
  assert i==len(header) and list(segments)==([219,192,196,221,218] if dri else [219,192,196,218])
  assert segments[219]==bytes([0]+[255 if n==17 else n+1 for n in Z])
  assert segments[192]==bytes([8,h>>8,h&255,w>>8,w&255,1,1,17,0])
  expected_dht=b''
  for tid,name in ((0,'dc_luminance'),(16,'ac_luminance')):
   t=TABLES[name];expected_dht+=bytes([tid]+t['counts']+t['values'])
  assert segments[196]==expected_dht and segments[218]==bytes([1,1,0,0,63,0])
  if dri:assert segments[221]==dri.to_bytes(2,'big')
  decoded=False
  if w<100:
   # Independently construct a legal all-zero-coefficient entropy scan.
   dc=canonical(**TABLES['dc_luminance'])[0];ac=canonical(**TABLES['ac_luminance'])[0]
   block=f'{dc[0]:0{dc[1]}b}'+f'{ac[0]:0{ac[1]}b}'
   total=((w+7)//8)*((h+7)//8);bits='';entropy=bytearray();ri=0
   for block_index in range(total):
    bits+=block
    if block_index==total-1 or (dri and (block_index+1)%dri==0):
     bits+='1'*((-len(bits))%8)
     for bi in range(0,len(bits),8):
      v=int(bits[bi:bi+8],2);entropy.append(v)
      if v==255:entropy.append(0)
     bits=''
     if block_index!=total-1:entropy.extend(rst[ri%8]);ri+=1
   image=Image.open(io.BytesIO(header+entropy+eoi));image.load();assert image.mode=='L' and image.size==(w,h) and set(image.tobytes())=={128};decoded=True
  results.append({'width':w,'height':h,'dri':dri,'header_bytes':len(header),'parser':'PASS','independent_decoder':decoded})
 (HERE/'evidence.json').write_text(json.dumps({'result':'PASS','cases':results,'restart_markers':8,'invalid_config_and_commands':'PASS'},indent=2)+'\n')
