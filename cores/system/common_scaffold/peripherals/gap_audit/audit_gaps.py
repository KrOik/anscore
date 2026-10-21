"""Read-only repository capability inventory. Does not simulate or certify IP."""
from pathlib import Path
import hashlib,json,re,subprocess,datetime
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
EXCLUDES=['**/build*/**','**/evidence/**','**/board/**','**/scratch/**','**/*netlist*','**/ila*/**','**/.git/**']
FILES={
 'spi_slave':'cores/system/ip_series/src/ips_spi_slave_reg.v',
 'spi_fixture':'cores/communication/primitives/src/spi_slave_model.v',
 'i2s_stereo_rx':'cores/system/ip_series/src/ips_i2s_rx_slave.v',
 'i2s_stereo_tx':'cores/system/ip_series/src/ips_i2s_tx_master.v',
 'i2s_8ch_rx':'projects/micarry_audio_capture_20k/src/micarry_i2s_slots.v',
 'i2s_7ch_rx':'projects/micarry_channel_map_20k/src/micarry_i2s_rx.v',
 'i2s_named_stub_real_rx':'cores/acquisition/micarray_doa/src/i2s_quad_rx_stub.v',
 'i2s_readable_reference':'references/Sped0n_eko/verilog/eko.srcs/design/i2s/i2s_recv.v',
 'tdm_scalar_demux':'cores/acceleration/operator_library/rtl/acc_tdm8_demux.v',
 'timer_capture':'cores/system/ip_series/src/ips_timer4_pwm_cap.v',
 'pulse_monitor':'cores/system/ip_series/src/ips_glitch_detector.v',
 'gate_frequency_fragment':'cores/system/extended_library/src/top_tapedbg.v',
 'iq_phase_frequency':'cores/signal_processing/dsp_isp_library/dsp/hilbert/rtl/phase_freq.sv',
 'onewire_byte_master':'cores/system/ip_series/src/ips_one_wire_master.v',
 'onewire_slot_kernel':'cores/acceleration/operator_library/rtl/acc_onewire_slot.v',
}
PATTERNS={
 'module_names':r'(?im)^\s*(?:module|entity)\s+\w*(?:spi.*slave|i2s|tdm|servo|freq|period|capture|one_?wire|ds18)\w*',
 'protocol_keywords':r'(?i)\b(?:ds18b20|search_?rom|match_?rom|read_?rom|period_count|period_ticks|high_ticks|servo|frequency_counter)\b',
}
def main():
 args=['rg','--files','-g','*.v','-g','*.sv','-g','*.vhd','-g','*.vhdl']
 for pattern in EXCLUDES:args.extend(['-g','!'+pattern])
 paths=subprocess.check_output(args,cwd=ROOT,text=True).splitlines()
 examined=[];excluded_encrypted=[];hits={k:[] for k in PATTERNS}
 for name in paths:
  f=ROOT/name;blob=f.read_bytes();text=blob.decode('utf-8','replace')
  if 'pragma protect' in text.lower() or 'pragma protect' in text.lower().replace('`',''):
   excluded_encrypted.append(name);continue
  examined.append((name.replace('\\','/'),hashlib.sha256(blob).hexdigest()))
  for group,pattern in PATTERNS.items():
   for match in re.finditer(pattern,text):
    hits[group].append(dict(path=name.replace('\\','/'),line=text.count('\n',0,match.start())+1,match=match.group(0).strip()))
 inventory={}
 for label,name in FILES.items():
  blob=(ROOT/name).read_bytes();inventory[label]=dict(path=name,sha256=hashlib.sha256(blob).hexdigest(),lines=len(blob.splitlines()))
 duplicates=[]
 for label,name in FILES.items():
  digest=inventory[label]['sha256'];same=[n for n,h in examined if h==digest and n!=name]
  if same:duplicates.append(dict(primary=name,identical_sources=same))
 rows=[
  dict(capability='true SPI slave',status='PRESENT_DO_NOT_DUPLICATE',evidence=['spi_slave'],remaining='Optional generic host-stream FIFO interface and independent asynchronous-pin timing verification; existing register slave is real.',priority='Do not create another same-function slave'),
  dict(capability='I2S stereo RX/TX',status='PRESENT_DO_NOT_DUPLICATE',evidence=['i2s_stereo_rx','i2s_stereo_tx'],remaining='Review and normalize existing stream contracts before reuse; this audit is not a correctness certification.',priority='Reuse existing'),
  dict(capability='parallel multi-lane multi-channel I2S RX',status='PRESENT_FIXED_PROFILE',evidence=['i2s_8ch_rx','i2s_7ch_rx','i2s_named_stub_real_rx'],remaining='Configurable lanes/sample width/stream buffering, TX counterpart; retain real existing capture code despite stub suffix.',priority='P1 enhancement'),
  dict(capability='single-serial-wire multichannel TDM RX/TX',status='NO_GENERAL_PIN_LEVEL_CORE_FOUND',evidence=['tdm_scalar_demux','i2s_stereo_tx'],remaining='Frame-sync/BCLK/serial data RX and TX; 2/4/8/16 slots, 16/24/32 sample bits, I2S/left-justified/DSP-A/B alignment; physical clock independent of host CE; FIFO/underflow/overrun/frame errors.',priority='P0'),
  dict(capability='PWM input / RC-servo high-and-period measurement',status='PARTIAL_CAPTURE_EXISTS_FULL_APPLICATION_MISSING',evidence=['timer_capture','pulse_monitor'],remaining='Reusable 24/32-bit synchronized input capture, high/low/period coherent output, timeout/stuck flags, optional RC-servo range checks, stable host ready/valid. Avoid rewriting PWM generator.',priority='P0'),
  dict(capability='frequency / reciprocal period counter',status='PARTIAL_INLINE_GATE_COUNTER_EXISTS',evidence=['gate_frequency_fragment','iq_phase_frequency'],remaining='Standalone parameterized reciprocal period and gate-frequency measurement, coherent CDC snapshot when needed, no-edge timeout/overflow, rearm and host stable output. IQ phase differentiation is not an input-edge counter.',priority='P1; share capture frontend with PWM measurement'),
  dict(capability='1-Wire reset/byte/CRC master',status='PRESENT_DO_NOT_REDUCE_TO_SLOT_KERNEL',evidence=['onewire_byte_master','onewire_slot_kernel'],remaining='Reuse byte-master interfaces where suitable, review tick/CE timing and parameter validity before integration.',priority='Reuse existing'),
  dict(capability='1-Wire ROM enumeration / DS18B20 transaction scheduler',status='NO_COMPLETE_CONTROLLER_FOUND',evidence=['onewire_byte_master','onewire_slot_kernel'],remaining='ROM read/match/skip/search with discrepancy traversal and ROM CRC; reset/presence -> ROM select -> Convert T -> busy/timeout -> reset/select -> Read Scratchpad 9 bytes + CRC -> signed temperature. Explicit externally-powered vs parasite-power/strong-pullup scope.',priority='P1; ROM search optional separate extension'),
 ]
 report=dict(status='AUDIT_COMPLETE_NOT_VERIFICATION',date_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),root=str(ROOT),scope='Read-only actual RTL capability and duplicate audit; no new RTL, no compilation/simulation/board claims.',excluded_patterns=EXCLUDES,scanned_readable_files=len(examined),encrypted_files_excluded=len(excluded_encrypted),inventory=inventory,identical_source_copies=duplicates,search_hits=hits,capabilities=rows,absence_limit='No matching complete controller found in this readable-source snapshot; keyword search plus manual implementation review is evidence of current inventory, not a proof against obfuscated/unrelated names.')
 (HERE/'gap_audit.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
 print('PASS read-only inventory:',len(examined),'readable files;',len(inventory),'manually reviewed canonical sources;',len(rows),'capability decisions')
if __name__=='__main__':main()
