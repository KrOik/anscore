"""Simulate then build a 25K dock transport probe (GW5A-25A).

    python build_transport.py [--build] [--probe echo|beacon]

`echo` is the pure full-duplex contract (host byte in, XOR-A5 byte out).
`beacon` adds a self-driven TX stream so a silent link can be split into
"image/clock/TX pad dead" versus "host->FPGA RX pad dead".

Produces evidence dirs under board/tang25k/transport/evidence/<stamp>/ with the
simulation trace, synthesis/P&R logs and an uncompressed design_25k.fs that
board/remote/run_25k.py loads over JTAG into SRAM.
"""
import argparse, datetime, hashlib, json, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent            # board/tang25k/transport
LIB = HERE.parents[2]                             # dsp_isp_library
ROOT = HERE.parents[4]                            # repository root
sys.path.insert(0, str(HERE.parent))              # board/tang25k for device_flow

PROBES = {
    'echo': dict(top='transport_probe_25k', marker='TRANSPORT SIM PASS',
                 src=['transport_probe_25k.v', 'tb_transport_probe_25k.sv'],
                 tb='tb_transport_probe_25k'),
    'beacon': dict(top='beacon_probe_25k', marker='BEACON SIM PASS',
                   src=['beacon_probe_25k.v', 'tb_beacon_probe_25k.sv'],
                   tb='tb_beacon_probe_25k'),
}
DEP = [ROOT / 'cores/communication/primitives/src/uart_rx.v',
       ROOT / 'cores/communication/primitives/src/uart_tx.v']
RTL = ['uart_rx.v', 'uart_tx.v']


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--build', action='store_true')
    p.add_argument('--probe', choices=sorted(PROBES), default='echo')
    p.add_argument('--dest', type=Path)
    a = p.parse_args()
    sel = PROBES[a.probe]
    dest = a.dest or (HERE / 'evidence' / datetime.datetime.now()
                      .strftime('%Y%m%d_%H%M%S_%f'))
    dest.mkdir(parents=True, exist_ok=True)
    for f in [HERE / s for s in sel['src']] + DEP:
        shutil.copy2(f, dest / f.name)
    (dest / 'hashes.json').write_text(json.dumps({
        f.name: hashlib.sha256((dest / f.name).read_bytes()).hexdigest()
        for f in dest.iterdir() if f.suffix in ('.v', '.sv')}, indent=2))

    import device_flow

    def run(cmd, log):
        return device_flow.run_capture(dest, cmd, log)

    run(['iverilog', '-g2012', '-Wall', '-I.', '-s', sel['tb'],
         '-o', 'sim.vvp', *(sel['src'] + RTL)], 'compile.log')
    out = run(['vvp', 'sim.vvp'], 'simulation.log')
    nonce = [bytes.fromhex(l)[0] for l in (dest / 'nonce.bin').read_text().split()]
    echo = [bytes.fromhex(l)[0] for l in (dest / 'tx.bin' if a.probe == 'beacon'
                                          else dest / 'echo.bin'
                                          ).read_text().split()]
    exp = [b ^ 0xA5 for b in nonce]
    hits = sum(1 for e in exp if e in echo)
    if a.probe == 'echo':
        assert echo[:len(exp)] == exp, 'sim echo mismatch'
    # the beacon probe interleaves passthrough and beacon bytes on one wire, so
    # its framing/passthrough accounting is done in the TB; only the verdict
    # marker is re-checked here.
    assert sel['marker'] in out, out[-400:]
    (dest / 'simulation_summary.json').write_text(json.dumps(dict(
        status='PASS', probe=a.probe, bytes_in=len(nonce), bytes_out=len(echo),
        echoes_present=hits, clk_mhz=device_flow.CLK_MHZ, baud=115200, xor=0xA5,
        sim=out.strip().splitlines()[-2:]), indent=2) + '\n')
    print(sel['marker'], dest, flush=True)
    if a.build:
        s = device_flow.build(dest, top=sel['top'], rtl=[sel['src'][0]] + RTL,
                              params=dict(CLK_FRE=device_flow.CLK_MHZ))
        print(json.dumps(s, indent=2))


if __name__ == '__main__':
    main()
