"""SRAM/JTAG input loading and source-bound full raw UART model acceptance."""
import argparse
import hashlib
import json
import shlex
import sys
import paramiko
from common import ROOT,REPO,evidence
from remote_board import password,execute
sys.path.insert(0,str(ROOT/'models'))
from auto_check import packets,check

CAPTURE='''import serial,time,sys
s=serial.Serial('/dev/ttyUSB1',115200,timeout=.1)
s.reset_input_buffer()
b=bytearray(); deadline=time.monotonic()+25
while time.monotonic()<deadline:
    b.extend(s.read(4096))
    if len(b)>=31 and b[-31:-28]==bytes.fromhex('55aa86'): break
s.close()
open(sys.argv[1],'wb').write(b)
print('UART_RAW_BYTES',len(b))
assert len(b)>=31 and b[-31:-28]==bytes.fromhex('55aa86'),'missing terminal record'
'''

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--build',type=__import__('pathlib').Path,required=True)
    ap.add_argument('--profiles',default='0,1,2,3,4,5,6,7,8'); ap.add_argument('--jtag-freq',type=int,default=1000000); a=ap.parse_args()
    build=a.build.resolve(); rb=json.loads((build/'summary.json').read_text());assert rb['transport']=='JTAG-loaded-raw-UART'
    rows={r['profile']:r for r in rb['profiles']}; ps=list(map(int,a.profiles.split(',')))
    for p in ps:
        r=rows[p];assert r['route']=='PASS' and r['under_budget']
        for f,h in r['input_sha256'].items():assert hashlib.sha256((REPO/f).read_bytes()).hexdigest()==h,('stale source',f)
        assert hashlib.sha256((ROOT/r['bitstream']).read_bytes()).hexdigest()==r['bitstream_sha256']
    out=evidence('board_auto');report={'status':'IN_PROGRESS','build':str(build),'transport':'JTAG input load; UART raw capture',
              'clock_mhz':50,'clock_enable':1,'host':'192.168.31.176','device':'GW5A-25','jtag_freq_hz':a.jtag_freq,'profiles':[]}
    c=paramiko.SSHClient();c.set_missing_host_key_policy(paramiko.AutoAddPolicy());c.connect('192.168.31.176',username='bianbu',password=password(),allow_agent=False,look_for_keys=False,timeout=15)
    sftp=c.open_sftp();remote='/home/bianbu/'+out.name
    try:
        code,det=execute(c,['openFPGALoader','-b','tangprimer25k','--detect'])
        (out/'jtag.txt').write_text(det,encoding='utf-8');assert code==0 and '0x1281b' in det and 'GW5A-25' in det
        sftp.mkdir(remote)
        with sftp.file(remote+'/capture.py','w') as s:s.write(CAPTURE)
        for p in ps:
            r=rows[p];fs=ROOT/r['bitstream'];rf=remote+f'/profile_{p}.fs';sftp.put(str(fs),rf)
            code,sha=execute(c,['sha256sum',rf]);assert code==0 and sha.startswith(r['bitstream_sha256'])
            cmd='openFPGALoader -b tangprimer25k --freq '+str(a.jtag_freq)+' '+shlex.quote(rf)+' && python3 '+shlex.quote(remote+'/capture.py')+' '+shlex.quote(remote+f'/profile_{p}.bin')
            code,log=execute(c,['flock','-n','/tmp/production_ip_25k_board.lock','sh','-c',cmd],60)
            (out/f'profile_{p}_program_uart.log').write_text(log,encoding='utf-8')
            try:sftp.get(remote+f'/profile_{p}.bin',str(out/f'profile_{p}.bin'))
            except FileNotFoundError:pass
            assert code==0,('auto program/capture',p,log[-1000:])
            raw=(out/f'profile_{p}.bin').read_bytes();frames=packets(raw);result=check(p,frames)
            checked=dict(profile=p,status='PASS',runs=result,raw_frames=len(frames),raw_sha256=hashlib.sha256(raw).hexdigest())
            (out/f'profile_{p}_checked.json').write_text(json.dumps(checked,indent=2)+'\n')
            report['profiles'].append(dict(profile=p,status='PASS',runs=len(result),raw_outputs=sum(len(v['raw']) for v in result),
                   raw_sha256=checked['raw_sha256'],bitstream_sha256=r['bitstream_sha256'],rx_pin_edges=result[-1]['status']['protocol_errors']))
            (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
            print(f'BOARD AUTO profile={p} PASS cases={len(result)} outputs={report["profiles"][-1]["raw_outputs"]}',flush=True)
        report['status']='PASS'
    except Exception as e:report['status']='FAIL';report['reason']=str(e);raise
    finally:
        (out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');sftp.close();c.close();print('Evidence='+str(out),flush=True)

if __name__=='__main__':main()
