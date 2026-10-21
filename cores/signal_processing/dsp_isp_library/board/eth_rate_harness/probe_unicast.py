"""Settle whether the dock really rejects unicast IPv4 datagrams, or whether the
earlier claim was an artefact of reading rx_err as if it were our own traffic.

Every logged board session satisfies  tx_frames == rx_udp == requests sent (+1 for
the STAT poll), while rx_err runs 0..34 independently of what we send.  The extra
frames are this PC's own background multicast (LLMNR/mDNS/NetBIOS on the dock link)
correctly classified as 'not addressed to us', so no logged counter shows one of our
datagrams being rejected.

This probe separates the three cases that claim conflates, using only counters the
pipe already reports plus host-side ARP state:

  idle    measure the background frame rate with nothing sent, so later deltas mean
          something.  rx_err/s is the noise floor.
  icmp    ping the dock.  stat_ping only increments for a unicast IPv4 echo request
          that passed the whole RX gate, so replies plus a stat_ping delta prove
          unicast RX works; frames advancing with stat_ping flat means the gate
          really is rejecting; frames flat means the datagram never arrived, i.e.
          ARP resolution failed and the defect was host-side all along.
  udp     one unicast STAT request, then read counters over broadcast (the reliable
          path) to see whether the pipe accepted and answered it even though the
          host saw no reply.

Writes probe.json next to the evidence it explains.  Run with the dock powered and
cabled: python probe_unicast.py
"""
import argparse, json, re, subprocess, sys, time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import eth_protocol as ep


def sh(*cmd):
    p = subprocess.run(cmd, capture_output=True)
    return p.returncode, (p.stdout + p.stderr).decode('gbk', 'replace')


def arp_entry(ip):
    """Return (mac, kind) for `ip` in this host's ARP cache, or (None, reason)."""
    rc, out = sh('arp', '-a', '-N', ip)
    if rc != 0:
        rc, out = sh('arp', '-a')
    for line in out.splitlines():
        m = re.match(r'\s*(\d+\.\d+\.\d+\.\d+)\s+((?:[0-9a-f]+-){5}[0-9a-f]+)'
                     r'\s+(\w+)', line, re.I)
        if m and m.group(1) == ip:
            return m.group(2).upper().replace('-', ':'), m.group(3)
    return None, 'no-entry'


def ping_count(ip, n):
    rc, out = sh('ping', '-n', str(n), '-w', '1000', ip)
    replies = len(re.findall(r'TTL=\d+', out, re.I))
    return dict(rc=rc, replies=replies, sent=n,
                unresolved=bool(re.search(r'unreachable|无法访问|请求超时', out, re.I)))


def main():
    a = argparse.ArgumentParser()
    a.add_argument('--bind-ip', default='192.168.137.1')
    a.add_argument('--endpoint', default=ep.ENDPOINT_IP)
    a.add_argument('--idle', type=float, default=3.0)
    a.add_argument('--pings', type=int, default=4)
    a.add_argument('--out', default=None)
    args = a.parse_args()

    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    out = Path(args.out or ep.HERE / 'evidence' / ('probe_unicast_' + ts))
    out.mkdir(parents=True, exist_ok=True)
    report = dict(started_at=ts, bind_ip=args.bind_ip, endpoint=args.endpoint,
                  fpga_mac=ep.FPGA_MAC, steps=[])

    def broadcast_status(client, tries=3):
        for i in range(tries):
            try:
                st, rtt = client.status()
                return st, rtt, None
            except Exception as exc:              # noqa: BLE001 - report any host error
                last = exc
                time.sleep(0.3)
        return None, None, str(last)

    with ep.EthClient(bind_ip=args.bind_ip, broadcast=True) as bc:
        base, rtt, err = broadcast_status(bc)
        if base is None:
            report['verdict'] = ('BLOCKED: the dock answers no broadcast STAT '
                                 'request (%s). It is unpowered, unprogrammed or '
                                 'the link is down; this probe cannot run.' % err)
            (out / 'probe.json').write_text(json.dumps(report, indent=2), 'utf-8')
            print(report['verdict'])
            return 2
        print('baseline STAT ok rtt=%s us %s' % (rtt, base), flush=True)

        # ---- idle: background frame rate with nothing sent ----
        t0 = time.monotonic()
        time.sleep(args.idle)
        after_idle, rtt2, err2 = broadcast_status(bc)
        d = ep.status_delta(base, after_idle) if after_idle else {}
        secs = time.monotonic() - t0
        report['steps'].append(dict(
            step='idle', seconds=round(secs, 2), delta=d, err_per_s=d.get('rx_err', 0) / secs,
            note='rx_err here is host background traffic, not a rejected request'))
        print('idle %.1fs: rx_frames+%s rx_err+%s (noise floor %.2f err/s)'
              % (secs, d.get('rx_frames'), d.get('rx_err'),
                 d.get('rx_err', 0) / max(secs, 1e-9)), flush=True)

        # ---- icmp: does a unicast IPv4 datagram reach the gate? ----
        before_ping = after_idle
        ping = ping_count(args.endpoint, args.pings)
        ping['arp_before'] = dict(zip(('mac', 'kind'), arp_entry(args.endpoint)))
        time.sleep(0.4)
        after_ping, rtt3, err3 = broadcast_status(bc)
        dp = ep.status_delta(before_ping, after_ping) if after_ping else {}
        ping['delta'] = dp
        ping['arp_after'] = dict(zip(('mac', 'kind'), arp_entry(args.endpoint)))
        report['steps'].append(dict(step='icmp', pings=args.pings, **ping))
        print('icmp: replies=%s/%s stat_ping+%s rx_frames+%s rx_err+%s arp=%s'
              % (ping['replies'], args.pings, dp.get('ping'), dp.get('rx_frames'),
                 dp.get('rx_err'), ping['arp_after']), flush=True)

        # ---- udp: one unicast datagram, counters read over broadcast ----
        before_udp = after_ping
        uni = dict(sent=1)
        with ep.EthClient(bind_ip=args.bind_ip, broadcast=False) as uc:
            t1 = time.perf_counter()
            try:
                st, rtt_us = uc.status(timeout=3.0)
                uni.update(reply=True, rtt_us=rtt_us, counters=st)
            except Exception as exc:              # noqa: BLE001
                uni.update(reply=False, error=str(exc),
                           waited_s=round(time.perf_counter() - t1, 2))
        after_udp, rtt4, err4 = broadcast_status(bc)
        du = ep.status_delta(before_udp, after_udp) if after_udp else {}
        uni['delta'] = du
        report['steps'].append(dict(step='udp', **uni))
        print('udp unicast: reply=%s rx_frames+%s rx_udp+%s tx_frames+%s rx_err+%s'
              % (uni.get('reply'), du.get('rx_frames'), du.get('rx_udp'),
                 du.get('tx_frames'), du.get('rx_err')), flush=True)

        # ---- verdict ----
        ping_ok = ping['replies'] > 0 or (dp.get('ping', 0) or 0) > 0
        gate_rejects = (dp.get('rx_frames', 0) or 0) >= args.pings and \
            (dp.get('ping', 0) or 0) == 0
        never_arrives = (dp.get('rx_frames', 0) or 0) < args.pings and not ping_ok
        if ping_ok and uni.get('reply'):
            report['verdict'] = ('UNICAST WORKS. The recorded "dock drops every '
                                 'unicast IPv4 datagram" defect is refuted: ICMP '
                                 'round-trips and the unicast UDP request is '
                                 'answered. Investigate the host/socket path of the '
                                 'old run instead.')
        elif gate_rejects:
            report['verdict'] = ('UNICAST RX GATE REJECTS CONFIRMED. %d echo '
                                 'requests arrived (rx_frames) but stat_ping never '
                                 'moved, so the frame fails the IPv4 clause at '
                                 'rmii_eth_pipe.sv:722 while the same shape passes '
                                 'as broadcast. Localise by value.' % args.pings)
        elif never_arrives:
            report['verdict'] = ('UNICAST DATAGRAMS NEVER ARRIVE. rx_frames stayed '
                                 'at the background floor and ARP shows %s, so the '
                                 'dock ARP reply is not being accepted by this host. '
                                 'That is the real defect; the RX gate was never the '
                                 'problem.' % ping['arp_after'])
        elif uni.get('delta', {}).get('rx_udp', 0) > 0 and not uni.get('reply'):
            report['verdict'] = ('REQUEST ACCEPTED, REPLY LOST. The pipe counted the '
                                 'unicast datagram (rx_udp+%s, tx_frames+%s) but the '
                                 'host saw nothing, so the defect is in the TX '
                                 'destination resolution, not the RX gate.'
                                 % (du.get('rx_udp'), du.get('tx_frames')))
        else:
            report['verdict'] = ('INCONCLUSIVE: deltas %s / %s are within the '
                                 'background noise floor measured above; rerun with '
                                 '--pings and --idle tuned away from it.' % (dp, du))
        report['accounting'] = dict(
            rule='rx_frames == rx_udp + rx_err + accepted arp/icmp frames',
            idle=report['steps'][0].get('delta'), icmp=dp, udp=du)

    (out / 'probe.json').write_text(json.dumps(report, indent=2), 'utf-8')
    print('\nverdict: ' + report['verdict'])
    print('wrote ' + str(out / 'probe.json'))
    return 0 if report['verdict'].startswith('UNICAST WORKS') else 1


if __name__ == '__main__':
    sys.exit(main())
