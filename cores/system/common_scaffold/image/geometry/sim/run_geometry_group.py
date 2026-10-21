"""One group regression: integer Python references versus all frame geometry paths.

Run from any directory; OSS CAD Suite is located relative to the repository.
This is a development regression, not synthesis/board qualification.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
GROUP = HERE.parent
ROOT = GROUP.parents[3]


def rgb(x: int, y: int, seed: int) -> int:
    return sum(((x * (19 + lane * 7) + y * (47 - lane * 9) + seed * (13 + lane * 5)) & 255)
               << (lane * 8) for lane in range(3))


def trunc_div(a: int, b: int) -> int:
    return (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1)


def geometry_ref(src, sw, sh, dw, dh, mode, filt, h):
    result = []
    for y in range(dh):
        for x in range(dw):
            error = 0
            if mode == 0:
                qx, qy = x << 8, y << 8
            elif mode == 1:
                qx, qy = (x * sw * 256) // dw, (y * sh * 256) // dh
            elif mode == 2:
                qx, qy = y << 8, (sh - 1 - x) << 8
            elif mode == 3:
                qx, qy = (sw - 1 - x) << 8, (sh - 1 - y) << 8
            elif mode == 4:
                qx, qy = (sw - 1 - y) << 8, x << 8
            elif mode == 5:
                qx, qy = (sw - 1 - x) << 8, y << 8
            elif mode == 6:
                qx, qy = x << 8, (sh - 1 - y) << 8
            else:
                nx, ny = h[0]*x+h[1]*y+h[2], h[3]*x+h[4]*y+h[5]
                if mode == 7:
                    qx, qy = nx >> 8, ny >> 8
                else:
                    den = h[6]*x+h[7]*y+h[8]
                    if den == 0:
                        qx, qy, error = 0, 0, 4
                    else:
                        qx, qy = trunc_div(nx * 256, den), trunc_div(ny * 256, den)
            if error or qx < 0 or qy < 0 or qx >= sw*256 or qy >= sh*256:
                value = 0
            else:
                sx, sy, fx, fy = qx >> 8, qy >> 8, qx & 255, qy & 255
                if filt == 0:
                    sx, sy = min(sw-1, sx+(fx >= 128)), min(sh-1, sy+(fy >= 128))
                    value = src[sy*sw+sx]
                else:
                    nx, ny = min(sw-1, sx+1), min(sh-1, sy+1)
                    p = [src[sy*sw+sx], src[sy*sw+nx], src[ny*sw+sx], src[ny*sw+nx]]
                    weights = [(256-fx)*(256-fy), fx*(256-fy), (256-fx)*fy, fx*fy]
                    value = sum(((sum(((p[k] >> (8*lane)) & 255)*weights[k] for k in range(4))
                                  + 32768) >> 16) << (8*lane) for lane in range(3))
            result.append((value, error))
    return result


def area_ref(src, sw, sh, dw, dh):
    result = []
    for y in range(dh):
        for x in range(dw):
            sums = [0, 0, 0]
            for sy in range(sh):
                wy = max(0, min((y+1)*sh, (sy+1)*dh)-max(y*sh, sy*dh))
                for sx in range(sw):
                    wx = max(0, min((x+1)*sw, (sx+1)*dw)-max(x*sw, sx*dw))
                    for lane in range(3):
                        sums[lane] += ((src[sy*sw+sx] >> (lane*8)) & 255)*wx*wy
            result.append((sum(((v+(sw*sh)//2)//(sw*sh)) << (lane*8)
                               for lane, v in enumerate(sums)), 0))
    return result


IDENTITY = [65536, 0, 0, 0, 65536, 0, 0, 0, 65536]


def cases():
    output = []

    def add(name, sw=5, sh=3, dw=None, dh=None, target=0, mode=0, filt=0,
            scale=2, h=None, error=0, malformed=False):
        dw, dh = (sw if dw is None else dw), (sh if dh is None else dh)
        h = list(IDENTITY if h is None else h)
        seed = len(output)+1
        src = [rgb(x, y, seed) for y in range(sh) for x in range(sw)]
        if error and error != 4:
            expected = []
        elif target == 1:
            expected = area_ref(src, sw, sh, dw, dh)
        else:
            expected = geometry_ref(src, sw, sh, dw, dh, mode, filt, h)
        output.append(dict(name=name, sw=sw, sh=sh, dw=dw, dh=dh, target=target,
                           mode=mode, filt=filt, scale=scale, h=h, error=error,
                           malformed=malformed, src=src, expected=expected,
                           send_input=not error or error == 4 or malformed))

    add("identity_rgb")
    for mode in range(2, 7):
        add(f"direct_mode_{mode}", mode=mode, dw=3 if mode in (2, 4) else 5,
            dh=5 if mode in (2, 4) else 3)
    add("nearest_reduce", dw=3, dh=2, mode=1)
    add("bilinear_enlarge", dw=9, dh=7, mode=1, filt=1)
    add("bilinear_reduce", sw=7, sh=5, dw=3, dh=2, mode=1, filt=1)
    add("single_pixel_enlarge", sw=1, sh=1, dw=4, dh=3, mode=1, filt=1)
    add("affine_translation_border", dw=7, dh=4, mode=7, filt=1,
        h=[65536, 8192, -49152, 0, 65536, -32768, 0, 0, 65536])
    add("perspective", dw=6, dh=4, mode=8, filt=1,
        h=[65536, 8192, 0, -4096, 65536, 0, 2048, 1024, 65536])
    add("perspective_divzero", sw=3, sh=2, mode=8, error=4,
        h=[65536, 0, 0, 0, 65536, 0, 65536, 0, 0])
    add("bad_mode", mode=15, error=3)
    add("bad_shape", mode=2, error=1)
    add("bad_filter", filt=3, error=3)
    add("bad_source_limit", sw=9, error=1)
    add("bad_markers", malformed=True, error=2)
    add("area_fractional_reduce", target=1, sw=5, sh=3, dw=3, dh=2)
    add("area_ssaa_2x2", target=1, sw=4, sh=4, dw=2, dh=2)
    add("area_fractional_enlarge", target=1, sw=3, sh=2, dw=5, dh=3)
    add("area_whole_frame_mean", target=1, sw=7, sh=5, dw=1, dh=1)
    add("area_one_pixel", target=1, sw=1, sh=1, dw=3, dh=5)
    add("area_bad_markers", target=1, malformed=True, error=2)
    add("area_bad_limit", target=1, sw=9, error=1)
    add("integer_upsample_compat", target=2, sw=3, sh=2, dw=6, dh=4, mode=1, filt=1)
    add("integer_upsample_3x", target=2, sw=2, sh=3, dw=6, dh=9, mode=1, filt=1, scale=3)
    add("integer_upsample_bad_scale", target=2, scale=0, error=1)
    return output


BENCH = r"""
`timescale 1ns/1ps
module tb_geometry_group;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=0,cfg_valid=0,s_valid=0,s_sof=0,s_eol=0,m_ready=0,rsp_ready=0;
reg [23:0] s_data=0;
reg [7:0] tag=0;
reg [3:0] mode=0,scale=2;
reg [1:0] filt=0;
reg [15:0] sw=0,sh=0,dw=0,dh=0;
reg signed [31:0] h00=0,h01=0,h02=0,h10=0,h11=0,h12=0,h20=0,h21=0,h22=0;
integer target=0;
wire [2:0] cr,sr,mv,rv,ms,me,mf;
wire [23:0] md[0:2];wire [3:0] merr[0:2],rerr[0:2];wire [7:0] rtag[0:2];
wire [31:0] pixels;
img_geo_frame_buffered #(.MAX_WIDTH(8),.MAX_HEIGHT(8)) geometric (
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(cfg_valid && target==0),.cfg_ready(cr[0]),.cfg_tag(tag),
 .cfg_mode(mode),.cfg_filter(filt),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_h00(h00),.cfg_h01(h01),.cfg_h02(h02),.cfg_h10(h10),.cfg_h11(h11),.cfg_h12(h12),.cfg_h20(h20),.cfg_h21(h21),.cfg_h22(h22),
 .busy(),.rsp_valid(rv[0]),.rsp_ready(rsp_ready),.rsp_tag(rtag[0]),.rsp_error(rerr[0]),.rsp_pixels(pixels),
 .s_valid(s_valid && target==0),.s_ready(sr[0]),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(mv[0]),.m_ready(m_ready),.m_data(md[0]),.m_error(merr[0]),.m_sof(ms[0]),.m_eol(me[0]),.m_eof(mf[0]));
img_geo_area_resample #(.MAX_WIDTH(8),.MAX_HEIGHT(8)) area (
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(cfg_valid && target==1),.cfg_ready(cr[1]),.cfg_tag(tag),
 .cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .busy(),.rsp_valid(rv[1]),.rsp_ready(rsp_ready),.rsp_tag(rtag[1]),.rsp_error(rerr[1]),
 .s_valid(s_valid && target==1),.s_ready(sr[1]),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(mv[1]),.m_ready(m_ready),.m_data(md[1]),.m_sof(ms[1]),.m_eol(me[1]),.m_eof(mf[1]));
assign merr[1]=0;
img_geo_super_resolution_stub #(.MAX_WIDTH(8),.MAX_HEIGHT(8)) compat (
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cfg_valid(cfg_valid && target==2),.cfg_ready(cr[2]),.cfg_tag(tag),
 .cfg_width(sw),.cfg_height(sh),.cfg_scale(scale),
 .rsp_valid(rv[2]),.rsp_ready(rsp_ready),.rsp_tag(rtag[2]),.rsp_error(rerr[2]),
 .s_valid(s_valid && target==2),.s_ready(sr[2]),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(mv[2]),.m_ready(m_ready),.m_data(md[2]),.m_sof(ms[2]),.m_eol(me[2]));
assign merr[2]=0;assign mf[2]=0;
reg [23:0] source[0:255],expected[0:255];reg [3:0] expected_error[0:255];
integer cycle=0,got=0,n_expected=0,n_source=0,test_count=0,input_index,wait_count;
integer expected_rsp_error=0;
reg monitor=0,malformed=0,send_input=0;
reg held=0;reg [30:0] held_output;
always @(negedge clk) begin
 cycle=cycle+1;
 ce=(cycle%7!=1 && cycle%7!=2);
 m_ready=(cycle%5!=0 && cycle%5!=1);
end
always @(posedge clk) if(rst_n && monitor) begin
 if(held && {mv[target],merr[target],ms[target],me[target],md[target]} !== held_output)
  $fatal(1,"output unstable target=%0d test=%0d",target,test_count);
 held=mv[target] && (!ce || !m_ready);
 held_output={mv[target],merr[target],ms[target],me[target],md[target]};
 if(ce && mv[target] && m_ready) begin
  if(got>=n_expected) $fatal(1,"unexpected pixel test=%0d",test_count);
  if(md[target]!==expected[got] || merr[target]!==expected_error[got])
   $fatal(1,"pixel test=%0d index=%0d actual=%h/%h expected=%h/%h",test_count,got,md[target],merr[target],expected[got],expected_error[got]);
  if(ms[target] !== (got==0) || me[target] !== ((got%dw)==dw-1))
   $fatal(1,"marker test=%0d index=%0d",test_count,got);
  if(target!=2 && mf[target] !== (got==n_expected-1)) $fatal(1,"eof mismatch");
  got=got+1;
 end
end
task run_case;
 reg [11:0] response_snapshot;
 reg [7:0] accepted_tag;
 begin
  got=0;held=0;monitor=1;test_count=test_count+1;accepted_tag=tag;
  @(negedge clk);cfg_valid=1;
  wait_count=0;
  begin: command_wait
   forever begin
    @(posedge clk);if(ce && cr[target]) disable command_wait;
    wait_count=wait_count+1;if(wait_count>1000) $fatal(1,"cfg timeout");
   end
  end
  @(negedge clk);cfg_valid=0;
  // Command fields may change immediately after acceptance. They must have
  // been latched, including matrix/filter and the transaction tag.
  tag=tag^8'ha5;mode=15;filt=3;scale=0;
  h00=0;h01=0;h02=32'h7fffffff;h10=0;h11=0;h12=32'h80000000;h20=0;h21=0;h22=0;
  if(send_input) for(input_index=0;input_index<n_source;input_index=input_index+1) begin
   // Deterministic bubbles before selected input pixels.
   if(input_index%3==1) begin @(negedge clk);s_valid=0;end
   @(negedge clk);s_valid=1;s_data=source[input_index];
   s_sof=(input_index==0);s_eol=(input_index%sw==sw-1);
   if(malformed && input_index==n_source-1) s_eol=0;
   wait_count=0;
   begin: pixel_wait
    forever begin
     @(posedge clk);if(ce && sr[target]) disable pixel_wait;
     wait_count=wait_count+1;if(wait_count>2000) $fatal(1,"input timeout test=%0d",test_count);
    end
   end
   @(negedge clk);s_valid=0;
  end
  wait_count=0;
  while(!rv[target]) begin
   @(posedge clk);wait_count=wait_count+1;
   if(wait_count>40000) $fatal(1,"completion timeout test=%0d",test_count);
  end
  @(negedge clk);
  if(got!=n_expected || rerr[target]!==expected_rsp_error[3:0] || rtag[target]!==accepted_tag)
   $fatal(1,"response test=%0d count=%0d/%0d err=%d/%0d tag=%h/%h",test_count,got,n_expected,rerr[target],expected_rsp_error,rtag[target],accepted_tag);
  if(target==0 && pixels!==n_expected) $fatal(1,"completion pixel count");
  response_snapshot={rerr[target],rtag[target]};
  repeat(9) begin
   @(posedge clk);
   if(!rv[target] || {rerr[target],rtag[target]}!==response_snapshot || cr[target]) $fatal(1,"response hold failure");
  end
  @(negedge clk);rsp_ready=1;
  begin: response_wait
   forever begin @(posedge clk);if(ce && rv[target]) disable response_wait;end
  end
  @(negedge clk);rsp_ready=0;monitor=0;held=0;
  $display("case %0d PASS target=%0d pixels=%0d",test_count,target,n_expected);
 end
endtask
task reset_abort;
 input integer which;
 integer k;
 begin
  target=which;sw=3;sh=2;dw=3;dh=2;mode=0;filt=0;scale=1;tag=8'hbb;
  @(negedge clk);cfg_valid=1;
  begin: reset_cmd_wait
   forever begin @(posedge clk);if(ce && cr[target]) disable reset_cmd_wait;end
  end
  @(negedge clk);cfg_valid=0;
  for(k=0;k<2;k=k+1) begin
   @(negedge clk);s_valid=1;s_data=24'habcdef;s_sof=k==0;s_eol=0;
   begin: reset_pixel_wait
    forever begin @(posedge clk);if(ce && sr[target]) disable reset_pixel_wait;end
   end
   @(negedge clk);s_valid=0;
  end
  // RAM contents persist, but a partially captured frame must never publish.
  rst_n=0;repeat(3) @(negedge clk);rst_n=1;
  repeat(11) begin
   @(posedge clk);
   if(rv[target] || mv[target] || !cr[target] || sr[target]) $fatal(1,"reset abort target=%0d",target);
  end
  $display("reset abort PASS target=%0d",target);
 end
endtask
initial begin
 repeat(4) @(negedge clk);rst_n=1;
 reset_abort(0);reset_abort(1);reset_abort(2);
 @CASES@
 $display("GEOMETRY_GROUP PASS cases=%0d",test_count);$finish;
end
initial begin #100000000;$fatal(1,"global timeout");end
endmodule
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir or HERE / ("build_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
    build.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    oss = ROOT / "tools/oss-cad-suite/oss-cad-suite"
    env["PATH"] = os.pathsep.join([str(oss / "bin"), str(oss / "lib"), env.get("PATH", "")])
    compiler = shutil.which("iverilog", path=env["PATH"])
    runtime = shutil.which("vvp", path=env["PATH"])
    if not compiler or not runtime:
        raise SystemExit("iverilog/vvp unavailable; source scripts/env.ps1 or install OSS CAD Suite")
    data = cases()
    statements = []
    for case in data:
        statements.append("// " + case["name"])
        for key, dest in [("target", "target"), ("sw", "sw"), ("sh", "sh"), ("dw", "dw"), ("dh", "dh"),
                          ("mode", "mode"), ("filt", "filt"), ("scale", "scale"), ("error", "expected_rsp_error")]:
            statements.append(f"{dest}={case[key]};")
        statements.append(f"tag=8'd{len(statements) % 255};")
        statements.append(f"n_source={len(case['src'])};n_expected={len(case['expected'])};")
        statements.append(f"send_input={int(case['send_input'])};malformed={int(case['malformed'])};")
        for name, value in zip(["h00", "h01", "h02", "h10", "h11", "h12", "h20", "h21", "h22"], case["h"]):
            statements.append(f"{name}=32'h{value & 0xffffffff:08x};")
        for i, value in enumerate(case["src"]):
            statements.append(f"source[{i}]=24'h{value:06x};")
        for i, (value, error) in enumerate(case["expected"]):
            statements.append(f"expected[{i}]=24'h{value:06x};expected_error[{i}]={error};")
        statements.append("run_case;")
    bench = build / "tb_geometry_group.sv"
    bench.write_text(BENCH.replace("@CASES@", "\n ".join(statements)), encoding="utf-8")
    sources = sorted(str(p) for p in (GROUP / "rtl").glob("*.v"))
    commands = [[compiler, "-g2012", "-tnull", *sources],
                [compiler, "-g2012", "-s", "tb_geometry_group", "-o", str(build/"geometry.vvp"), str(bench), *sources],
                [runtime, str(build/"geometry.vvp")]]
    results = []
    for i, command in enumerate(commands):
        proc = subprocess.run(command, text=True, capture_output=True, env=env, timeout=120)
        output = proc.stdout+proc.stderr
        (build / f"step_{i}.log").write_text(output, encoding="utf-8")
        print(output, end="")
        results.append(dict(command=command, returncode=proc.returncode, log=f"step_{i}.log"))
        if proc.returncode:
            break
    summary = dict(cases=[c["name"] for c in data], commands=results,
                   passed=len(results)==3 and all(r["returncode"]==0 for r in results),
                   synthesis="not_run", board="not_run", resource_impact="unknown")
    (build / "result.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("Evidence:", build)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
