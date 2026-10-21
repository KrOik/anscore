"""Independent hand-calculated frame-bank and host-stall review of the FRC."""
import argparse
import hashlib
import json
import tempfile
from pathlib import Path

from tooling import PACKAGE, ROOT, evidence_dir, execute, write_json


TB = r'''
`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,cadence_tick=0,done_ready=0;
reg [7:0] s_pixel=0; reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,running,done_valid;
wire [7:0] m_pixel,error_code;
wire [31:0] m_frame_id,published_count,output_count,dropped_count,repeated_count,underrun_count,tick_overrun_count;
video_frame_rate_converter #(.PIXEL_W(8),.MAX_WIDTH(2),.MAX_HEIGHT(1)) d(
 .clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.abort(abort),
 .cadence_tick(cadence_tick),.start_ready(start_ready),.cfg_width(16'd2),.cfg_height(16'd1),
 .cfg_rate_num(16'd1),.cfg_rate_den(16'd1),.s_pixel(s_pixel),.s_valid(s_valid),
 .s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),.s_last(s_last),
 .m_pixel(m_pixel),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol),
 .m_last(m_last),.m_frame_id(m_frame_id),.running(running),.done_valid(done_valid),
 .done_ready(done_ready),.error_code(error_code),.published_count(published_count),
 .output_count(output_count),.dropped_count(dropped_count),.repeated_count(repeated_count),
 .underrun_count(underrun_count),.tick_overrun_count(tick_overrun_count));
integer accepted=0,hold_cycles=0;
reg held=0; reg [42:0] held_value;
always @(posedge clk) if(rst_n)begin
 if(held && {m_frame_id,m_sof,m_eol,m_last,m_pixel}!==held_value)
  $fatal(1,"held output changed");
 if(held&&!m_valid)$fatal(1,"held valid withdrawn");
 held<=m_valid&&!(ce&&m_ready);
 held_value<={m_frame_id,m_sof,m_eol,m_last,m_pixel};
 if(m_valid&&!(ce&&m_ready))hold_cycles<=hold_cycles+1;
 if(m_valid&&ce&&m_ready)begin
  case(accepted)
   0:if(m_pixel!==30||m_frame_id!==2)$fatal(1,"first bank");
   1:if(m_pixel!==31||m_frame_id!==2)$fatal(1,"protected bank last");
   2,4:if(m_pixel!==50||m_frame_id!==4)$fatal(1,"latest/repeat first");
   3,5:if(m_pixel!==51||m_frame_id!==4)$fatal(1,"latest/repeat last");
   default:$fatal(1,"unexpected pixel");
  endcase
  if(m_sof!==(accepted%2==0)||m_eol!==(accepted%2==1)||m_last!==(accepted%2==1))
   $fatal(1,"frame markers");
  accepted<=accepted+1;
 end
end
task frame; input integer value;begin
 @(negedge clk);s_valid=1;s_sof=1;s_eol=0;s_last=0;s_pixel=value;
 @(posedge clk);if(!s_ready)$fatal(1,"input blocked");
 @(negedge clk);s_sof=0;s_eol=1;s_last=1;s_pixel=value+1;
 @(posedge clk);if(!s_ready)$fatal(1,"input last blocked");
 @(negedge clk);s_valid=0;s_eol=0;s_last=0;
end endtask
task tick;begin @(negedge clk);cadence_tick=1;@(negedge clk);cadence_tick=0;end endtask
initial begin
 repeat(3)@(posedge clk);@(negedge clk);rst_n=1;start_valid=1;
 @(negedge clk);start_valid=0;
 frame(10);frame(20);frame(30);
 if(published_count!=3||dropped_count!=2)$fatal(1,"immediate replacement accounting");
 tick();wait(m_valid);@(negedge clk);
 frame(40);frame(50);
 if(dropped_count!=3||m_pixel!==30||m_frame_id!==2)$fatal(1,"active bank overwritten");
 ce=0;m_ready=1;tick();repeat(4)@(negedge clk);
 if(accepted!=0||tick_overrun_count!=1)$fatal(1,"CE-independent tick/held host");
 ce=1;wait(output_count==1);@(negedge clk);m_ready=0;
 tick();wait(m_valid);@(negedge clk);m_ready=1;
 wait(output_count==2);@(negedge clk);m_ready=0;
 tick();wait(m_valid);@(negedge clk);m_ready=1;
 wait(output_count==3);@(negedge clk);m_ready=0;
 if(accepted!=6||published_count!=5||dropped_count!=3||repeated_count!=1||underrun_count!=0)
  $fatal(1,"final accounting");
 abort=1;@(negedge clk);abort=0;wait(done_valid);@(negedge clk);
 if(error_code!=9||running||hold_cycles<10)$fatal(1,"abort boundary");
 $display("PASS FRC_PEER pixels=%0d held=%0d pub=%0d drop=%0d repeat=%0d",accepted,hold_cycles,published_count,dropped_count,repeated_count);$finish;
end
initial begin #100000;$fatal(1,"watchdog");end
endmodule
'''


def main(folder):
    folder.mkdir(parents=True, exist_ok=True)
    source = PACKAGE/'image/video_frame_rate_converter/video_frame_rate_converter.sv'
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='frc_root_peer_') as tmp:
        p = Path(tmp)
        (p/'tb.sv').write_text(TB, encoding='utf-8')
        execute(['iverilog', '-g2012', '-s', 'tb', '-o', p/'sim', source, p/'tb.sv'], ROOT, folder/'frc_peer_compile.log')
        out = execute(['vvp', p/'sim'], ROOT, folder/'frc_peer_simulation.log')
        assert 'PASS FRC_PEER' in out
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before, 'RTL changed during review'
    write_json(folder/'frc_peer_directed_evidence.json', dict(status='PASS', source_sha256=before,
               reviewer_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               scope='Independent hand-calculated complete frames, immediate drop counts, pinned active bank, CE-independent due, held token, repeat and abort; no board claim'))
    print(out.strip())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path, nargs='?')
    args = parser.parse_args()
    main(args.evidence.resolve() if args.evidence else evidence_dir('frc_root_peer'))
