from run_tests import *
def main():
 rows=[]
 for depth in [2,3,7,1024,4096]:
  for mode in [0,1]:rows.append(run_case(f'fifo_{depth}_{mode}',7,5,mode,flow=False,period=1,depth=depth))
 def expand(v):
  r=(v>>11)&31;g=(v>>5)&63;b=v&31
  return ((r<<3|r>>2)<<16)|((g<<2|g>>4)<<8)|(b<<3|b>>2)
 for be in [False,True]:rows.append(run_case(f'all_rgb565_{be}',256,256,1,be,period=1,flow=False,pixels=[expand(v) for v in range(65536)]))
 for w,h in [(4096,1),(1,4096)]:rows.append(run_case(f'geometry_{w}_{h}',w,h,period=1,flow=False,mw=4096,mh=4096))
 rows.append(run_case('max_blank_and_period',1,1,hb=4096,vb=1,period=2,flow=False))
 rows.append(run_case('vblank4096',1,1,hb=1,vb=4096,period=1,flow=False))
 rows.append(run_case('period4096',1,1,hb=1,vb=1,period=4096,flow=False))
 invalid=[('width0',0,1,640,480,3,1,1,1),('widthover',641,1,640,480,3,1,1,1),('height0',1,0,640,480,3,1,1,1),('heightover',1,481,640,480,3,1,1,1),('maxwidth0',1,1,0,480,3,1,1,1),('maxheight4097',1,1,640,4097,3,1,1,1),('fifo1',1,1,640,480,1,1,1,1),('fifo4097',1,1,640,480,4097,1,1,1),('hblank0',1,1,640,480,3,0,1,1),('hblank4097',1,1,640,480,3,4097,1,1),('vblank0',1,1,640,480,3,1,0,1),('vblank4097',1,1,640,480,3,1,4097,1),('period0',1,1,640,480,3,1,1,0),('period4097',1,1,640,480,3,1,1,4097)]
 for name,w,h,mw,mh,fd,hb,vb,per in invalid:
  tb=f'''module tb;reg clk=0;always #5 clk=~clk;reg rst_n=0;wire done_valid,frame_error;wire[7:0]error_code;wire sample_valid;
 dvp_tx #(.MAX_WIDTH({mw}),.MAX_HEIGHT({mh}),.FIFO_DEPTH({fd}))dut(.clk(clk),.rst_n(rst_n),.ce(1'b1),.start_valid(1'b1),.abort(1'b0),.cfg_width(16'd{w}),.cfg_height(16'd{h}),.cfg_mode(1'b0),.cfg_big_endian(1'b0),.cfg_vsync_active_high(1'b1),.cfg_href_active_high(1'b1),.cfg_hblank(16'd{hb}),.cfg_vblank_lines(16'd{vb}),.cfg_byte_period(16'd{per}),.s_pixel(24'b0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.done_ready(1'b0),.done_valid(done_valid),.frame_error(frame_error),.error_code(error_code),.sample_valid(sample_valid));
 initial begin #12;rst_n=1;#40;if(!done_valid||!frame_error||error_code!=1||sample_valid)$fatal(1,"invalid");$display("PASS INVALID");$finish;end endmodule'''
  with tempfile.TemporaryDirectory(prefix='dvp_tx_parameter_') as td:
   d=Path(td);(d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'));out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'));assert 'PASS INVALID' in out
  rows.append(dict(name=name,status='PASS',expected_error=1))
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),cases=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
