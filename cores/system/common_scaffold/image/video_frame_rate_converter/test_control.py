from run_tests import *
def main():
 vectors=[]
 for c in range(120):
  ce=not 13<=c<23;ready=c>=30;tick=c==10;abort=15<=c<=20 or c==23
  valid=c<3;sof=c==0;eol=c==2;last=c==2;value=c*11 if valid else 0
  vectors.append((int(ce)<<15)|(int(ready)<<14)|(int(tick)<<13)|(int(abort)<<12)|(int(valid)<<11)|(int(sof)<<10)|(int(eol)<<9)|(int(last)<<8)|value)
 row=run('held_frame_abort',w=3,h=1,num=1,den=1,custom_rows=vectors)
 assert row['counters'][:2]==[1,1]
 header=TB[:TB.index('reg[31:0]vectors')]
 for k,v in dict(PW=8,W=2,H=2,NUM=1,DEN=1,MW=2,MH=2).items():header=header.replace('@'+k+'@',str(v))
 body=r'''integer j;
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin ce=1;start_valid=1;tick;start_valid=0;end endtask
 task pixel;input[7:0]v;input integer n;begin raw_pixel=v;s_valid=1;s_sof=n==0;s_eol=n%2==1;s_last=n==3;tick;s_valid=0;end endtask
 task resetnow;begin rst_n=0;ce=0;tick;if(m_valid||running||done_valid||published_count!=0||output_count!=0)$fatal(1,"reset active");rst_n=1;ce=1;tick;end endtask
 initial begin repeat(3)tick;rst_n=1;launch;
 pixel(8'ha0,0);pixel(8'ha1,1);resetnow; // partial frame discarded
 launch;for(j=0;j<4;j=j+1)pixel(8'ha0+j,j);
 cadence_tick=1;tick;cadence_tick=0;while(!m_valid)tick;
 if(m_pixel!=8'ha0||!m_sof)$fatal(1,"initial frame");resetnow; // held exposed output discarded only by reset
 launch;cadence_tick=1;tick;cadence_tick=0;repeat(4)tick;
 if(m_valid||underrun_count!=1)$fatal(1,"old frame survived reset");
 for(j=0;j<4;j=j+1)pixel(8'hb0+j,j);
 cadence_tick=1;tick;cadence_tick=0;m_ready=0;
 for(j=0;j<4;j=j+1)begin while(!m_valid)tick;
 if(m_pixel!=8'hb0+j||m_sof!==(j==0)||m_eol!==(j%2==1)||m_last!==(j==3)||m_frame_id!=0)$fatal(1,"healthy after reset");
 repeat(3)tick;m_ready=1;tick;m_ready=0;end
 abort=1;tick;abort=0;while(!done_valid)tick;if(error_code!=9||output_count!=1)$fatal(1,"idle abort");
 done_ready=1;tick;done_ready=0;launch;
 raw_pixel=1;s_valid=1;s_sof=0;s_eol=0;s_last=0;tick;s_valid=0;while(!done_valid)tick;
 if(error_code!=2||m_valid)$fatal(1,"marker error recovery");
 $display("PASS FRC RESET partial held restart underrun healthy idleabort markererror");$finish;end
 initial begin #100000;$fatal(1,"watchdog");end
 endmodule'''
 with tempfile.TemporaryDirectory(prefix='video_frc_reset_') as td:
  p=Path(td);(p/'tb.sv').write_text(header+body);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',RTL,p/'tb.sv'],H,H/'reset_compile.log');out=execute(['vvp',p/'sim'],H,H/'reset_simulation.log');assert 'PASS FRC RESET' in out
 resetrow=dict(name='reset_partial_held_recovery',status='PASS',output=out)
 (H/'control_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='CEoff ignores abort; CEon abort while output held must drain full exact frame before DONE, no output token withdrawal',profiles=[row,resetrow]),indent=2)+'\n')
if __name__=='__main__':main()
