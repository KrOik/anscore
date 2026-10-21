from test_transactions import *
READ=r'''
 request(0,@ADDRESS@,@LENGTH@);
 for(integer x=0;x<@LENGTH@;x=x+1)begin
  wait(rx_valid);@(negedge clk);#1;
  if(rx_data!==(((@ADDRESS@+x)*13+7)&255)||rx_last!=(x==@LENGTH@-1))$fatal(1,"random read data/LAST");
  repeat(40+x%7)@(negedge clk);
  force_off=1;ce=0;rx_ready=1;repeat(30)@(negedge clk);#1;if(!rx_valid)$fatal(1,"CE0 read held");
  force_off=0;@(posedge clk);while(!ce)@(posedge clk);
  @(negedge clk);#1;rx_ready=0;
 end
 completion(0,@LENGTH@);
 if(starts!=2||stops!=1||read_bytes!=@LENGTH@||write_bytes!=0)$fatal(1,"random read must use repeated START");
'''
def main():
 frozen=hashes();rows=[]
 for page,address,length in [(1,3,5),(8,7,18),(64,63,66),(256,255,2)]:rows.append(run('page_'+str(page),page=page,address=address,length=length,busy_polls=0))
 rows.append(run('random_read_16bit',address=4093,length=9,host=READ))
 rows.append(run('random_read_8bit',addr_bytes=1,capacity=256,page=8,address=248,length=8,host=READ))
 rows.append(run('max_page256',capacity=65536,page=256,address=250,length=263))
 rows.append(run('minimum_half4',address=63,length=3,half=4))
 assert hashes()==frozen
 (HERE/'boundary_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=rows),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
