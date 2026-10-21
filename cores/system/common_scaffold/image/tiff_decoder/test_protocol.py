from run_tests import *
TBP=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=0,done_ready=0;reg[7:0]s_data;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire[1:0]image_mode;wire[23:0]m_pixel;
tiff_decoder dut(.*);reg[7:0]source[0:NB-1];reg[23:0]expected[0:NP-1];integer got=0,cycles=0,ti,j,k,ap,pass=0;reg hit,check_pixels=0;reg[26:0]held;reg stalled=0;
always @(posedge clk)begin cycles=cycles+1;if(cycles>3000000)$fatal(1,"timeout");
 if(rst_n&&ce&&check_pixels&&m_valid&&m_ready)begin
  if(m_pixel!==expected[got]||m_sof!==(got==0)||m_eol!==(got%7==6)||m_last!==(got==NP-1))$fatal(1,"pixel");got=got+1;
 end
end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;begin rst_n=0;ce=0;tick;tick;if(dut.state!=0||m_valid||done_valid)$fatal(1,"reset at CE0");rst_n=1;ce=1;tick;end endtask
 task run;input integer target,action;integer pos;begin
  got=0;check_pixels=target==0;pos=0;hit=0;m_ready=target==0;start_valid=1;tick;start_valid=0;
  while(!done_valid&&!hit)begin
   if(target!=0&&dut.state==target)begin
    hit=1;
    if(action==0)begin abort=1;tick;abort=0;if(!done_valid||error_code!=9)$fatal(1,"abort %d",target);end
    else begin rst_n=0;ce=0;tick;tick;if(dut.state!=0||m_valid||done_valid)$fatal(1,"reset %d",target);rst_n=1;ce=1;end
   end else begin
    if(dut.state==1&&pos<NB)begin s_valid=1;s_data=source[pos];s_last=pos==NB-1;end else begin s_valid=0;s_last=0;end
    @(posedge clk);if(ce&&s_valid&&s_ready)pos=pos+1;tick;
   end
  end
  s_valid=0;s_last=0;
  if(target!=0&&!hit)$fatal(1,"state absent %d",target);
  if(target==0)begin if(frame_error||got!=NP)$fatal(1,"healthy %h %d",error_code,got);pass=pass+1;end
  if(done_valid)begin repeat(4)tick;done_ready=1;tick;done_ready=0;tick;end
  check_pixels=0;
 end endtask
 initial begin $readmemh("SRC",source);$readmemh("EXP",expected);reset;
 for(ap=0;ap<2;ap=ap+1)for(ti=1;ti<=26;ti=ti+1)if(ti!=22)begin run(ti,ap);run(0,0);end
 $display("PASS TIFF PROTOCOL recovery=%d active_abort=25 CE0reset=25",pass);$finish;end
endmodule"""
def main():
 data,pix=fixture(mode=2,rps=2);tb=TBP.replace('NB',str(len(data))).replace('NP',str(len(pix)))
 with tempfile.TemporaryDirectory(prefix='tiff_protocol_') as td:
  d=Path(td)
  for token,values in [('SRC',data),('EXP',pix)]:
   f=d/(token+'.hex');f.write_text('\n'.join(f'{v:x}' for v in values));tb=tb.replace('"'+token+'"','"'+f.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'protocol_compile.log');out=execute(['vvp',d/'a.vvp'],ROOT,H/'protocol_simulation.log');assert 'PASS TIFF PROTOCOL' in out
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),active_abort_states=25,ce_off_reset_states=25,recovery_frames=50,recovery_pixels=1750),indent=2)+'\n');print(out)
if __name__=='__main__':main()
