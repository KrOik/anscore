"""Remote equivalent of re-seating the dock's USB plug.

The Tang Primer 25K dock takes its power from the host USB port, so de-authorizing
and re-authorizing that one port power-cycles the FPGA the same way unplugging and
replugging the cable does. This exists because the board has been reporting
`TDO is stuck at 0` while the FT2232 stays enumerated: the adapter is fine, the
chip is not answering, and the only remaining cause is chip power, held reset, or
mode-pin state.

Safety by construction: the port is chosen by reading the FTDI vendor/product id
from sysfs, and nothing is toggled unless exactly one such device is found. The
login password is streamed into `sudo -S` over the SSH channel's stdin, never into
argv, and never printed or logged.
"""
import argparse
import shlex
import sys
import time
from types import SimpleNamespace

import remote_board as rb

DISCOVER = r'''for d in /sys/bus/usb/devices/*/; do
  v=$(cat "$d/idVendor" 2>/dev/null)
  p=$(cat "$d/idProduct" 2>/dev/null)
  if [ "$v" = "0403" ]; then
    echo "$(basename "$d") $v:$p product=$(cat "$d/product" 2>/dev/null) authorized=$(cat "$d/authorized" 2>/dev/null) power=$(cat "$d/bMaxPower" 2>/dev/null)"
  fi
done'''


def sudo_write(client, path, value, pw):
    """`sudo -S tee <path>`, with the password then the value on channel stdin."""
    chan = client.get_transport().open_session()
    chan.settimeout(30)
    chan.exec_command('sudo -S -p "" tee ' + shlex.quote(path))
    chan.sendall(pw + '\n')
    time.sleep(0.6)
    chan.sendall(value + '\n')
    time.sleep(0.6)
    chan.shutdown_write()
    out = chan.recv(4096).decode('utf-8', 'replace')
    err = chan.recv_stderr(4096).decode('utf-8', 'replace')
    while not chan.exit_status_ready():
        time.sleep(0.2)
    code = chan.exit_status
    chan.close()
    # The password echo never reaches these buffers, but scrub anyway before printing.
    text = (out + err).replace(pw, '<scrubbed>')
    return code, text


def detect(client, label):
    code, text = rb.execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'],
                            timeout=60)
    print(f'{label}: detect rc={code}', flush=True)
    for line in text.splitlines():
        if line.strip():
            print('  ' + line[:120])
    return code, text


def recover(client, pw, dev):
    """Re-claim the re-enumerated FTDI: free both interfaces from ftdi_sio, force
    configuration 1 so libftdi can open it, then hand the UART channel back."""
    code, text = rb.execute(client, ['sh', '-c',
                                     'for i in /sys/bus/usb/devices/%s:*; do [ -d "$i" ] || continue;'
                                     ' echo "$(basename "$i") driver=$(readlink -f "$i/driver" 2>/dev/null)'
                                     ' name=$(cat "$i/interface" 2>/dev/null)"' % dev])
    ifaces = [l.split()[0] for l in text.splitlines() if ':1.' in l]
    print('interfaces:', ' '.join(
        '%s->%s' % (i.split(':')[-1], (l.split('driver=')[1].split()[0].rsplit('/', 1)[-1]
                                      if 'driver=/' in l and len(l.split('driver=')[1].split()) > 0
                                      else 'none')) for i, l in zip(ifaces, text.splitlines())))
    for line in text.splitlines():
        if 'ftdi_sio' in line:
            name = line.split()[0]
            print('  unbind', name, *sudo_write(client, '/sys/bus/usb/drivers/ftdi_sio/unbind', name, pw))
    print('  config', *sudo_write(client, '/sys/bus/usb/devices/%s/bConfigurationValue' % dev, '1', pw))
    time.sleep(3.0)
    code, text = detect(client, 'after config')
    for name in ifaces:
        if name.endswith(':1.1'):
            print('  rebind console', name,
                  *sudo_write(client, '/sys/bus/usb/drivers/ftdi_sio/bind', name, pw))
    time.sleep(2.0)
    code, text = rb.execute(client, ['ls', '/dev/ttyUSB0', '/dev/ttyUSB1'], timeout=20)
    print('nodes:', text.replace('\n', ' ').strip())
    return code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='192.168.31.176')
    ap.add_argument('--user', default='bianbu')
    ap.add_argument('--apply', action='store_true', help='actually toggle the port')
    ap.add_argument('--recover', action='store_true', help='re-claim a re-enumerated FTDI')
    args = ap.parse_args()

    client = rb.connect(SimpleNamespace(host=args.host, user=args.user,
                                       port='/dev/ttyUSB1'))
    code, text = rb.execute(client, ['sh', '-c', DISCOVER])
    lines = [l for l in text.splitlines() if l.strip().startswith(('2-', '1-', '3-', '4-'))]
    print('ftdi candidates:')
    for line in lines:
        print('  ' + line)
    if not args.apply and not args.recover:
        print('discovery only; pass --apply to toggle')
        return 0
    targets = [l.split()[0] for l in lines if ':6010' in l or ':6014' in l]
    if len(targets) != 1:
        raise SystemExit(f'refusing to toggle: expected exactly one FTDI JTAG device, got {targets}')
    pw = rb.password()
    node = '/sys/bus/usb/devices/' + targets[0]
    if args.recover:
        return 0 if recover(client, pw, targets[0]) == 0 else 1
    print(f'cycling {targets[0]} (authorized 0 -> 1), which power-cycles the dock', flush=True)
    print('  off:', *sudo_write(client, node + '/authorized', '0', pw))
    time.sleep(4.0)
    print('  on :', *sudo_write(client, node + '/authorized', '1', pw))
    time.sleep(6.0)
    code, text = rb.execute(client, ['sh', '-c', DISCOVER])
    print('after cycle:')
    for line in text.splitlines():
        if line.strip():
            print('  ' + line)
    code, text = rb.execute(client, ['ls', '/dev/ttyUSB0', '/dev/ttyUSB1'], timeout=20)
    print('nodes:', text.replace('\n', ' ').strip())
    code, text = rb.execute(client, ['openFPGALoader', '-b', 'tangprimer25k', '--detect'],
                            timeout=60)
    print('detect rc=%s' % code)
    for line in text.splitlines():
        if line.strip():
            print('  ' + line[:120])
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
