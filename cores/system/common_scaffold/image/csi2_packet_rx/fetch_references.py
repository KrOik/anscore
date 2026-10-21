"""Retrieve small pinned mature sources; keep hashes/excerpts, no downloads."""
from pathlib import Path
import concurrent.futures,datetime,hashlib,json,subprocess,tempfile
HERE=Path(__file__).resolve().parent
ENTRIES=[
 ('CSI2Rx_header_ecc','https://cdn.jsdelivr.net/gh/gatecat/CSI2Rx@582f870d31404f58fffa557459b4c0dbd9b85937/verilog_cores/csi/header_ecc.v',['ecc[7:6]','ecc[5]','ecc[0]']),
 ('Linux_packet_ecc_crc','https://cdn.jsdelivr.net/gh/torvalds/linux@v6.12/drivers/gpu/drm/sun4i/sun6i_mipi_dsi.c',['ecc_array','crc_ccitt','sun6i_dsi_ecc_compute']),
 ('Linux_CSI2_data_types','https://cdn.jsdelivr.net/gh/torvalds/linux@v6.12/include/media/mipi-csi2.h',['FRAME_START','LINE_START','GENERIC_SHORT','RAW10','RGB888']),
 ('CSI2Rx_packet_handler','https://cdn.jsdelivr.net/gh/gatecat/CSI2Rx@582f870d31404f58fffa557459b4c0dbd9b85937/verilog_cores/csi/rx_packet_handler.v',['packet_type','word_count','header_ecc'])]
def fetch(entry):
 name,url,keys=entry
 with tempfile.TemporaryDirectory(prefix='csi2_packet_reference_') as tmp:
  dest=Path(tmp)/'reference.txt'
  r=subprocess.run(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','30','-o',str(dest),url],capture_output=True)
  if r.returncode:raise RuntimeError(name+': '+r.stderr.decode(errors='replace'))
  data=dest.read_bytes();lines=data.decode(errors='replace').splitlines();hits=[i for i,line in enumerate(lines) if any(k.lower() in line.lower() for k in keys)]
  return dict(name=name,url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),excerpts=[dict(line=i+1,text='\n'.join(lines[max(0,i-1):i+5])) for i in hits[:8]],use='Original RTL; mathematical ECC parity sets, header VC/DT/WC and reflected CRC conventions reviewed. Linux sun6i is a mature DSI implementation sharing the packet ECC/CRC algorithm, not evidence of a CSI-2 physical receiver. No third-party implementation source copied.')
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(fetch,ENTRIES))
 (HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(json.dumps([{k:v for k,v in row.items() if k!='excerpts'} for row in rows],indent=2))
