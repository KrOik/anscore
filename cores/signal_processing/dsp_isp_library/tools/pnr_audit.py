"""Per-core P&R / timing audit for dsp_isp_library (goal.md section 8.5).

For every spec entry: dump the parameter-elaborated port list, generate a
register-shell wrapper (pnr_top: clk, rst_n, obs pins only), run
yosys synth_gowin -noalu -family gw2a, then nextpnr-himbaechel at 27 MHz on
GW2A-LV18PG256C8/I7.  Writes evidence/pnr_<ts>/ per spec under the core dir
and prints a JSON summary line per case.

Gates: DUT-hierarchy LUT1..4 <= 15000, DSP cells <= 4, min clock Fmax >= 27.
Wrapper overhead is reported separately from the DUT cell counts.

Usage:
    python tools/pnr_audit.py                 # all specs
    python tools/pnr_audit.py --only DSP-01   # one requirement
    python tools/pnr_audit.py --list          # print spec table
"""
import argparse, collections, datetime, hashlib, json, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LIB = HERE.parent                       # cores/signal_processing/dsp_isp_library
ROOT = LIB.parents[1]                   # repo root
CAD = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
YOSYS = CAD / 'bin/yosys.exe'
NEXTPNR = CAD / 'bin/nextpnr-himbaechel.exe'
DEVICE = 'GW2A-LV18PG256C8/I7'
FAMILY = 'GW2A-18'
FREQ = 27.0

W = 'cores/signal_processing/dsp_isp_library/infra/window'
FP = 'cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl'


def libsrc(rel):
    # Sources inside dsp_isp_library are relative to LIB; entries starting
    # with 'projects/' are repo-root relative (shared legacy cores).
    if rel.startswith('projects/'):
        return str(ROOT / rel)
    return str(LIB / rel)


# req, case label, dut top, sources (repo-relative to dsp_isp_library),
# parameter overrides, include dirs
SPECS = [
 dict(req='DSP-01', case='resampler_m128', top='polyphase_resampler',
      sources=['dsp/resampler/rtl/polyphase_resampler.sv'],
      params=dict(MAX_TAPS=128)),
 dict(req='DSP-02', case='biquad_sos4', top='biquad_sos_stream',
      sources=['dsp/biquad/rtl/biquad_sos_stream.sv'],
      params=dict(MAX_SOS=4)),
 dict(req='DSP-03', case='ddc_cic3', top='ddc_stream',
      sources=['dsp/ddcduc/rtl/ddc_stream.sv', 'dsp/ddcduc/rtl/duc_stream.sv',
               'dsp/ddcduc/rtl/ddcduc_iq_fir.sv', 'dsp/ddcduc/rtl/ddcduc_nco.sv',
               'infra/stream/stream_sync_fifo.v'],
      params=dict(CIC_STAGES=3)),
 dict(req='DSP-03', case='duc_cic3', top='duc_stream',
      sources=['dsp/ddcduc/rtl/ddc_stream.sv', 'dsp/ddcduc/rtl/duc_stream.sv',
               'dsp/ddcduc/rtl/ddcduc_iq_fir.sv', 'dsp/ddcduc/rtl/ddcduc_nco.sv'],
      params=dict(CIC_STAGES=3)),
 dict(req='DSP-04', case='statistics_ls0', top='statistics_stream',
      sources=['dsp/statistics/rtl/statistics_stream.sv'],
      params=dict(LOGIC_SQUARE=0)),
 dict(req='DSP-05', case='window_mult', top='window_mult',
      sources=['dsp/spectrum/rtl/window_mult.sv',
               'dsp/spectrum/rtl/window_cos_rom.sv'], params={}),
 dict(req='DSP-05', case='mag_squared', top='mag_squared',
      sources=['dsp/spectrum/rtl/mag_squared.sv'], params={}),
 dict(req='DSP-05', case='block_accum', top='block_accum',
      sources=['dsp/spectrum/rtl/block_accum.sv'], params={}),
 dict(req='DSP-05', case='peak_search', top='peak_search',
      sources=['dsp/spectrum/rtl/peak_search.sv'], params={}),
 dict(req='DSP-06', case='correlation_d16_t64', top='correlation_stream',
      sources=['dsp/correlation/rtl/correlation_stream.sv'], params={}),
 dict(req='DSP-07', case='agc_default', top='agc_stream',
      sources=['dsp/agc/rtl/agc_stream.sv'], params={}),
 dict(req='DSP-08', case='carrier_loop', top='carrier_loop',
      sources=['dsp/recovery/rtl/carrier_loop.sv',
               'dsp/recovery/rtl/timing_loop.sv',
               'dsp/recovery/rtl/nco.sv', 'dsp/recovery/rtl/pi_loop.sv',
               'dsp/recovery/rtl/lock_det.sv'], params={}),
 dict(req='DSP-08', case='timing_loop', top='timing_loop',
      sources=['dsp/recovery/rtl/carrier_loop.sv',
               'dsp/recovery/rtl/timing_loop.sv',
               'dsp/recovery/rtl/nco.sv', 'dsp/recovery/rtl/pi_loop.sv',
               'dsp/recovery/rtl/lock_det.sv'], params={}),
 dict(req='DSP-10', case='halfband_decim_l4', top='halfband_decim',
      sources=['dsp/halfband/rtl/halfband_decim.sv'], params=dict(LANES=4)),
 dict(req='DSP-10', case='halfband_interp_l4', top='halfband_interp',
      sources=['dsp/halfband/rtl/halfband_interp.sv'], params=dict(LANES=4)),
 dict(req='DSP-10', case='cic_comp_fir_l4', top='cic_comp_fir',
      sources=['dsp/halfband/rtl/cic_comp_fir.sv'], params=dict(LANES=4)),
 dict(req='DSP-11', case='farrow_cubic', top='farrow_cubic_stream',
      sources=['dsp/farrow/rtl/farrow_cubic_stream.sv'], params={}),
 dict(req='DSP-12', case='hilbert_p16_l2', top='synth_top',
      sources=['dsp/hilbert/rtl/hilbert_analytic.sv',
               'dsp/hilbert/rtl/phase_freq.sv',
               'dsp/hilbert/rtl/hilbert_core.sv',
               'dsp/hilbert/evidence/synth_20260925_110642_636620/pairs16_lanes2/top.sv'],
      params={}),
 dict(req='DSP-13', case='goertzel_bank', top='goertzel_bank',
      sources=['dsp/goertzel/rtl/goertzel_bank.sv'], params={}),
 dict(req='DSP-14', case='stft_ramregs1', top='stft_welch',
      sources=['dsp/stft/rtl/stft_welch.sv',
               'cores/signal_processing/transforms/src/fft64.v',
               'cores/signal_processing/transforms/src/sig_sdp_ram.v',
               'cores/signal_processing/transforms/src/tw_rom_cos.v',
               'cores/signal_processing/transforms/src/tw_rom_sin.v',
               'dsp/spectrum/rtl/window_mult.sv',
               'dsp/spectrum/rtl/window_cos_rom.sv',
               'dsp/spectrum/rtl/mag_squared.sv'],
      params=dict(RAM_REGS=1)),
 dict(req='DSP-15', case='lms_serial_dsp', top='lms_stream',
      sources=['dsp/lms/rtl/lms_stream.sv',
               'infra/fixedpoint/rtl/recip_div.sv'],
      params=dict(NTAPS=8, IMPL=0, MULT_DSP=1)),
 dict(req='DSP-16', case='pfb_m8p8', top='pfb_stream',
      sources=['dsp/pfb/rtl/pfb_stream.sv'],
      params=dict(M=8, P=8), incdirs=['dsp/pfb/rtl'], no_dut_pass=True),
 dict(req='ISP-02', case='conv_k3_d8_pad1', top='convolution_stream',
      sources=['isp/convolution/convolution_stream.v',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(WIDTH=32, HEIGHT=24, K=3, BITS=8, PAD_MODE=1)),
 dict(req='ISP-03', case='median_k3_d8_pad1', top='median_stream',
      sources=['isp/median/median_stream.v', 'isp/median/median_network.v',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(WIDTH=32, HEIGHT=24, K=3, BITS=8, PAD_MODE=1)),
 dict(req='ISP-04', case='gradient_k3_d8_pad1', top='gradient_stream',
      sources=['isp/gradient/gradient_stream.v',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(WIDTH=32, HEIGHT=24, BITS=8, PAD_MODE=1)),
 dict(req='ISP-06', case='scale_poly6', top='scale_poly6_stream',
      sources=['isp/scale/scale_poly6_stream.v'],
      params=dict(MAX_W=1920), incdirs=['isp/scale']),
 # bounded-width variant: default MAX_W=1920 needs 141 BSRAM > 46 available;
 # MAX_W=64 is the representative small-frame config
 dict(req='ISP-06', case='scale_poly6_w64', top='scale_poly6_stream',
      sources=['isp/scale/scale_poly6_stream.v'],
      params=dict(MAX_W=64), incdirs=['isp/scale']),
 dict(req='ISP-07', case='bayer_b8_32x24', top='bayer_demosaic',
      sources=['isp/bayer/rtl/bayer_demosaic.sv',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(BITS=8, WIDTH=32, HEIGHT=24)),
 dict(req='ISP-08', case='basic_isp_b8_c3_32x24', top='basic_isp_top',
      sources=['isp/basic_isp/rtl/basic_isp_top.sv',
               'isp/basic_isp/rtl/isp_blc.sv',
               'isp/basic_isp/rtl/isp_wb_gain.sv',
               'isp/basic_isp/rtl/isp_dpc.sv',
               'isp/basic_isp/rtl/isp_gamma.sv',
               'isp/basic_isp/rtl/isp_awb_stats.sv',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(BITS=8, CH=3, WIDTH=32, HEIGHT=24),
      incdirs=['isp/basic_isp/rtl']),
 dict(req='ISP-09', case='cca_w64h64nl32eq64', top='cca_stream',
      sources=['isp/cca/rtl/cca_stream.sv'],
      params=dict(W_MAX=64, H_MAX=64, NL=32, EQT=64)),
 dict(req='ISP-10', case='integral_b8_32x24', top='integral_stats',
      sources=['isp/localstats/rtl/integral_stats.sv',
               'isp/localstats/rtl/adaptive_threshold.sv'],
      params=dict(BITS=8, MAX_W=32, MAX_H=24, WIN_W_MAX=15, WIN_H_MAX=15)),
 dict(req='ISP-10', case='adaptive_threshold', top='adaptive_threshold',
      sources=['isp/localstats/rtl/integral_stats.sv',
               'isp/localstats/rtl/adaptive_threshold.sv'],
      params=dict(BITS=8)),
 dict(req='ISP-11', case='histeq_b8_32x24', top='histeq_stream',
      sources=['isp/histeq/rtl/histeq_stream.sv'],
      params=dict(BITS=8, MAX_W=32, MAX_H=24)),
 dict(req='ISP-12', case='ispstats_b8_c3_32x24', top='ispstats_stream',
      sources=['isp/ispstats/rtl/ispstats_stream.sv'],
      params=dict(BITS=8, CH=3, MAX_W=32, MAX_H=24)),
 dict(req='ISP-13', case='lsc_b8', top='lsc_stream',
      sources=['isp/lsc/rtl/lsc_stream.sv'], params=dict(BITS=8)),
 dict(req='ISP-14', case='ccm_b8', top='ccm_stream',
      sources=['isp/ccm/rtl/ccm_stream.sv'], params=dict(BITS=8)),
 dict(req='ISP-15', case='chroma422_b8_32x24', top='chroma_422',
      sources=['isp/chroma/rtl/chroma_422.sv',
               'isp/chroma/rtl/chroma_420.sv', 'isp/chroma/rtl/pix_pack.sv'],
      params=dict(BITS=8, WIDTH=32, HEIGHT=24)),
 dict(req='ISP-15', case='chroma420_b8_32x24', top='chroma_420',
      sources=['isp/chroma/rtl/chroma_422.sv',
               'isp/chroma/rtl/chroma_420.sv', 'isp/chroma/rtl/pix_pack.sv'],
      params=dict(BITS=8, WIDTH=32, HEIGHT=24)),
 dict(req='ISP-15', case='chroma420v_b8_16x24', top='chroma420_v',
      sources=['isp/chroma/rtl/chroma_422.sv',
               'isp/chroma/rtl/chroma_420.sv', 'isp/chroma/rtl/pix_pack.sv'],
      params=dict(BITS=8, NCOLS=16, HEIGHT=24)),
 dict(req='ISP-15', case='pix_pack_b8', top='pix_pack',
      sources=['isp/chroma/rtl/chroma_422.sv',
               'isp/chroma/rtl/chroma_420.sv', 'isp/chroma/rtl/pix_pack.sv'],
      params=dict(BITS=8, NS=4, SLOT=0)),
 dict(req='ISP-16', case='canny_w32h24_d8', top='canny_stream',
      sources=['isp/canny/rtl/canny_stream.sv',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(BITS=8, WIDTH=32, HEIGHT=24, PAD_MODE=1, PASSES=4)),
 dict(req='ISP-17', case='framediff_b8_32x24', top='framediff_stream',
      sources=['isp/framediff/rtl/framediff_stream.sv'],
      params=dict(BITS=8, MAX_W=32, MAX_H=24)),
 dict(req='ISP-18', case='bilateral_b8_32x24', top='bilateral_stream',
      sources=['isp/bilateral/rtl/bilateral_stream.sv',
               'infra/fixedpoint/rtl/recip_div.sv',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(BITS=8, WIDTH=32, HEIGHT=24, PAD_MODE=1)),
 dict(req='ISP-19', case='remap_b8_32x24', top='remap_stream',
      sources=['isp/remap/rtl/remap_stream.sv',
               'infra/fixedpoint/rtl/recip_div.sv'],
      params=dict(BITS=8, MAX_W=32, MAX_H=24, LXMAX=9, LYMAX=9)),
 dict(req='DSP-09', case='dc_stream_v3', top='dc_stream',
      sources=['dsp/dc/rtl/dc_stream.sv'], params={}),
 dict(req='ISP-01', case='csc_b8', top='csc_stream',
      sources=['isp/csc_stream.v'], params=dict(BITS=8)),
 dict(req='ISP-05', case='morph_k3_b8', top='morphology_stream',
      sources=['isp/morphology/morphology_stream.v',
               'isp/morphology/morph_reduce.v',
               'infra/window/stream_window.v',
               'infra/window/stream_window_padded.v'],
      params=dict(BITS=8, WIDTH=8, HEIGHT=8, K=3, PAD_MODE=1)),
 dict(req='INFRA-02', case='window_k3_b8', top='stream_window',
      sources=['infra/window/stream_window.v'],
      params=dict(DATA_WIDTH=8, WIDTH=32, HEIGHT=24, K=3)),
 dict(req='INFRA-02', case='window_padded_k3_b8', top='stream_window_padded',
      sources=['infra/window/stream_window_padded.v',
               'infra/window/stream_window.v'],
      params=dict(DATA_WIDTH=8, WIDTH=32, HEIGHT=24, K=3)),
 dict(req='INFRA-01', case='stream_elastic_w16', top='stream_elastic',
      sources=['infra/stream/stream_elastic.v'], params=dict(DATA_WIDTH=16)),
 dict(req='INFRA-01', case='sync_fifo_w16d16', top='stream_sync_fifo',
      sources=['infra/stream/stream_sync_fifo.v'],
      params=dict(DATA_WIDTH=16, RAM_DEPTH=16)),
 dict(req='INFRA-01', case='stream_stats_u1', top='stream_stats',
      sources=['infra/stream/stream_stats.v'], params=dict(USER_WIDTH=1)),
 dict(req='INFRA-03', case='async_fifo_w16d16', top='async_stream_fifo',
      sources=['infra/asyncfifo/rtl/async_stream_fifo.sv',
               'infra/asyncfifo/rtl/stream_cdc_handshake.sv'],
      params=dict(WIDTH=16, DEPTH=16)),
 dict(req='INFRA-03', case='cdc_handshake_w16', top='stream_cdc_handshake',
      sources=['infra/asyncfifo/rtl/async_stream_fifo.sv',
               'infra/asyncfifo/rtl/stream_cdc_handshake.sv'],
      params=dict(WIDTH=16)),
 dict(req='INFRA-05', case='sat_round', top='sat_round',
      sources=['infra/fixedpoint/rtl/sat_round.sv'],
      params=dict(IN_W=32, OUT_W=16, SHIFT=15, SIGNED_IN=1)),
 dict(req='INFRA-05', case='cplx_mac', top='cplx_mac',
      sources=['infra/fixedpoint/rtl/cplx_mac.sv'],
      params=dict(DATA_W=16, ACC_W=48, OUT_W=32, SHIFT=0)),
 dict(req='INFRA-05', case='div_pipe', top='fp_div_pipe',
      sources=['infra/fixedpoint/rtl/recip_div.sv'],
      params=dict(AW=16, BW=16, FB=15, OUT_W=18)),
 dict(req='INFRA-05', case='sqrt_pipe', top='fp_sqrt_pipe',
      sources=['infra/fixedpoint/rtl/sqrt_unit.sv'],
      params=dict(IN_W=32, FB=8)),
 dict(req='INFRA-05', case='log2_iter', top='fp_log2_iter',
      sources=['infra/fixedpoint/rtl/log2exp2.sv'],
      params=dict(IN_W=16, FB=12, G=6, SIGNED_IN=0)),
 dict(req='INFRA-05', case='exp2_iter', top='fp_exp2_iter',
      sources=['infra/fixedpoint/rtl/log2exp2.sv'],
      params=dict(IW=16, FB=12, G=6, OUT_W=13, FRACO=6)),
 dict(req='INFRA-07', case='prbs_source', top='prbs_source',
      sources=['infra/testsrc/rtl/prbs_source.sv'], params={}),
 dict(req='INFRA-07', case='tone_source', top='tone_source',
      sources=['infra/testsrc/rtl/tone_source.sv'], params={}),
 dict(req='INFRA-07', case='image_pattern', top='image_pattern_source',
      sources=['infra/testsrc/rtl/image_pattern_source.sv'],
      params=dict(DATA_WIDTH=16, MAX_W=4096, MAX_H=4096)),
 dict(req='INFRA-07', case='backpressure_sink', top='backpressure_sink',
      sources=['infra/testsrc/rtl/backpressure_sink.sv'],
      params=dict(DATA_WIDTH=8)),
 dict(req='INFRA-07', case='crc32_w8', top='crc32',
      sources=['infra/testsrc/rtl/crc32.sv'], params=dict(DATA_WIDTH=8)),
 dict(req='INFRA-07', case='sink_checker', top='stream_sink_checker',
      sources=['infra/testsrc/rtl/stream_sink_checker.sv',
               'infra/testsrc/rtl/crc32.sv'], params={}),
]

CLK_RE = re.compile(r'clk|clock', re.I)
RST_RE = re.compile(r'rst|reset|areset|preset|clr_n?', re.I)


def run(cmd, cwd, logname, env):
    with open(Path(cwd) / logname, 'w') as log:
        r = subprocess.run([str(c) for c in cmd], cwd=cwd, env=env,
                           stdout=log, stderr=subprocess.STDOUT)
    if r.returncode:
        raise RuntimeError(f'{logname} rc={r.returncode}')


def dump_ports(spec, dest, env):
    inc = ''.join(f'verilog_defaults -add -I{libsrc(i)}; '
                  for i in spec.get('incdirs', []))
    read = ' '.join(f'read_verilog -sv "{libsrc(s)}";' for s in spec['sources'])
    chp = ''
    if spec.get('params'):
        chp = ('chparam ' + ' '.join(f'-set {k} {v}'
               for k, v in spec['params'].items()) + f' {spec["top"]};')
    script = f'{inc}{read} {chp} hierarchy -top {spec["top"]}; proc; write_json ports.json'
    run([YOSYS, '-Q', '-p', script], dest, 'port_dump.log', env)
    net = json.loads((dest / 'ports.json').read_text())
    mod = net['modules'].get(spec['top'])
    if mod is None:
        cand = [k for k in net['modules'] if spec['top'] in k]
        mod = net['modules'][cand[0]]
    return {n: (p['direction'], len(p['bits']))
            for n, p in mod['ports'].items()}


def gen_wrapper(spec, ports, dest):
    """Register-shell wrapper: LFSR-driven inputs, captured outputs."""
    lines = ['module pnr_top(input wire clk, input wire rst_n, output wire obs);',
             'reg [63:0] lfsr = 64\'h0123456789abcdef;',
             'always @(posedge clk) lfsr <= {lfsr[62:0],'
             ' lfsr[63]^lfsr[62]^lfsr[60]^lfsr[58]};']
    conns, caps = [], []
    idx = 0
    for name, (direction, width) in ports.items():
        if direction == 'input':
            if CLK_RE.fullmatch(name) or name in ('clk', 'clka', 'clkb'):
                conns.append(f'.{name}(clk)')
            elif RST_RE.fullmatch(name):
                conns.append(f'.{name}(rst_n)')
            else:
                reg = f'r{idx}'
                idx += 1
                lines.append(f'reg [{width - 1}:0] {reg};')
                if width == 1:
                    lines.append(f'always @(posedge clk) {reg} <= lfsr[{idx}];')
                else:
                    lines.append(f'genvar g{idx};')
                    lines.append(f'for (g{idx}=0; g{idx}<{width}; g{idx}=g{idx}+1)'
                                 f' always @(posedge clk)'
                                 f' {reg}[g{idx}] <= lfsr[(g{idx}+{idx * 13}) % 64];')
                conns.append(f'.{name}({reg})')
        elif direction == 'output':
            w = f'o{idx}'
            idx += 1
            lines.append(f'wire [{width - 1}:0] {w};')
            lines.append(f'reg [{width - 1}:0] {w}_r;')
            lines.append(f'always @(posedge clk) {w}_r <= {w};')
            conns.append(f'.{name}({w})')
            caps.append(f'{w}_r')
        else:
            raise RuntimeError(f'inout port {name} unsupported')
    param = ''
    if spec.get('params'):
        param = '#(' + ','.join(f'.{k}({v})' for k, v in spec['params'].items()) + ')'
    lines.append(f'{spec["top"]} {param} dut ({",".join(conns)});')
    lines.append(f'assign obs = ^{{{",".join(caps)}}};' if caps
                 else 'assign obs = lfsr[0];')
    lines.append('endmodule')
    text = '\n'.join(lines) + '\n'
    (dest / 'pnr_wrap.sv').write_text(text)
    return text


def cell_counts(net, top):
    """Cell counts grouped by module; dut = all modules except pnr_top."""
    per_mod = {}
    for mname, m in net['modules'].items():
        per_mod[mname] = collections.Counter(
            c['type'] for c in m['cells'].values())
    return per_mod


def summarize(counts):
    lut = sum(counts.get(f'LUT{i}', 0) for i in range(1, 5)) + counts.get('ALU', 0)
    ff = sum(v for k, v in counts.items() if k.startswith('DFF') or k in ('FF',))
    dsp = sum(v for k, v in counts.items() if k.startswith(('MULT', 'PADD', 'ALU54')))
    bram = sum(v for k, v in counts.items()
               if k.startswith(('DPX', 'SPX', 'SDPX', 'DPB', 'SPB', 'SDPB', 'DP', 'SP', 'SDP', 'ROM')))
    mux = sum(v for k, v in counts.items() if k.startswith('MUX'))
    return dict(lut1_4=lut, ff=ff, dsp=dsp, bram=bram, wide_mux=mux)


def audit(spec, env):
    base = LIB / spec['sources'][0]
    core_dir = base.parent.parent if base.parent.name == 'rtl' else base.parent
    outroot = core_dir / 'evidence' / ('pnr_' + datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    outroot.mkdir(parents=True)
    dest = outroot / spec['case']
    dest.mkdir()
    result = dict(req=spec['req'], case=spec['case'], top=spec['top'],
                  params=spec.get('params', {}),
                  sources=[str(LIB / s) for s in spec['sources']],
                  status='FAIL')
    try:
        ports = dump_ports(spec, dest, env)
        (dest / 'ports.json.json').unlink(missing_ok=True)
        gen_wrapper(spec, ports, dest)
        inc = ''.join(f'verilog_defaults -add -I{libsrc(i)}; '
                      for i in spec.get('incdirs', []))
        read = ' '.join(f'read_verilog -sv "{libsrc(s)}";' for s in spec['sources'])
        script = (f'{inc}{read} read_verilog -sv "pnr_wrap.sv"; '
                  f'synth_gowin -noalu -family gw2a -top pnr_top -json mapped.json; stat')
        (dest / 'build.ys').write_text(script + '\n')
        run([YOSYS, '-Q', '-s', 'build.ys'], dest, 'yosys.log', env)
        # synth_gowin flattens; count DUT cells from a dedicated DUT-only pass
        chp = ''
        if spec.get('params'):
            chp = ('chparam ' + ' '.join(f'-set {k} {v}'
                   for k, v in spec['params'].items()) + f' {spec["top"]};')
        script = (f'{inc}{read} {chp} synth_gowin -noalu -family gw2a '
                  f'-top {spec["top"]} -json dut.json')
        if spec.get('no_dut_pass'):
            dut = collections.Counter()
            result['resource_source'] = 'wrapper_upper_bound'
            result['dut_count_error'] = 'skipped by spec (design too large for second synth pass)'
        else:
          try:
            run([YOSYS, '-Q', '-p', script], dest, 'yosys_dut.log', env)
            dnet = json.loads((dest / 'dut.json').read_text())
            dmod = dnet['modules'].get(spec['top'])
            if dmod is None:
                cand = [k for k in dnet['modules'] if spec['top'] in k]
                dmod = dnet['modules'][cand[0]]
            dut = collections.Counter(c['type'] for c in dmod['cells'].values())
          except Exception as exc:
            # DUT-only counting pass is informational; wrapper P&R still runs.
            dut = collections.Counter()
            result['dut_count_error'] = repr(exc)
        wnet = json.loads((dest / 'mapped.json').read_text())
        wrapper = collections.Counter(c['type'] for c in
                                      wnet['modules']['pnr_top']['cells'].values())
        result['dut_cells'] = dict(dut)
        result['dut'] = summarize(dut)
        result['wrapper_total_cells'] = dict(wrapper)
        result['wrapper_total'] = summarize(wrapper)
        (dest / 'top.cst').write_text(
            'IO_LOC "clk" H11;\nIO_PORT "clk" PULL_MODE=NONE;\n'
            'IO_LOC "rst_n" T13;\nIO_LOC "obs" M11;\n')
        run([NEXTPNR, '--json', 'mapped.json', '--write', 'pnr.json',
             '--device', DEVICE, '--vopt', f'family={FAMILY}',
             '--vopt', 'cst=top.cst', '--freq', str(int(FREQ)),
             '--seed', '1', '--log', 'nextpnr.log'], dest, 'pnr_console.log', env)
        log = (dest / 'nextpnr.log').read_text(errors='replace')
        freqs = [float(x) for x in re.findall(
            r'Max frequency for clock[^\n]*?:\s*([\d.]+)\s*MHz', log)]
        util = re.search(r'Device utilisation:(.*?)\n\n', log, re.S)
        result['fmax_mhz'] = freqs
        result['fmax_min'] = min(freqs) if freqs else None
        if util:
            result['utilisation'] = util.group(1).strip()
        r4 = re.search(r'\bLUT4:\s+(\d+)', log)
        result['routed_lut4'] = int(r4.group(1)) if r4 else None
        res_source = dut if dut else wrapper
        gates = dict(lut_ok=summarize(res_source)['lut1_4'] <= 15000,
                     dsp_ok=summarize(res_source)['dsp'] <= 4,
                     timing_ok=(result['fmax_min'] is not None
                                and result['fmax_min'] >= FREQ))
        if not dut:
            result['resource_source'] = 'wrapper_upper_bound'
        result['gates'] = gates
        result['status'] = 'PASS' if all(gates.values()) else 'FAIL_GATE'
    except Exception as exc:
        result['error'] = repr(exc)
    (dest / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    (outroot / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--only', nargs='*')
    p.add_argument('--list', action='store_true')
    a = p.parse_args()
    if a.list:
        for s in SPECS:
            print(s['req'], s['case'], s['top'], s.get('params'))
        return
    env = os.environ.copy()
    env['PATH'] = (str(CAD / 'lib') + os.pathsep + str(CAD / 'bin') +
                   os.pathsep + env.get('PATH', ''))
    results = []
    for spec in SPECS:
        if a.only and spec['req'] not in a.only and spec['case'] not in a.only:
            continue
        r = audit(spec, env)
        results.append(r)
        print(json.dumps({k: r[k] for k in
                          ('req', 'case', 'status', 'error') if k in r},
                         ensure_ascii=False), flush=True)
        if 'dut' in r:
            print('   dut:', r['dut'], 'fmax:', r.get('fmax_min'),
                  'gates:', r.get('gates'), flush=True)
    n_pass = sum(1 for r in results if r['status'] == 'PASS')
    print(f'TOTAL {n_pass}/{len(results)} PASS')


if __name__ == '__main__':
    main()
