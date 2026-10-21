from run_tests import *
def main():
 rows=[]
 rows.append(run('crc_bad',[rom(0x123428)^0x100000000000000],error=4,outputs=0))
 rows.append(run('stuck_low',[],error=2,outputs=0,pre='stuck=1;repeat(5)tick;'))
 rows.append(run('invalid_pair',[rom(0x123428)],error=3,outputs=0,action='while(cmd_count!=8)tick;ndev=0;'))
 rows.append(run('timeout',[rom(0x123428)],error=6,outputs=0,timeout=1000))
 for phase in ['RESET_BUS','COMMAND','READ_ID','READ_COMP','CHOOSE','WRITE_DIR']:
  st={'RESET_BUS':1,'COMMAND':2,'READ_ID':3,'READ_COMP':4,'CHOOSE':5,'WRITE_DIR':6}[phase]
  rows.append(run('abort_'+phase,[rom(0x123428)],error=7,outputs=0,action=f'while(dut.state!={st})tick;ce=0;abort=1;repeat(2)tick;if(done_valid)$fatal(1,"CEoff abort");ce=1;tick;abort=0;'))
 rows.append(run('held_abort',[rom(0x123428)],error=7,outputs=1,action='rom_ready=0;while(!rom_valid)tick;ce=0;abort=1;repeat(7)tick;if(!rom_valid||done_valid)$fatal(1,"CEoff held abort");ce=1;tick;abort=0;repeat(5)tick;if(!rom_valid||done_valid)$fatal(1,"abort withdrew ROM");rom_ready=1;'))
 rows.append(run('held_timeout',[rom(0x123428)],error=6,outputs=1,timeout=16000,action='rom_ready=0;while(!rom_valid)tick;repeat(2000)tick;if(!rom_valid||done_valid)$fatal(1,"timeout withdrew ROM");rom_ready=1;'))
 rows.append(run('mid_stuck',[rom(0x123428)],error=2,outputs=0,action='while(cmd_count!=8)tick;stuck=1;'))
 rows.append(run('disappeared',[0,rom(1)],error=8,outputs=1,check=0,action='while(!rom_valid)tick;ndev=0;'))
 for st in (1,2,3,4,5,6,7):
  act=f'rom_ready=0;while(dut.state!={st})tick;rst_n=0;tick;if(ow_drive_low||rom_valid||busy||done_valid)$fatal(1,"reset release");rst_n=1;repeat(5)tick;rom_ready=1;start_valid=1;tick;start_valid=0;'
  rows.append(run('reset_'+str(st),[rom(0x123428)],action=act))
 for delay in (13,13.9):rows.append(run('late_response_'+str(delay),[rom(0x123428)],delay=delay))
 rows.append(run('after_sample_response_15',[rom(0x123428)],delay=15,error=3,outputs=0))
 rows.append(run('ce_off',[rom(0x123428)],action='ce=0;rom_ready=0;while(!rom_valid)tick;repeat(17)tick;ce=1;rom_ready=1;'))
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()

