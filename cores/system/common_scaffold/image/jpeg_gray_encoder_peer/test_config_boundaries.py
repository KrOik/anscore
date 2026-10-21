"""Independent configuration recovery and nonuniform-DQT integration boundary."""
import io,json,hashlib,sys,tempfile
from pathlib import Path
from PIL import Image
H=Path(__file__).resolve().parent;P=H.parents[1];O=P/'image/jpeg_gray_encoder'
sys.path.insert(0,str(P/'integration'))
from tooling import execute
REL=['dsp/dct8x8/dct8x8_serial.sv','dsp/jpeg_quant_zigzag/jpeg_quant_zigzag.sv','dsp/jpeg_entropy/jpeg_baseline_symbols.v','dsp/jpeg_huffman/jpeg_default_huffman.sv','dsp/jpeg_bitstream/jpeg_entropy_bitpacker.sv','dsp/jpeg_scan_control/jpeg_entropy_scan_controller.v','dsp/jpeg_grayscale/jpeg_grayscale_scan.sv','dsp/jpeg_headers/jpeg_gray_headers.sv','image/raster_blocks/img_raster_blocks.v','image/jpeg_gray_encoder/jpeg_gray_encoder.sv']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
TB=r'''
`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,table_valid=0,cfg_valid=0,start_valid=0,abort=0;
reg[5:0]table_index=0;reg[7:0]table_value=0;reg[15:0]cfg_restart_interval=0;
wire table_ready,cfg_ready,cfg_done,cfg_error,start_ready,s_ready,m_valid,m_last,done_valid,busy;
reg[7:0]s_data=128;reg s_valid=0,s_sof=0,s_eol=0,m_ready=1,done_ready=0;
wire[7:0]m_data,error_code;
jpeg_gray_encoder #(.WIDTH(8),.HEIGHT(8))dut(.*);
integer fd,i,bytes=0,lasts=0;
always @(posedge clk)if(rst_n&&ce&&m_valid&&m_ready)begin $fdisplay(fd,"%02x",m_data);bytes=bytes+1;if(m_last)lasts=lasts+1;end
task tick;begin @(negedge clk);#1;end endtask
task write_q;input[5:0]idx;input[7:0]v;begin
 table_index=idx;table_value=v;table_valid=1;while(!table_ready)tick;tick;table_valid=0;
end endtask
task configure;input bad;input simultaneous;begin
 cfg_restart_interval=16'h1234;cfg_valid=1;
 if(simultaneous)begin table_valid=1;table_index=7;table_value=0;end
  #1;while(!cfg_ready)tick;
 if(table_ready)$fatal(1,"configuration must suppress table handshake");tick;cfg_valid=0;table_valid=0;cfg_restart_interval=16'hffff;
 while(!cfg_done)tick;
 if(cfg_error!==bad)$fatal(1,"config error expected%0d actual%0d",bad,cfg_error);
 tick;
end endtask
initial begin
 fd=$fopen("frame.hex","w");repeat(4)tick;rst_n=1;tick;
 // Missing table then explicit zero-value table failures must permit repair.
 configure(1,0);if(start_ready||s_ready||m_valid)$fatal(1,"unconfigured start");
 for(i=0;i<64;i=i+1)write_q(i,i==17?0:i+1);
 configure(1,0);if(start_ready||m_valid)$fatal(1,"zero quant configured");
 write_q(17,18);
 // The competing table write must not be accepted at the config handshake.
 configure(0,1);if(!start_ready)$fatal(1,"repair did not restore start");
 start_valid=1;tick;start_valid=0;
 for(i=0;i<64;i=i+1)begin s_valid=1;s_sof=i==0;s_eol=i%8==7;while(!s_ready)tick;tick;s_valid=0;end
 while(!done_valid)tick;
 if(error_code||lasts!=1)$fatal(1,"final frame status");
 $fclose(fd);$display("PASS JPEG PEER CONFIG_RECOVERY NONUNIFORM_DQT bytes%0d",bytes);$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''
def main():
 frozen=json.loads((O/'source_freeze.json').read_text(encoding='utf-8'));fs=sha(O/'source_freeze.json');sources={n:sha(P/n) for n in REL}
 for n,d in frozen.items():assert sha(O/n)==d,n
 with tempfile.TemporaryDirectory(prefix='jpeg_config_peer_') as tmp:
  w=Path(tmp);(w/'tb.sv').write_text(TB,encoding='utf-8')
  execute(['iverilog','-g2012','-s','tb','-o',w/'sim',*[P/n for n in REL],w/'tb.sv'],w,H/'compile.log')
  out=execute(['vvp',w/'sim'],w,H/'simulation.log');assert 'PASS JPEG PEER CONFIG_RECOVERY' in out
  data=bytes.fromhex((w/'frame.hex').read_text(encoding='ascii'));assert data.startswith(b'\xff\xd8\xff\xe0\x00\x10JFIF\x00') and data.endswith(b'\xff\xd9')
  # Generate the standard zigzag order algorithmically, independent of RTL LUTs.
  zig=[]
  for diagonal in range(15):
   coords=[(r,diagonal-r) for r in range(8) if 0<=diagonal-r<8]
   if diagonal%2==0:coords.reverse()
   zig.extend(8*r+c for r,c in coords)
  pos=data.index(b'\xff\xdb');size=int.from_bytes(data[pos+2:pos+4],'big');assert size==67 and data[pos+4]==0
  assert list(data[pos+5:pos+69])==[v+1 for v in zig]
  dri=data.index(b'\xff\xdd');assert data[dri+2:dri+6]==b'\x00\x04\x12\x34'
  with Image.open(io.BytesIO(data)) as image:image.load();assert image.size==(8,8) and image.mode=='L' and set(image.tobytes())=={128}
 for n,d in frozen.items():assert sha(O/n)==d,n
 assert sources=={n:sha(P/n) for n in REL}
 report=dict(status='PASS',source_freeze_sha256=fs,owner_frozen_inputs=frozen,sources=sources,script_sha256=sha(Path(__file__)),output=out,decoded_pixels=64,jpeg_bytes=len(data),jpeg_sha256=hashlib.sha256(data).hexdigest(),quantization_natural=list(range(1,65)),dri=4660,logs={p.name:sha(p) for p in H.glob('*.log')},board_tested=False)
 (H/'boundary_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print('PASS JPEG CONFIG PEER',len(data))
if __name__=='__main__':main()
