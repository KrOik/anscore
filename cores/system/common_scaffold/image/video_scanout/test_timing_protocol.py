from test_timing import *
def main():
 frozen=hashes();tb=TB
 for k,v in dict(HA=4,HF=2,HS=1,HB=1,VA=2,VF=1,VS=1,VB=1,HP=0,VP=1).items():tb=tb.replace('@'+k+'@',str(v))
 tb=tb[:tb.index('integer cyc')]+r'''
integer n=0,j;always @(posedge clk)if(running&&pixel_tick)n=n+1;
task tick;begin @(negedge clk);#1;end endtask
task launch;begin n=0;ce=1;start_valid=1;tick;start_valid=0;end endtask
task ack;input[7:0]err;begin wait(done_valid);tick;if(error_code!==err||frame_error!==(err!=0)||running)$fatal(1,"report");ce=1;done_ready=1;tick;done_ready=0;end endtask
initial begin repeat(3)tick;rst_n=1;
launch;ce=0;stop=1;repeat(10)tick;if(done_valid||!running)$fatal(1,"CEoff stop accepted");stop=0;ce=1;
while(n<39)tick;stop=1;tick;stop=0;ack(0);if(n!=40)$fatal(1,"boundary stop");
launch;tick;abort=1;tick;abort=0;ce=0;ack(3);if(n!=40)$fatal(1,"abort shortened timing");
launch;tick;ce=0;rst_n=0;tick;if(running||done_valid||de||h_count||v_count)$fatal(1,"reset");rst_n=1;ce=1;
for(j=0;j<4;j=j+1)begin cfg_h_active=j==0?0:4;cfg_v_active=2;cfg_h_sync=j==1?0:1;cfg_h_front=j==2?65535:2;cfg_v_sync=j==3?0:1;launch;ack(1);end
$display("PASS TIMING_PROTOCOL stop/abort40ticks,CEoffignore,reset,4errors");$finish;end
initial begin #100000;$fatal(1,"timeout");end endmodule'''
 with tempfile.TemporaryDirectory(prefix='timing_protocol_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out)
 assert hashes()==frozen
 (HERE/'timing_protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,output=out),indent=2)+'\n')
if __name__=='__main__':main()
