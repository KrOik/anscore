from test_transactions import *
HOST=r'''
 force_off=1;ce=0;start_valid=1;repeat(30)@(negedge clk);#1;if(!start_ready||busy||starts!=0)$fatal(1,"CE0 idle accepted");
 force_off=0;@(posedge clk);while(!(ce&&start_ready))@(posedge clk);
 @(negedge clk);#1;start_valid=0;
 wait(starts==1);force_off=1;ce=0;
 wait(result_valid);@(negedge clk);#1;
 if(year!=2026||month!=10||day!=19||hour!=23||minute!=59||second!=58)$fatal(1,"physical CE0 progress");
 result_ready=1;repeat(100)@(negedge clk);#1;if(!result_valid||done_valid)$fatal(1,"CE0 consumed RTC result");
 force_off=0;@(posedge clk);while(!ce)@(posedge clk);
 @(negedge clk);#1;result_ready=0;completion(0);
 if(starts!=6||stops!=3)$fatal(1,"duplicate RTC command");
'''
def main():
 frozen=hashes();dep=dependency();rows=[]
 rows.append(run('ce0_physical_progress',host=HOST))
 rows.append(run('minimum_divider',half=4,stretch_timeout=4,retry_limit=0))
 rows.append(run('max_retries_stable',retry_limit=255,status=0x04))
 rows.append(run('reset_held_result',host='request;wait(result_valid);@(negedge clk);#1;ce=0;force_off=1;rst_n=0;repeat(6)@(negedge clk);#1;if(!start_ready||busy||result_valid||done_valid||year||status_raw||scl_drive_low||sda_drive_low)$fatal(1,"reset held CE0");'))
 assert hashes()==frozen and dependency()==dep
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
