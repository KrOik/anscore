from test_transactions import *
HOST=r'''
 force_off=1;ce=0;start_valid=1;write=0;word_address=0;length=1;
 repeat(40)@(negedge clk);#1;
 if(!start_ready||busy||starts!=0)$fatal(1,"IDLE ready does not imply CE0 acceptance");
 force_off=0;@(posedge clk);while(!(ce&&start_ready))@(posedge clk);
 @(negedge clk);#1;start_valid=0;word_address=65535;length=0;write=1;device_address=0;
 wait(rx_valid);@(negedge clk);#1;if(rx_data!=7||!rx_last||bytes_completed!=0)$fatal(1,"snapshot or read data");
 force_off=1;ce=0;rx_ready=1;repeat(1000)@(negedge clk);#1;
 if(!rx_valid||rx_data!=7||!rx_last||done_valid||bytes_completed!=0)$fatal(1,"CE0 must preserve output even beyond host TX timeout");
 force_off=0;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;rx_ready=0;
 completion(0,1);
 if(starts!=2||stops!=1||read_bytes!=1)$fatal(1,"duplicate accepted command or early NACK");
'''
def main():
 frozen=hashes();rows=[run('ce0_idle_and_rx',host=HOST)]
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
