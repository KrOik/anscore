"""Force the stuck FT2232 back into a configured state without touching anything
else on the host's USB tree.

After a port de-authorize the dock's FT2232 came back with an address but no
configuration (`bConfigurationValue` empty, no `2-1.4:1.x` interface dirs, and a
write to `authorized` that fails with ETIMEDOUT). libftdi therefore cannot open it,
which is a strictly worse state than the original `TDO is stuck at 0`. This script
sends the two things the kernel offers for exactly one device -- a USBDEVFS_RESET
ioctl on its bus device node, and a usb-driver unbind/bind -- then hands the UART
interface back to ftdi_sio so the console node returns.

The password is streamed into `sudo -S` on the SSH channel stdin only. The shell
sequence lives in a file uploaded to the dock, so no quoting or credential ever
reaches argv.
"""
import argparse
import shlex
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import remote_board as rb
from dockcycle import sudo_write

SCRIPT = r'''#!/bin/sh
D=/sys/bus/usb/devices/2-1.4
BUS=$(cat "$D/busnum" 2>/dev/null)
DEV=$(cat "$D/devnum" 2>/dev/null)
echo "device bus=$BUS dev=$DEV"
python3 - "$BUS" "$DEV" <<'PY'
import fcntl, os, sys
bus, dev = sys.argv[1], sys.argv[2]
path = '/dev/bus/usb/%03d/%03d' % (int(bus), int(dev))
fd = os.open(path, os.O_WRONLY)
try:
    fcntl.ioctl(fd, 0x5514)   # USBDEVFS_RESET
    print('USBDEVFS_RESET ok', path)
finally:
    os.close(fd)
PY
sleep 2
echo 2-1.4 > /sys/bus/usb/drivers/usb/unbind 2>/dev/null && echo unbound || echo "unbind failed"
sleep 2
echo 2-1.4 > /sys/bus/usb/drivers/usb/bind 2>/dev/null && echo bound || echo "bind failed"
sleep 3
echo "bConfigurationValue=$(cat "$D/bConfigurationValue" 2>/dev/null)"
echo "ifaces=$(ls -d "$D":* 2>/dev/null | tr '\n' ' ')"
for i in "$D":*; do
  [ -d "$i" ] || continue
  echo "  $(basename "$i") driver=$(readlink -f "$i/driver" 2>/dev/null)"
done
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='192.168.31.176')
    ap.add_argument('--user', default='bianbu')
    args = ap.parse_args()
    client = rb.connect(SimpleNamespace(host=args.host, user=args.user, port='/dev/ttyUSB1'))
    pw = rb.password()
    remote = '/tmp/dockreset_%d.sh' % int(time.time())
    sftp = client.open_sftp()
    with sftp.file(remote, 'w') as stream:
        stream.write(SCRIPT)
    sftp.chmod(remote, 0o755)
    sftp.close()
    chan = client.get_transport().open_session()
    chan.settimeout(90)
    chan.exec_command('sudo -S -p "" sh ' + shlex.quote(remote))
    chan.sendall(pw + '\n')
    time.sleep(0.5)
    chan.shutdown_write()
    out = b''
    err = b''
    while True:
        if chan.recv_ready():
            out += chan.recv(4096)
        if chan.recv_stderr_ready():
            err += chan.recv_stderr(4096)
        if chan.exit_status_ready():
            break
        time.sleep(0.2)
    text = (out + err).decode('utf-8', 'replace').replace(pw, '<scrubbed>')
    print('rc=%s' % chan.exit_status)
    print(text)
    chan.close()
    rb.execute(client, ['rm', '-f', remote])

    # ftdi_sio may not have re-attached after the reset; the console is channel 1.
    code, text = rb.execute(client, ['sh', '-c', 'ls /dev/ttyUSB* 2>/dev/null'])
    if not text.strip():
        print('no console node, binding ftdi_sio to interface 1',
              *sudo_write(client, '/sys/bus/usb/drivers/ftdi_sio/bind', '2-1.4:1.1', pw))
        time.sleep(2.0)
        code, text = rb.execute(client, ['ls', '/dev/ttyUSB0', '/dev/ttyUSB1'], timeout=20)
        print('nodes:', text.replace('\n', ' ').strip())
    else:
        print('nodes:', text.replace('\n', ' ').strip())
    code, text = rb.execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'],
                            timeout=60)
    print('detect rc=%s' % code)
    for line in text.splitlines():
        if line.strip():
            print('  ' + line[:130])
    return 0 if 'GW5A-25' in text else 1


if __name__ == '__main__':
    raise SystemExit(main())
