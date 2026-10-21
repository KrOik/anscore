from test_transactions import *
_run=run
def run(label,**kwargs):return _run("error_"+label,**kwargs)
def main():
 frozen=hashes();dep=dependency();rows=[]
 rows.append(run('rollover_exhausted',rollovers=-1,host='request;completion(6);if(retries!=2)$fatal(1,"retry budget");'))
 rows.append(run('retry_zero',rollovers=1,roll_values=(2026,10,19,1,23,59,59),retry_limit=0,host='request;completion(6);if(retries!=0)$fatal(1,"zero retry budget");'))
 rows.append(run('nack_control',nack=True,host='request;completion(1);'))
 rows.append(run('nack_set_data',set_op=True,data_nack=True,host='request;completion(1);'))
 rows.append(run('bus_busy',host='fault_sda=1;request;completion(5);'))
 rows.append(run('stretch_timeout',host='fork begin request;end begin wait(starts==1);@(posedge scl_drive_low);fault_scl=1;end join completion(3);'))
 rows.append(run('arbitration',host='fork begin request;end begin wait(starts==1);@(negedge scl_in);#20;fault_sda=1;end join completion(4);'))
 rows.append(run('reset_ce0',host='fork begin request;end begin wait(starts==1);@(posedge scl_drive_low);force_off=1;ce=0;rst_n=0;end join repeat(6)@(negedge clk);#1;if(!start_ready||busy||done_valid||result_valid||scl_drive_low||sda_drive_low)$fatal(1,"CE0 reset");rst_n=1;start_valid=1;repeat(6)@(negedge clk);#1;if(!start_ready||busy)$fatal(1,"CE0 accepted start");'))
 valid=[0x30,0x45,0x16,4,0x29,0x02,0x24]
 for index,value,label in [(0,0x6a,'bcd_digit'),(0,0x80,'seconds_reserved'),(1,0x60,'minute_range'),(2,0x40,'12h_zero'),(2,0x53,'12h_13'),(2,0x24,'24h_24'),(3,0,'weekday_zero'),(3,0x81,'weekday_reserved'),(4,0x30,'feb30'),(5,0x22,'month_reserved'),(6,0xfa,'year_digit')]:
  raw=valid.copy();raw[index]=value;rows.append(run(label,raw=raw,host='request;completion(2);'))
 rows.append(run('gregorian_2100_nonleap',raw=[0,0,0,1,0x29,0x82,0],host='request;completion(2);'))
 for vals,label in [((1999,1,1,1,0,0,0),'set_year_low'),((2200,1,1,1,0,0,0),'set_year_high'),((2100,2,29,1,0,0,0),'set_nonleap'),((2025,4,31,1,0,0,0),'set_april31'),((2024,0,1,1,0,0,0),'set_month0'),((2024,1,0,1,0,0,0),'set_day0'),((2024,1,1,0,0,0,0),'set_weekday0'),((2024,1,1,1,24,0,0),'set_hour24'),((2024,1,1,1,0,60,0),'set_minute60'),((2024,1,1,1,0,0,60),'set_second60')]:rows.append(run(label,values=vals,set_op=True,host='request;completion(8);if(starts!=0)$fatal(1,"invalid SET drove bus");'))
 assert hashes()==frozen and dependency()==dep
 (HERE/'error_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,dependency_sha256=dep,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
