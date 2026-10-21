"""Small ISP group regression with independent integer reference equations.

Run from any directory: python .../image/pipelines/run_group_regression.py
The generated bench and full tool transcripts remain in a new timestamped
directory. This is a functional integration check, not synthesis/board QA.
"""
from __future__ import annotations
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
IMAGE = HERE.parent
ROOT = HERE.parents[3]


BENCH = r'''
`timescale 1ns/1ps
module bayer_case #(parameter B=8)(output reg done=0);
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=0;integer cycle=0;
reg cfg=0;wire cfg_ready;reg [15:0] w=5,h=5;reg [1:0] pat=0;
wire rsp;reg rsp_ready=0;wire[3:0] err;wire[15:0] ow,oh;
reg[B-1:0] sd=0;reg sv=0,ss=0,se=0;wire sr;
wire[23:0] md;wire mv,ms,me,mf;reg mr=0;
integer frame=0,received=0,i,x,y;reg bad_tag=0;
reg[B-1:0] pixels[0:24];reg[23:0] hold_data;reg[2:0] hold_tags;reg held=0;
img_bayer_window_frontend_draft #(.RAW_BITS(B),.MAX_WIDTH(8)) dut(
 .clk(clk),.rst_n(rst),.clk_en(ce),.cfg_valid(cfg),.cfg_ready(cfg_ready),
 .cfg_width(w),.cfg_height(h),.cfg_pattern(pat),.rsp_valid(rsp),.rsp_ready(rsp_ready),
 .rsp_error(err),.out_width(ow),.out_height(oh),.s_data(sd),.s_valid(sv),.s_sof(ss),.s_eol(se),
 .s_ready(sr),.m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_eof(mf),.m_ready(mr));
always @(negedge clk) begin cycle=cycle+1;ce=(cycle%5!=1);mr=(cycle%7!=2 && cycle%7!=3);end
function[23:0] reference;
 input integer n;integer cx,cy,site,r,g,b,crossv,diag,horiz,vert,centre;
 begin cx=1+n%3;cy=1+n/3;site=((cy%2)*2+cx%2)^pat;
 centre=pixels[cy*5+cx];
 crossv=(pixels[(cy-1)*5+cx]+pixels[cy*5+cx-1]+pixels[cy*5+cx+1]+pixels[(cy+1)*5+cx]+2)/4;
 diag=(pixels[(cy-1)*5+cx-1]+pixels[(cy-1)*5+cx+1]+pixels[(cy+1)*5+cx-1]+pixels[(cy+1)*5+cx+1]+2)/4;
 horiz=(pixels[cy*5+cx-1]+pixels[cy*5+cx+1]+1)/2;
 vert=(pixels[(cy-1)*5+cx]+pixels[(cy+1)*5+cx]+1)/2;
 case(site)0:begin r=centre;g=crossv;b=diag;end
 1:begin r=horiz;g=centre;b=vert;end
 2:begin r=vert;g=centre;b=horiz;end
 default:begin r=diag;g=crossv;b=centre;end endcase
 reference={8'(r>>(B-8)),8'(g>>(B-8)),8'(b>>(B-8))};end
endfunction
always @(posedge clk) if(rst)begin
 if(held && (!mv || md!==hold_data || {ms,me,mf}!==hold_tags))$fatal(1,"Bayer %0d unstable output",B);
 held=mv && (!ce || !mr);hold_data=md;hold_tags={ms,me,mf};
 if(ce && mv && mr)begin
  if(received>=9 || md!==reference(received))$fatal(1,"Bayer B=%0d frame=%0d n=%0d got=%h want=%h",B,frame,received,md,reference(received));
  if(ms!==(received==0) || me!==(received%3==2) || mf!==(received==8))$fatal(1,"Bayer tags");
  received=received+1;
 end
 if(rsp && received!=9 && w==5)$fatal(1,"Bayer response preceded final RGB");
end
task configure;
 begin @(negedge clk);cfg=1;do @(posedge clk);while(!(ce && cfg_ready));@(negedge clk);cfg=0;end
endtask
task send;
 input integer n;
 begin @(negedge clk);sd=pixels[n];ss=(n==0);se=(n%5==4) ^ (bad_tag && n==3);sv=1;
 do @(posedge clk);while(!(ce && sr));@(negedge clk);sv=0;end
endtask
task response;
 input integer expected;
 begin wait(rsp);if(err!==expected)$fatal(1,"Bayer response %0d want %0d",err,expected);
 repeat(4)@(posedge clk);if(!rsp)$fatal(1,"Bayer response did not hold");
 @(negedge clk);rsp_ready=1;do @(posedge clk);while(!ce);@(negedge clk);rsp_ready=0;end
endtask
initial begin
 repeat(3)@(negedge clk);rst=1;
 for(frame=0;frame<5;frame=frame+1)begin
  pat=frame%4;bad_tag=(frame==4);received=0;
  for(i=0;i<25;i=i+1)pixels[i]=(i*i*13+(i%5)*63+(i/5)*29+frame*17)&((1<<B)-1);
  configure;for(i=0;i<25;i=i+1)send(i);response(bad_tag?2:0);
  if(ow!=3 || oh!=3)$fatal(1,"Bayer dimensions");
 end
 w=2;configure;response(1);done=1;$display("Bayer RAW%0d all phases/tag/error PASS",B);
end
endmodule

module solver_case(output reg done=0);
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=0;integer cycle=0;
always @(negedge clk)begin cycle=cycle+1;ce=(cycle%4!=0);end
reg sv=0,overflow=0;wire sr;reg[15:0] r=0,g=0,b=0,lo=0,hi=0;reg[31:0] count=0,id=0;
wire gv;reg gr=0;wire[15:0] rr,gg,bb;wire[31:0] fid;wire[7:0] error;
img_isp_awb_autogain #(.SUM_WIDTH(16)) dut(
 .clk(clk),.rst_n(rst),.clk_en(ce),.stats_valid(sv),.stats_ready(sr),.stats_sum_r(r),.stats_sum_g(g),.stats_sum_b(b),
 .stats_pixel_count(count),.stats_frame_id(id),.stats_overflow(overflow),.cfg_min_gain(lo),.cfg_max_gain(hi),
 .gain_valid(gv),.gain_ready(gr),.gain_r(rr),.gain_g(gg),.gain_b(bb),.gain_frame_id(fid),.gain_error(error));
task run;
 input integer ir,ig,ib,ic,il,ih,io,er,eg,eb,ee;
 begin
 @(negedge clk);r=ir;g=ig;b=ib;count=ic;lo=il;hi=ih;overflow=io;sv=1;
 do @(posedge clk);while(!(ce && sr));@(negedge clk);sv=0;
 wait(gv);repeat(5)begin @(posedge clk);if(!gv || rr!==er || gg!==eg || bb!==eb || error!==ee || fid!==id)
 $fatal(1,"AWB solver got %0d/%0d/%0d e%0d want %0d/%0d/%0d e%0d",rr,gg,bb,error,er,eg,eb,ee);end
 @(negedge clk);gr=1;do @(posedge clk);while(!ce);@(negedge clk);gr=0;id=id+1;
 end
endtask
initial begin repeat(3)@(negedge clk);rst=1;
 run(30,60,90,1,0,1024,0,512,256,170,0);
 run(30,60,90,1,200,400,0,400,256,200,0);
 run(0,0,0,4,0,1024,0,256,256,256,0);
 run(0,60,90,1,0,1024,0,1024,213,142,8);
 run(65535,1,1,1,0,65535,0,85,65535,65535,0);
 run(1,2,3,0,0,1024,0,256,256,256,1);
 run(1,2,3,1,0,1024,1,256,256,256,2);
 run(1,2,3,1,400,200,0,256,256,256,4);
 done=1;$display("AWB hardware divider/config/error/CE/hold PASS");end
endmodule

module pipeline_case(output reg done=0);
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=0,mr=0;integer cycle=0;
always @(negedge clk)begin cycle=cycle+1;ce=(cycle%5!=0);mr=(cycle%7!=1 && cycle%7!=2);end
reg[23:0] sd=0;reg sv=0,ss=0,se=0;wire sr;
wire[23:0] md;wire mv,ms,me;
reg flush=0;wire flush_ready;
wire[15:0] gainr,gaing,gainb;wire[31:0] aframe;wire[7:0] awe;wire awpending;
reg cwe=0;reg[3:0] ci=0;reg signed[15:0] cv=0;wire cr;
reg awecfg=0;reg signed[9:0] bright=0;reg[15:0] contrast=256;wire ar;
reg gwe=0;reg[7:0] ga=0,gd=0;reg gen=0;wire gready;wire[2:0] complete;
reg commit=0;wire commit_ready;wire[3:0] pending;wire error,active;
integer got=0,i;reg configured=0;reg[23:0] expected[0:11];reg[23:0] hd;reg[1:0] ht;reg held=0;
img_color_pipeline_auto #(.OUTPUT_YCBCR(1),.AWB_SUM_WIDTH(16)) dut(
 .clk(clk),.rst_n(rst),.clk_en(ce),.s_data(sd),.s_valid(sv),.s_sof(ss),.s_eol(se),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr),
 .stats_flush(flush),.stats_flush_ready(flush_ready),.cfg_awb_min_gain(16'd0),.cfg_awb_max_gain(16'd1024),
 .applied_gain_r(gainr),.applied_gain_g(gaing),.applied_gain_b(gainb),.applied_statistics_frame(aframe),
 .awb_error(awe),.awb_update_pending(awpending),
 .cfg_ccm_we(cwe),.cfg_ccm_index(ci),.cfg_ccm_value(cv),.cfg_ccm_ready(cr),
 .cfg_adjust_we(awecfg),.cfg_brightness(bright),.cfg_contrast(contrast),.cfg_adjust_ready(ar),
 .cfg_gamma_we(gwe),.cfg_gamma_channel(2'd3),.cfg_gamma_addr(ga),.cfg_gamma_value(gd),.cfg_gamma_enable(gen),
 .cfg_gamma_ready(gready),.cfg_gamma_complete(complete),.cfg_commit_valid(commit),.cfg_commit_ready(commit_ready),
 .cfg_pending(pending),.cfg_error(error),.gamma_active(active));
function integer clip;input integer v;begin clip=v<0?0:v>255?255:v;end endfunction
function[23:0] csc;
 input integer r,g,b;integer yy,cb,cc;
 begin yy=clip((77*r+150*g+29*b+128)>>>8);cb=clip(((-43*r-85*g+128*b+128)>>>8)+128);
 cc=clip(((128*r-107*g-21*b+128)>>>8)+128);csc={8'(yy),8'(cb),8'(cc)};end
endfunction
always @(posedge clk)if(rst)begin
 if(held && (!mv || md!==hd || {ms,me}!==ht))$fatal(1,"Color output unstable");
 held=mv && (!ce || !mr);hd=md;ht={ms,me};
 if(ce && mv && mr)begin
  if(got>=12 || md!==expected[got])$fatal(1,"Color n%0d got%h expected%h",got,md,expected[got]);
  if(ms!==(got%4==0) || me!==(got%2==1))$fatal(1,"Color output tags");got=got+1;
 end
 if(cfg_commit_ready_invalid())$fatal(1,"unreachable");
end
// Commit can never be accepted while a source pixel is being presented.
function cfg_commit_ready_invalid;begin cfg_commit_ready_invalid=commit_ready && sv;end endfunction
task send;
 input integer n;input[23:0] pixel;
 begin @(negedge clk);sd=pixel;ss=(n%4==0);se=(n%2==1);sv=1;
 do @(posedge clk);while(!(ce && sr));@(negedge clk);sv=0;end
endtask
task flush_stats;
 begin @(negedge clk);flush=1;do @(posedge clk);while(!(ce && flush_ready));@(negedge clk);flush=0;end
endtask
task matrix_write;
 input integer index,value;
 begin @(negedge clk);ci=index;cv=value;cwe=1;do @(posedge clk);while(!(ce && cr));@(negedge clk);cwe=0;end
endtask
initial begin
 for(i=0;i<4;i=i+1)expected[i]=csc(30,60,90);
 for(i=4;i<8;i=i+1)expected[i]=csc(60,60,60);
 // Stage 3: gains first yield 60/60/60, CCM gains 2/1/0.5,
 // brightness +5, inverse LUT => 130/190/220 before CSC.
 for(i=8;i<12;i=i+1)expected[i]=csc(130,190,220);
 repeat(3)@(negedge clk);rst=1;
 for(i=0;i<4;i=i+1)send(i,24'h1e3c5a);
 wait(got==4);flush_stats;wait(awpending);repeat(5)@(posedge clk);
 if(gainr!=256 || gaing!=256 || gainb!=256)$fatal(1,"AWB applied report changed before next SOF");
 for(i=4;i<8;i=i+1)send(i,24'h1e3c5a);
 wait(got==8);if(gainr!=512 || gaing!=256 || gainb!=170 || aframe!=0 || awe!=0)$fatal(1,"AWB closed loop gain report");
 matrix_write(0,2048);matrix_write(8,512);
 @(negedge clk);bright=5;awecfg=1;do @(posedge clk);while(!(ce && ar));@(negedge clk);awecfg=0;
 gen=1;repeat(3)@(posedge clk);if(commit_ready)$fatal(1,"Gamma incomplete commit accepted");
 for(i=0;i<256;i=i+1)begin
  @(negedge clk);gwe=1;ga=i;gd=255-i;do @(posedge clk);while(!(ce && gready));@(negedge clk);gwe=0;
 end
 if(complete!=7)$fatal(1,"Gamma complete map");
 @(negedge clk);commit=1;do @(posedge clk);while(!(ce && commit_ready));@(negedge clk);commit=0;
 for(i=8;i<12;i=i+1)send(i,24'h1e3c5a);
 wait(got==12);if(error || awe || pending || !active)$fatal(1,"Color configuration final state");
 done=1;$display("Auto AWB + CCM + brightness + gamma + CSC CE/backpressure/config PASS");
end
endmodule
module feedback_stream_case(output reg done=0);
reg clk=0;always #5 clk=~clk;
reg rst=0,ce=0,mr=0;integer cycle=0,n=0,got=0,balanced=0;
always @(negedge clk)begin cycle=cycle+1;ce=(cycle%4!=1);mr=(cycle%9>2);end
reg[23:0] sd=0;reg sv=0;wire sr;wire[23:0] md;wire mv,ms,me;
reg flush=0;wire fr;wire[15:0] ar,ag,ab;wire[31:0] af;wire[7:0] er;wire pending;
img_isp_awb_auto #(.SUM_WIDTH(16)) dut(
 .clk(clk),.rst_n(rst),.clk_en(ce),.s_data(sd),.s_valid(sv),.s_sof(1'b1),.s_eol(1'b1),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_ready(mr),.stats_flush(flush),.stats_flush_ready(fr),
 .cfg_min_gain(16'd0),.cfg_max_gain(16'd1024),.applied_gain_r(ar),.applied_gain_g(ag),.applied_gain_b(ab),
 .applied_statistics_frame(af),.error_code(er),.update_pending(pending));
always @(posedge clk)if(rst && ce && mv && mr)begin
 if(md!==(got%2?24'h0f1e2d:24'h1e3c5a) && md!==(got%2?24'h1e1e1e:24'h3c3c3c))
  $fatal(1,"AWB stream output n%0d %h",got,md);
 if(!ms || !me)$fatal(1,"AWB stream tags");
 if(md===(got%2?24'h1e1e1e:24'h3c3c3c))balanced=balanced+1;
 got=got+1;
end
task send_one;
 begin @(negedge clk);sd=n%2?24'h0f1e2d:24'h1e3c5a;sv=1;
 do @(posedge clk);while(!(ce && sr));@(negedge clk);sv=0;n=n+1;end
endtask
initial begin
 repeat(3)@(negedge clk);rst=1;
 // Collect several statistics while a frame-boundary gain update is pending,
 // then leave no SOF available. The mailbox must allow the solver to finish.
 repeat(4)send_one;
 @(negedge clk);flush=1;do @(posedge clk);while(!(ce && fr));@(negedge clk);flush=0;
 repeat(400)@(posedge clk);
 if(!pending)$fatal(1,"AWB lost pending update without SOF");
 repeat(76)send_one;
 wait(got==80);if(er || balanced<60 || ar!=512 || ag!=256 || ab!=170)$fatal(1,"AWB mixed stream final state");
 done=1;$display("AWB tiny-frame continuous feedback/mailbox no-deadlock PASS");
end
endmodule
module tb;
wire b8,b10,b12,solver,pipeline,feedback;
bayer_case #(.B(8)) a(b8);bayer_case #(.B(10)) b(b10);bayer_case #(.B(12)) c(b12);
solver_case d(solver);pipeline_case e(pipeline);
feedback_stream_case f(feedback);
initial begin wait(b8 && b10 && b12 && solver && pipeline && feedback);$display("ISP_GROUP_PASS");$finish;end
initial begin #2000000;$fatal(1,"ISP group timeout");end
endmodule
'''


def main() -> int:
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output = HERE / ("build_group_" + stamp)
    output.mkdir()
    env = os.environ.copy()
    oss = ROOT / "tools/oss-cad-suite/oss-cad-suite"
    env["PATH"] = os.pathsep.join([str(oss / "bin"), str(oss / "lib"), env.get("PATH", "")])
    iverilog = shutil.which("iverilog", path=env["PATH"])
    vvp = shutil.which("vvp", path=env["PATH"])
    if not iverilog or not vvp:
        raise SystemExit("iverilog/vvp missing; load scripts/env.ps1 or install OSS CAD Suite")
    tb = output / "tb_isp_group.sv"
    tb.write_text(BENCH, encoding="utf-8")
    sources = sorted((IMAGE / "isp").glob("*.v")) + sorted(HERE.glob("*.v")) + sorted((IMAGE / "window").glob("*.v"))
    commands = [
        [iverilog, "-g2012", "-Wall", "-s", "tb", "-o", str(output / "group.vvp"), str(tb), *map(str, sources)],
        [vvp, str(output / "group.vvp")],
    ]
    results = []
    for index, command in enumerate(commands):
        run = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        transcript = run.stdout + run.stderr
        (output / ("compile.log" if index == 0 else "simulation.log")).write_text(transcript, encoding="utf-8")
        results.append({"command": command, "returncode": run.returncode})
        print(transcript, end="")
        if run.returncode:
            break
    passed = len(results) == 2 and all(r["returncode"] == 0 for r in results)
    (output / "result.json").write_text(json.dumps({"passed": passed, "runs": results}, indent=2), encoding="utf-8")
    print(f"Evidence: {output}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
