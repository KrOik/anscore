"""Directed physical error and host/reset boundary tests."""
from test_transactions import *

def main():
 frozen=hashes();rows=[]
 rows.append(run('nack_device',nack_dev=True,host='request(0,3,2);completion(1,0);'))
 send='request(1,3,1);@(negedge clk);#1;tx_valid=1;tx_data=8\'h69;@(posedge clk);while(!(ce&&tx_ready))@(posedge clk);@(negedge clk);#1;tx_valid=0;'
 rows.append(run('nack_data',nack_data=True,host=send+'completion(2,0);'))
 rows.append(run('poll_timeout',busy_polls=100,host=send+'completion(6,1);if(poll_nacks!=5)$fatal(1,"poll budget");'))
 rows.append(run('host_timeout',host='request(1,0,1);completion(7,0);'))
 rows.append(run('bus_busy_timeout',host='fault_sda=1;request(0,0,1);completion(5,0);'))
 rows.append(run('stretch_timeout',host='fork begin request(0,0,1);end begin wait(starts==1);@(posedge scl_drive_low);fault_scl=1;end join completion(3,0);'))
 rows.append(run('arbitration_lost',host='fork begin request(0,0,1);end begin wait(starts==1);@(negedge scl_in);#20;fault_sda=1;end join completion(4,0);'))
 rows.append(run('length_zero',host='request(0,0,0);completion(8,0);if(starts!=0)$fatal(1,"invalid length drove bus");'))
 rows.append(run('capacity_overrun',host='request(1,32767,2);completion(8,0);if(starts!=0)$fatal(1,"invalid range drove bus");'))
 rows.append(run('reset_ce0',host='fork begin request(0,0,8);end begin wait(starts==1);@(posedge scl_drive_low);force_off=1;ce=0;rst_n=0;end join repeat(5)@(negedge clk);#1;if(!start_ready||busy||done_valid||rx_valid||scl_drive_low||sda_drive_low||bytes_completed)$fatal(1,"reset CE0 cancellation");rst_n=1;start_valid=1;repeat(5)@(negedge clk);#1;if(!start_ready||busy)$fatal(1,"CE0 accepted command");'))
 rows.append(run('nack_word_address',nack_addr=True,host='request(0,3,2);completion(2,0);'))
 rows.append(run('nack_read_control',nack_read=True,host='request(0,3,2);completion(1,0);'))
 rows.append(run('stop_bus_stuck',nack_dev=True,host='fork begin request(0,3,2);end begin wait(stops==1);fault_sda=1;end join completion(5,0);'))
 assert hashes()==frozen
 (HERE/'error_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
