from run_tests import *
PARAM_TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,cadence_tick=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,running,done_valid;reg m_ready=0,done_ready=0;wire[7:0]m_pixel,error_code;wire[31:0]m_frame_id,published_count,output_count,dropped_count,repeated_count,underrun_count,tick_overrun_count;
video_frame_rate_converter #(.PIXEL_W(@PW@),.MAX_WIDTH(@MW@),.MAX_HEIGHT(@MH@))dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.abort(abort),.cadence_tick(cadence_tick),.start_ready(start_ready),.cfg_width(16'd@W@),.cfg_height(16'd@H@),.cfg_rate_num(16'd@NUM@),.cfg_rate_den(16'd@DEN@),.s_pixel(0),.s_valid(1'b0),.s_sof(1'b0),.s_eol(1'b0),.s_last(1'b0),.s_ready(s_ready),.m_pixel(m_pixel),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_frame_id(m_frame_id),.running(running),.done_valid(done_valid),.done_ready(done_ready),.error_code(error_code),.published_count(published_count),.output_count(output_count),.dropped_count(dropped_count),.repeated_count(repeated_count),.underrun_count(underrun_count),.tick_overrun_count(tick_overrun_count));
initial begin repeat(3)@(negedge clk);rst_n=1;start_valid=1;@(negedge clk);start_valid=0;
if(!done_valid||error_code!=1||running||m_valid||s_ready)$fatal(1,"invalid parameter accepted");ce=0;done_ready=1;repeat(4)@(negedge clk);if(!done_valid)$fatal(1,"CEdone");ce=1;@(negedge clk);if(!start_ready)$fatal(1,"done ack");
rst_n=0;@(negedge clk);if(done_valid||running||m_valid)$fatal(1,"reset");$display("PASS FRC PARAM");$finish;end endmodule'''
def main():
 rows=[];cases=[dict(W=0),dict(H=0),dict(W=9),dict(H=9),dict(NUM=0),dict(DEN=0),dict(NUM=4,DEN=3),dict(PW=0),dict(PW=33),dict(MW=0),dict(MH=0),dict(MW=257),dict(MH=257),dict(MW=256,MH=256),dict(PW=32,MW=64,MH=64)]
 for i,case in enumerate(cases):
  profile=dict(PW=8,MW=8,MH=8,W=4,H=3,NUM=1,DEN=2);profile.update(case);tb=PARAM_TB
  for k,v in profile.items():tb=tb.replace('@'+k+'@',str(v))
  with tempfile.TemporaryDirectory(prefix='video_frc_param_') as td:
   p=Path(td);(p/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',RTL,p/'tb.sv'],H,H/f'param_{i}_compile.log');out=execute(['vvp',p/'sim'],H,H/f'param_{i}_simulation.log');assert 'PASS FRC PARAM' in out;rows.append(dict(profile=profile,status='PASS'))
 (H/'parameter_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n');print('PASS FRC15 invalid profiles')
if __name__=='__main__':main()
