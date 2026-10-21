from test_lcd8080 import *
BODY=r'''
integer i,j;
initial begin
 repeat(3)@(negedge clk);#1;rst_n=1;

 // Maximum counters: independent pin BFM verifies all four durations.
 cfg_setup=65535;cfg_pulse=65535;cfg_hold=65535;cfg_turnaround=65535;
 write_job(1,1,'h55);
 cfg_setup=1;cfg_pulse=1;cfg_hold=1;cfg_turnaround=1;
 launch(0,1,65535);@(negedge clk);#1;abort=1;
 begin:a forever begin @(posedge clk);if(ce)begin #1;disable a;end end end
 @(negedge clk);#1;abort=0;finish_job(3);
 cfg_pulse=40;expect_beat(0,1,'hb9);launch(0,1,1);send_word('hb9);wait(!lcd_wr_n);
 @(negedge clk);#1;rst_n=0;force_ce_off=1;
 @(posedge clk);#1;if(!lcd_cs_n||!lcd_rd_n||!lcd_wr_n||lcd_data_oe||busy||done_valid)$fatal(1,"reset active pulse");
 @(negedge clk);#1;exp_count=observed;rst_n=1;force_ce_off=0;
 cfg_pulse=1;write_job(1,1,'h28);
 // An abort asserted only under CE=0 is ignored; physical timing still completes.
 cfg_pulse=20;expect_beat(0,1,'h81);launch(0,1,1);send_word('h81);wait(!lcd_wr_n);
 @(negedge clk);#1;force_ce_off=1;ce=0;abort=1;
 wait(done_valid);@(negedge clk);#1;if(error_code!=0)$fatal(1,"CE-off abort accepted");
 abort=0;force_ce_off=0;finish_job(0);
 // Busy input configuration changes cannot change the captured bus waveform.
 cfg_setup=2;cfg_pulse=3;cfg_hold=4;cfg_turnaround=5;
 expect_beat(0,1,'h67);launch(0,1,1);
 cfg_setup=0;cfg_pulse=0;cfg_hold=0;cfg_turnaround=0;
 send_word('h67);finish_job(0);
 cfg_setup=1;cfg_pulse=1;cfg_hold=1;cfg_turnaround=1;
 // Reset may discard an exposed token and must release bus/host state immediately.
 expect_beat(1,1,'h75);launch(1,1,1);wait(rx_valid);repeat(2)@(negedge clk);
 @(negedge clk);#1;rst_n=0;force_ce_off=1;
 @(posedge clk);#1;if(rx_valid||busy||done_valid||!lcd_cs_n)$fatal(1,"reset exposed RX");
 @(negedge clk);#1;rst_n=1;force_ce_off=0;
 cfg_timeout=9;cfg_pulse=40;expect_beat(0,1,'h3a);launch(0,1,1);send_word('h3a);
 wait(!lcd_wr_n);repeat(14)@(negedge clk);#1;abort=1;
 begin:b forever begin @(posedge clk);if(ce)begin #1;disable b;end end end
 @(negedge clk);#1;abort=0;finish_job(2);cfg_timeout=0;
 if(observed!=exp_count)$fatal(1,"boundary scoreboard");
 $display("PASS LCD8080 BOUNDARIES width=%0d maxTiming65535 resetPulse abortWaitTX stickyTimeout jobs=%0d",W,jobs);$finish;

end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
if __name__=='__main__':
 frozen=hashes();rows=[]
 for w in (8,16):rows.append(run_tb('boundary'+str(w),(TB.split('integer i,j;')[0]+BODY).replace('@WIDTH@',str(w))))
 assert hashes()==frozen
 (HERE/'boundary_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n')
