from test_measurement import *
BODY=r'''
task launch;
begin
 @(negedge clk);#1;ce=1;start_valid=1;
 @(posedge clk);#1;@(negedge clk);#1;start_valid=0;
end endtask
task pin_for(input bit v,input integer n);
begin input_pin=v;repeat(n)@(negedge clk);#1;end endtask
task acknowledge(input integer err);
begin
 wait(done_valid);@(negedge clk);#1;if(error_code!=err||busy)$fatal(1,"terminal err");
 ce=0;done_ready=1;repeat(4)@(negedge clk);#1;if(!done_valid)$fatal(1,"CE0 ack");
 ce=1;@(posedge clk);#1;@(negedge clk);#1;done_ready=0;
 if(!start_ready)$fatal(1,"restart ready");
end endtask
reg[3*W+3:0]snapshot;
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;launch;
 pin_for(0,10);pin_for(1,8);pin_for(0,12);pin_for(1,9);pin_for(0,11);pin_for(1,10);
 if(!m_valid)$fatal(1,"expected completed cycle");
 snapshot={m_is_cycle,m_flags,m_high,m_low,m_period};
 // Abort while CE0 is ignored. Then a real abort must wait for both queued tokens.
 ce=0;abort=1;repeat(4)@(negedge clk);#1;if(done_valid||!busy)$fatal(1,"CE0 abort");
 ce=1;@(posedge clk);#1;@(negedge clk);#1;abort=0;ce=0;m_ready=1;
 repeat(8)@(negedge clk);#1;
 if(done_valid||!busy||!m_valid||snapshot!=={m_is_cycle,m_flags,m_high,m_low,m_period})$fatal(1,"drain revoked held token");
 ce=1;wait(done_valid);@(negedge clk);#1;if(events!=2)$fatal(1,"queue did not drain two");
 acknowledge(3);m_ready=0;
 // Runtime limits fail without starting measurement or emitting results.
 cfg_min_high=0;launch;acknowledge(1);cfg_min_high=1;
 cfg_max_high=0;launch;acknowledge(1);cfg_max_high={W{1'b1}};
 cfg_min_low=0;launch;acknowledge(1);cfg_min_low=1;
 cfg_max_low=0;launch;acknowledge(1);cfg_max_low={W{1'b1}};
 // Reset cancels an exposed token and running physical acquisition under CE0.
 launch;pin_for(0,10);pin_for(1,8);pin_for(0,12);pin_for(1,10);wait(m_valid);
 @(negedge clk);#1;ce=0;rst_n=0;@(posedge clk);#1;
 if(m_valid||busy||done_valid||drop_count||!start_ready)$fatal(1,"reset CE0");
 @(negedge clk);#1;rst_n=1;ce=1;cfg_timeout=20;input_pin=0;launch;
 wait(m_valid);if(m_flags!=1||m_is_cycle||m_high||m_low||m_period)$fatal(1,"timeout event");
 repeat(40)@(negedge clk);#1;if(drop_count)$fatal(1,"repeated timeout events");
 abort=1;@(posedge clk);#1;@(negedge clk);#1;abort=0;m_ready=1;
 acknowledge(3);
 $display("PASS PULSE PROTOCOL abortDrain/CEoff/reset/config/timeout heldStable checks=10");$finish;
end
initial begin #100000;$fatal(1,"watchdog");end
endmodule
'''
def run_protocol(label,body=BODY,width=32,filter_width=8):
 tb=TB.split('initial begin\n $readmemh')[0]+body
 for k,v in dict(W=width,N=1,POL=1,FILTER=0,TIMEOUT=0,MINH=1,MAXH=(1<<width)-1,MINL=1,MAXL=(1<<width)-1).items():tb=tb.replace('@'+k+'@',str(v))
 tb=tb.replace('#(.COUNTER_W(W))',f'#(.COUNTER_W(W),.FILTER_W({filter_width}))')
 with tempfile.TemporaryDirectory(prefix='pulse_protocol_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',SOURCE,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log')
  (HERE/f'simulation_{label}.log').write_text(out);assert 'PASS PULSE' in out;print(out,flush=True);return dict(label=label,width=width,filter_width=filter_width,output=out)
if __name__=='__main__':
 frozen=hashes();row=run_protocol('protocol');assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,case=row),indent=2)+'\n')
