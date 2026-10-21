"""SRAM-only pin/byte diagnostic; separate from acceptance builds."""
import hashlib
import json
import shlex
import paramiko
import argparse
from common import ROOT,SUITE,evidence,run
from build import metrics
from remote_board import password,execute

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--official-io',action='store_true');a=ap.parse_args()
    out=evidence('uart_diagnostic'); net=out/'net.json'; pnr=out/'pnr.json'; fs=out/'probe.fs'
    script=out/'synth.ys';script.write_text('read_verilog diagnostics/uart_probe.v board/sys_uart.v\nsynth_gowin -family gw5a -noalu -top sys_uart_probe -json '+net.as_posix()+'\n')
    run(['yosys','-s',script],out/'yosys.log',120);m=metrics(net,'sys_uart_probe');assert m['under_budget']
    cst=ROOT/'board/tang25k.cst'
    if a.official_io:
        cst=out/'official_io.cst'
        text=(ROOT/'board/tang25k.cst').read_text().replace('"uart_rx" PULL_MODE=UP DRIVE=OFF','"uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=OFF')
        cst.write_text(text)
    run(['nextpnr-himbaechel','--json',net,'--write',pnr,'--device','GW5A-LV25MG121NES','--vopt','family=GW5A-25A','--vopt','cst='+cst.as_posix(),'--vopt','sspi_as_gpio','--freq','50'],out/'nextpnr.log',300)
    run([SUITE/'lib/python3.exe',SUITE/'bin/gowin_pack-script.py','-d','GW5A-25A','--sspi_as_gpio','-o',fs,pnr],out/'pack.log')
    c=paramiko.SSHClient();c.set_missing_host_key_policy(paramiko.AutoAddPolicy());c.connect('192.168.31.176',username='bianbu',password=password(),look_for_keys=False,allow_agent=False,timeout=15)
    sftp=c.open_sftp(); remote='/home/bianbu/'+out.name+'.fs';sftp.put(str(fs),remote)
    code,det=execute(c,['openFPGALoader','-b','tangprimer25k','--detect']);assert code==0 and '0x1281b' in det and 'GW5A-25' in det
    capture="import serial,time; s=serial.Serial('/dev/ttyUSB1',115200,timeout=.2);s.reset_input_buffer();b=s.read(200);print('BEFORE',b.hex());s.write(bytes.fromhex('55aa1234567890'));s.flush();b=s.read(200);print('AFTER',b.hex());s.close()"
    cmd='openFPGALoader -b tangprimer25k '+shlex.quote(remote)+' && python3 -c '+shlex.quote(capture)
    code,text=execute(c,['flock','-n','/tmp/production_ip_25k_board.lock','sh','-c',cmd],60)
    (out/'remote.log').write_text(text,encoding='utf-8');(out/'summary.json').write_text(json.dumps(dict(exit_code=code,metrics=m,bitstream_sha256=hashlib.sha256(fs.read_bytes()).hexdigest()),indent=2))
    print(text[-3000:]);print(out);sftp.close();c.close()

if __name__=='__main__': main()
