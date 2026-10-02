"""Shared GW5A / Tang Primer 25K dock build flow for the dsp_isp_library board
harnesses.

The 20K harnesses build with ``synth_gowin -family gw2a`` + GW2A-18 P&R and are
loaded over JTAG as flash-compressed images.  The 25K dock
(GW5A-LV25MG121NES) differs in four measured ways that this module encodes:

* the dock oscillator is 50 MHz on E2 (20K: 27 MHz on H11), so every UART
  instance must be built with ``CLK_FRE=50``;
* JTAG/SRAM loads must be packed **without** ``-c`` -- a compressed image
  programs "successfully" and the FPGA runs nothing;
* ``nextpnr`` needs ``--vopt family=GW5A-25A`` plus ``sspi_as_gpio`` (the same
  vopt the packer needs), and ``cpu_as_gpio`` is not a nextpnr vopt;
* the resource ceiling is the 25K device, not the 20K 15K-LUT/4-DSP gate.

Usage from a harness ``run.py``::

    sys.path.insert(0, str(LIB / 'board/tang25k'))
    import device_flow
    summary = device_flow.build(dest, top='dsp_stream_harness',
                               params={'CORE': core_id, 'CLK_FRE': 50})
"""
import collections
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent                 # board/tang25k


def _up(path, n):
    """parents[n] that cannot raise: the rig stages this file in a shallow dir."""
    for _ in range(n):
        path = path.parent
    return path


BOARD = _up(HERE, 1)                   # board
LIB = _up(HERE, 2)                     # dsp_isp_library
ROOT = _up(HERE, 4)                    # repository root
CAD = ROOT / 'tools' / 'oss-cad-suite' / 'oss-cad-suite'

DEVICE = 'GW5A-LV25MG121NES'
FAMILY = 'GW5A-25A'
YOSYS_FAMILY = 'gw5a'
CLK_MHZ = 50                                          # dock oscillator, pin E2
UART_RX_PIN = 'B3'
UART_TX_PIN = 'C3'
DBG_PIN = 'E8'                                        # led0 pad, LA-sniffable

# Device ceilings reported by nextpnr for GW5A-LV25MG121NES.
CEILING = dict(lut4=23040, dff=23040, bsram=56, mult12=56)
# Keep the SOP's >=20% margin on each hard resource.
GATE = dict(lut4=18400, dff=18400, bsram=44, mult12=44)

CST = """// Tang Primer 25K DOCK (GW5A-LV25MG121NES) harness pins.
// clk = 50 MHz dock oscillator on E2; the FPGA serial console runs through the
// onboard SIPEED USB debugger: TX pad C3 -> ttyUSB1, host -> B3.
IO_LOC "clk" E2;
IO_PORT "clk" PULL_MODE=NONE DRIVE=OFF BANK_VCCIO=3.3;
IO_LOC "uart_rx_pin" {rx};
IO_PORT "uart_rx_pin" PULL_MODE=UP DRIVE=OFF BANK_VCCIO=3.3;
IO_LOC "uart_tx" {tx};
IO_PORT "uart_tx" PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "dbg_uart" {dbg};
IO_PORT "dbg_uart" PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
"""


def write_cst(dest, name='tang25k.cst'):
    (Path(dest) / name).write_text(CST.format(rx=UART_RX_PIN, tx=UART_TX_PIN,
                                              dbg=DBG_PIN), encoding='utf-8')
    return name


def tool_env():
    env = dict(os.environ)
    env['PATH'] = (str(CAD / 'bin') + os.pathsep + str(CAD / 'lib')
                   + os.pathsep + env['PATH'])
    return env


def run(dest, cmd, log, timeout=900):
    resolved = [resolve(cmd[0]), *[str(c) for c in cmd[1:]]]
    with (Path(dest) / log).open('w') as f:
        f.write('$ ' + ' '.join(resolved) + '\n')
        f.flush()
        r = subprocess.run(resolved, cwd=str(dest), env=tool_env(), stdout=f,
                           stderr=subprocess.STDOUT, timeout=timeout)
    if r.returncode:
        raise RuntimeError('%s failed rc=%d; see %s' % (log, r.returncode, dest))
    return r


def cells_xtra_lib():
    p = CAD / 'share' / 'yosys' / 'gowin' / 'cells_xtra_gw5a.v'
    return p if p.exists() else None


def resolve(exe):
    """Absolute path of a tool from the OSS CAD bin dir.

    Bare names must never be handed to CreateProcess on this host: the
    App Paths registry key wins over PATH and resolves ``iverilog`` to a dead
    chocolatey shim even when the OSS bin dir is first in PATH.
    """
    return shutil.which(str(exe), path=tool_env()['PATH']) or str(exe)


def run_capture(dest, cmd, log, timeout=900):
    """Run ``cmd`` in ``dest``, logging stdout+stderr, and return stdout."""
    resolved = [resolve(cmd[0]), *[str(c) for c in cmd[1:]]]
    r = subprocess.run(resolved, cwd=str(dest), env=tool_env(),
                       capture_output=True, text=True, timeout=timeout)
    (Path(dest) / log).write_text('$ %s\n%s%s' % (' '.join(resolved), r.stdout,
                                                  r.stderr), encoding='utf-8')
    if r.returncode:
        raise RuntimeError('%s failed rc=%d: %s' % (log, r.returncode, dest))
    return r.stdout


def build(dest, top, rtl, params=None, chparams=None, cst_name=None,
          noalu=True, gate=GATE,
          image='design_25k.fs', json_name='top25k.json',
          synth_timeout=900, pnr_timeout=900):
    """Synthesize, place-and-route and pack ``top`` in ``dest`` for the 25K.

    ``rtl`` lists the source files (basenames present in ``dest``) and
    ``params`` are set on the top module with ``chparam`` so a harness can pick
    its CORE and CLK_FRE.  ``chparams`` maps a *child module name* to the values
    it should carry, which a wrapper top needs: read_verilog elaborates every
    module in a file with its own defaults, so a child whose default branch
    instantiates a core that is not in ``rtl`` fails ``hierarchy -check`` even
    though the wrapper overrides it (measured: CORE=2 on the wrapper still left a
    CORE=0 ``dsp_stream_harness`` pointing at the absent farrow module).  Returns
    the machine-readable build summary, which is also written to
    ``build_25k_summary.json``.

    ``synth_timeout``/``pnr_timeout`` are the wall-clock caps on the two heavy
    steps.  900 s is what every single core needs; a composed delivery chain is a
    bigger problem, and the DC -> statistics chain was measured dying in ABC9
    after exactly 900 s with nothing wrong on the design side.
    """
    dest = Path(dest)
    cst_name = cst_name or write_cst(dest)
    params = dict(params or {})
    ys = ['read_verilog -sv -I. ' + ' '.join(rtl)]
    lib = cells_xtra_lib()
    if lib:
        ys.append('read_verilog -lib %s' % str(lib).replace('\\', '/'))
    for mod, kv in (chparams or {}).items():
        for k, v in kv.items():
            ys.append('chparam -set %s %d %s' % (k, int(v), mod))
    for k, v in params.items():
        ys.append('chparam -set %s %d %s' % (k, int(v), top))
    ys.append('synth_gowin %s -family %s -top %s -json %s'
              % ('-noalu' if noalu else '', YOSYS_FAMILY, top, json_name))
    ys.append('stat')
    (dest / 'build25k.ys').write_text('\n'.join(ys) + '\n', encoding='utf-8')
    run(dest, ['yosys', '-s', 'build25k.ys'], 'synthesis_25k.log',
        timeout=synth_timeout)

    net = json.loads((dest / json_name).read_text())
    counts = collections.Counter(c['type']
                                 for c in net['modules'][top]['cells'].values())
    lut = sum(v for k, v in counts.items() if re.fullmatch(r'LUT[1-4]|ALU', k))
    dsp = sum(v for k, v in counts.items()
              if k.startswith(('MULT', 'PADD', 'ALU54')))

    run(dest, ['nextpnr-himbaechel', '--json', json_name, '--write',
               'pnr25k.json', '--device', DEVICE, '--vopt', 'family=%s' % FAMILY,
               '--vopt', 'cst=%s' % cst_name, '--vopt', 'sspi_as_gpio',
               '--freq', str(CLK_MHZ), '--seed', '1', '--log', 'nextpnr_25k.log'],
        'pnr_console_25k.log', timeout=pnr_timeout)
    log = (dest / 'nextpnr_25k.log').read_text(errors='replace')
    util = {}
    for name, key in (('LUT4', 'lut4'), ('DFF', 'dff'), ('BSRAM', 'bsram'),
                      ('MULT12X12', 'mult12')):
        # nextpnr right-aligns both fields: "LUT4:     117/  23040     0%"
        m = re.search(r'%s:\s+(\d+)/\s*\d+' % name, log)
        util[key] = int(m.group(1)) if m else None
    if (not util.get('lut4') or 'Nothing was placed' in log
            or 'Program finished normally' not in log
            or re.search(r'^ERROR', log, re.M)):
        raise RuntimeError('route failed or utilisation unparsed; %s' % dest)
    clocks = re.findall(r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz', log)
    if not clocks:
        raise RuntimeError('no post-route frequency data; %s' % dest)

    python = CAD / 'lib' / 'python3.exe'
    if not python.exists():
        python = CAD / 'bin' / 'python.exe'
    # Uncompressed on purpose: a -c packed image does not run from JTAG/SRAM.
    run(dest, [str(python), str(CAD / 'bin' / 'gowin_pack-script.py'),
               '-d', FAMILY, '--sspi_as_gpio', '-o', image, 'pnr25k.json'],
        'pack_25k.log')

    gates = dict(lut4=util['lut4'] <= gate['lut4'],
                 dff=(util['dff'] or 0) <= gate['dff'],
                 bsram=(util['bsram'] or 0) <= gate['bsram'],
                 mult12=(util['mult12'] or 0) <= gate['mult12'],
                 timing=min(map(float, clocks)) >= CLK_MHZ)
    summary = dict(
        status='BUILD_PASS_NOT_BOARD' if all(gates.values()) else 'BUILD_GATE_FAIL',
        device=DEVICE, family=FAMILY, clk_mhz=CLK_MHZ, top=top,
        params=params, noalu=noalu,
        synth_lut=lut, synth_dsp=dsp,
        util=util, ceiling=CEILING, gate=gate,
        fmax_mhz=sorted(map(float, clocks)),
        gates=gates,
        bitstream=image,
        bitstream_bytes=(dest / image).stat().st_size,
        bitstream_sha256=hashlib.sha256((dest / image).read_bytes()).hexdigest(),
        built_at=datetime.datetime.now(datetime.timezone.utc)
        .strftime('%Y-%m-%dT%H:%M:%SZ'),
    )
    (dest / 'build_25k_summary.json').write_text(
        json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    if not all(gates.values()):
        raise RuntimeError('25K resource/timing gate: %s' % gates)
    return summary
