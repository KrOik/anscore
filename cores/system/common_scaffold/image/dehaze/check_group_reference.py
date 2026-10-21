"""One small end-to-end development check; no board/resource qualification.

Run after scripts/env.ps1 to put iverilog/vvp on PATH. The independent Python
model uses unbounded signed integers and explicit truncation toward zero.
Generated simulation artifacts stay in a new timestamped reference_build_* directory.
"""
from pathlib import Path
import json
import subprocess
import datetime

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / ("reference_build_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f"))


def trunc_div(n, d):
    return (1 if n >= 0 else -1) * (abs(n) // d)


def box_indices(x, y, w, h, r):
    return [max(0, min(h - 1, yy)) * w + max(0, min(w - 1, xx))
            for yy in range(y - r, y + r + 1)
            for xx in range(x - r, x + r + 1)]


def guided(guide, source, w, h, r, eps):
    area = (2 * r + 1) ** 2
    aa, bb = [], []
    for y in range(h):
        for x in range(w):
            ii = box_indices(x, y, w, h, r)
            si, sp = sum(guide[i] for i in ii), sum(source[i] for i in ii)
            sii = sum(guide[i] ** 2 for i in ii)
            sip = sum(guide[i] * source[i] for i in ii)
            a = trunc_div((area * sip - si * sp) << 16,
                          area * sii - si * si + area * area * eps)
            b = trunc_div((sp << 16) - a * si, area)
            aa.append(a)
            bb.append(b)
    result = []
    for y in range(h):
        for x in range(w):
            ii = box_indices(x, y, w, h, r)
            q = trunc_div(sum(aa[i] for i in ii) * guide[y * w + x] +
                          sum(bb[i] for i in ii), area << 16)
            result.append(max(0, min(32768, q)))
    return result


def unpack(rgb):
    return [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255]


def pack(rgb):
    return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]


def dehaze(pixels, w, h, r, auto, airlight, permille, omega, t0, refine, gr, eps):
    rgb = [unpack(v) for v in pixels]
    dark = [min(min(rgb[i]) for i in box_indices(x, y, w, h, r))
            for y in range(h) for x in range(w)]
    if auto:
        k = (len(pixels) * permille + 999) // 1000
        threshold = sorted(dark, reverse=True)[k - 1]
        best = max((sum(rgb[i]), i) for i, d in enumerate(dark) if d >= threshold)[1]
        aa = rgb[best]
    else:
        aa = unpack(airlight)
    aa = [max(1, a) for a in aa]
    normalized = [min((c * 32768 + a // 2) // a for c, a in zip(p, aa)) for p in rgb]
    tt = []
    for y in range(h):
        for x in range(w):
            d = min(normalized[i] for i in box_indices(x, y, w, h, r))
            tt.append(max(0, 32768 - ((d * omega + 16384) >> 15)))
    if refine:
        guide = [(77 * p[0] + 150 * p[1] + 29 * p[2] + 128) >> 8 for p in rgb]
        tt = guided(guide, tt, w, h, gr, eps)
    out = [pack([max(0, min(255, trunc_div((c - a) * 32768, max(t, t0)) + a))
                 for c, a in zip(p, aa)]) for p, t in zip(rgb, tt)]
    return out, pack(aa)


TB = r'''
`timescale 1ns/1ps
module tb_dehaze_group;
reg clk=0; always #5 clk=~clk;
reg rst_n=0,ce=1;
integer cycle=0;
always @(negedge clk) begin
  cycle=cycle+1;
  ce=((cycle%11)!=3 && (cycle%11)!=4);
end
wire mr=(cycle%7)!=2 && (cycle%7)!=3;
reg gc=0,gv=0,gs=0,ge=0;
reg [15:0] gw=0,gh=0,gp=0;reg [3:0] gr=0;reg [31:0] eps=0;
reg [7:0] gi=0;reg [15:0] gtag=0;
wire gcr,gsr,gmv,gms,gme,gmf,grv;wire [15:0] gq,gmt,grt;wire [3:0] gre;
img_dh_guided_frame #(.MAX_WIDTH(4),.MAX_HEIGHT(4),.MAX_RADIUS(2)) ug(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(gc),.cmd_ready(gcr),
 .cmd_width(gw),.cmd_height(gh),.cmd_radius(gr),.cmd_epsilon(eps),.cmd_tag(gtag),
 .s_guide(gi),.s_p(gp),.s_valid(gv),.s_sof(gs),.s_eol(ge),.s_ready(gsr),
 .m_q(gq),.m_valid(gmv),.m_sof(gms),.m_eol(gme),.m_eof(gmf),.m_ready(mr),.m_tag(gmt),
 .rsp_valid(grv),.rsp_ready(mr),.rsp_error(gre),.rsp_tag(grt),.busy());
reg dc=0,dv=0,ds=0,de=0,da=0,df=0;
reg [15:0] dw=0,dh=0,om=0,t0=0,dtag=0;
reg [3:0] dr=0,dgr=0;reg [31:0] deps=0;reg [23:0] ai=0,dp=0;
reg [9:0] perm=0;
wire dcr,dsr,dmv,dms,dme,dmf,drv;wire [23:0] dq,dair;
wire [15:0] dmt,drt;wire [3:0] dre;
img_dh_dehaze_frame #(.MAX_WIDTH(4),.MAX_HEIGHT(4),.MAX_RADIUS(2)) ud(
 .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(dc),.cmd_ready(dcr),
 .cmd_width(dw),.cmd_height(dh),.cmd_dark_radius(dr),.cmd_auto_airlight(da),
 .cmd_airlight_rgb(ai),.cmd_airlight_permille(perm),.cmd_omega(om),.cmd_t0(t0),
 .cmd_guided_enable(df),.cmd_guided_radius(dgr),.cmd_guided_epsilon(deps),.cmd_tag(dtag),
 .s_data(dp),.s_valid(dv),.s_sof(ds),.s_eol(de),.s_ready(dsr),
 .m_data(dq),.m_valid(dmv),.m_sof(dms),.m_eol(dme),.m_eof(dmf),.m_ready(mr),.m_tag(dmt),
 .rsp_valid(drv),.rsp_ready(mr),.rsp_error(dre),.rsp_tag(drt),.rsp_airlight_rgb(dair),.busy());
reg [7:0] guides[0:31];reg [15:0] sources[0:31],gexpect[0:31];
reg [23:0] pixels[0:31],dexpect[0:31];
integer g_received=0,d_received=0,expect_count=0,expected_error=0;
integer g_cases=0,d_cases=0;
reg [23:0] expected_air;
reg [67:0] gpast,dpast;
reg ghold=0,dhold=0;
always @(posedge clk) begin
  if(rst_n) begin
    // A previously stalled beat survives both external backpressure and CE pauses.
    if(ghold && {gmv,gq,gms,gme,gmf,gmt} !== gpast) $fatal(1,"guided output changed while held");
    if(dhold && {dmv,dq,dms,dme,dmf,dmt} !== dpast) $fatal(1,"dehaze output changed while held");
    ghold<=gmv && !(ce && mr);dhold<=dmv && !(ce && mr);
    gpast<={gmv,gq,gms,gme,gmf,gmt};dpast<={dmv,dq,dms,dme,dmf,dmt};
    if(ce && gmv && mr) begin
      if(g_received>=expect_count || gq !== gexpect[g_received])
        $fatal(1,"guided mismatch case=%0d pixel=%0d got=%0d expected=%0d",g_cases,g_received,gq,gexpect[g_received]);
      if(gms !== (g_received==0) || gme !== ((g_received%gw)==gw-1) || gmf !== (g_received==expect_count-1) || gmt!==gtag)
        $fatal(1,"guided framing/tag");
      g_received=g_received+1;
    end
    if(ce && dmv && mr) begin
      if(d_received>=expect_count || dq !== dexpect[d_received])
        $fatal(1,"dehaze mismatch case=%0d pixel=%0d got=%06x expected=%06x",d_cases,d_received,dq,dexpect[d_received]);
      if(dms !== (d_received==0) || dme !== ((d_received%dw)==dw-1) || dmf !== (d_received==expect_count-1) || dmt!==dtag)
        $fatal(1,"dehaze framing/tag");
      d_received=d_received+1;
    end
  end
end
task run_guided;
input integer w,h,r,e,tag,err;
integer i;
begin
  @(negedge clk);g_cases=g_cases+1;gw=w;gh=h;gr=r;eps=e;gtag=tag;
  g_received=0;expect_count=(err==1)?0:w*h;expected_error=err;gc=1;
  @(posedge clk);while(!(ce && gcr)) @(posedge clk);
  @(negedge clk);gc=0;
  for(i=0;i<expect_count;i=i+1) begin
    gi=guides[i];gp=sources[i];gs=(i==0);ge=(i%w==w-1);gv=1;
    if(err==2 && i==0) gs=0;
    @(posedge clk);while(!(ce && gsr)) @(posedge clk);
    @(negedge clk);gv=0;
    if(i%2==0) @(negedge clk);
  end
  @(posedge clk);while(!(ce && grv && mr)) @(posedge clk);
  if(gre!==err || grt!==tag || g_received!=expect_count) $fatal(1,"guided response/count");
  @(negedge clk);
end
endtask
task run_dehaze;
input integer w,h,r,aut,a,pp,ww,tt,refine,rr,ee,tag,err,expected_a;
integer i;
begin
  @(negedge clk);d_cases=d_cases+1;dw=w;dh=h;dr=r;da=aut;ai=a;perm=pp;
  om=ww;t0=tt;df=refine;dgr=rr;deps=ee;dtag=tag;d_received=0;
  expect_count=(err==1)?0:w*h;expected_air=expected_a;dc=1;
  @(posedge clk);while(!(ce && dcr)) @(posedge clk);
  @(negedge clk);dc=0;
  for(i=0;i<expect_count;i=i+1) begin
    dp=pixels[i];ds=(i==0);de=(i%w==w-1);dv=1;
    if(err==2 && i==0) ds=0;
    @(posedge clk);while(!(ce && dsr)) @(posedge clk);
    @(negedge clk);dv=0;
    if(i%3==0) @(negedge clk);
  end
  @(posedge clk);while(!(ce && drv && mr)) @(posedge clk);
  if(dre!==err || drt!==tag || d_received!=expect_count) $fatal(1,"dehaze response/count");
  if(err!=1 && dair!==expected_air) $fatal(1,"automatic airlight got=%06x expected=%06x",dair,expected_air);
  @(negedge clk);
end
endtask
initial begin
  repeat(3) @(negedge clk);rst_n=1;
  // GENERATED_CASES
  $display("PASS dehaze_group guided_cases=%0d dehaze_cases=%0d cycles=%0d",g_cases,d_cases,cycle);
  $finish;
end
initial begin #20000000;$fatal(1,"timeout");end
endmodule
'''


def main():
    BUILD.mkdir(exist_ok=True)
    cases = []
    summary = []
    guides = [17, 199, 32, 240, 80, 64, 0, 255, 101]
    sources = [31000, 300, 22000, 3200, 19000, 12000, 32768, 0, 16384]
    for case, (gg, pp, w, h, r, e, err) in enumerate([
        (guides, sources, 3, 3, 1, 16, 0),
        ([64] * 9, sources, 3, 3, 1, 64, 0),
        (guides, sources, 3, 3, 0, 1, 0),
        ([255], [32768], 1, 1, 2, 65535, 0),
        (guides, sources, 3, 3, 1, 16, 2),
        ([], [], 0, 3, 1, 16, 1),
    ]):
        expected = guided(gg, pp, w, h, r, e) if not err == 1 else []
        for i, (g, p, q) in enumerate(zip(gg, pp, expected)):
            cases.append(f"guides[{i}]=8'd{g};sources[{i}]=16'd{p};gexpect[{i}]=16'd{q};")
        cases.append(f"run_guided({w},{h},{r},{e},{100+case},{err});")
        summary.append({"kind": "guided", "case": case, "expected": expected})
    rgb = [0x607080, 0x90A060, 0x8090A0, 0xD0D8E0, 0x223344,
           0xA0B0C0, 0x778899, 0xCCDDEE, 0x405060]
    configs = [
        (3, 3, 1, 0, 0xC8DCF0, 1, 29491, 3277, 0, 1, 64, 0),
        (3, 3, 1, 1, 0, 1, 29491, 3277, 1, 1, 64, 0),
        (3, 3, 0, 1, 0, 400, 32000, 5000, 1, 1, 16, 0),
        (3, 3, 1, 1, 0, 1000, 0, 3277, 0, 0, 1, 0),
        (1, 1, 2, 1, 0, 1, 29491, 3277, 1, 2, 1, 0),
        (3, 3, 1, 0, 0x000080, 1, 29491, 3277, 0, 1, 64, 2),
        (0, 3, 1, 0, 0, 1, 29491, 3277, 0, 0, 1, 1),
    ]
    for case, cfg in enumerate(configs):
        w, h, r, aut, a, pp, ww, tt, refine, rr, ee, err = cfg
        pix = [0] if w * h == 1 else rgb
        expected, air = dehaze(pix, w, h, r, aut, a, pp, ww, tt, refine, rr, ee) if err != 1 else ([], 0)
        for i, (p, q) in enumerate(zip(pix, expected)):
            cases.append(f"pixels[{i}]=24'h{p:06x};dexpect[{i}]=24'h{q:06x};")
        cases.append("run_dehaze(" + ",".join(map(str, cfg[:-1] + (200+case, err, air))) + ");")
        summary.append({"kind": "dehaze", "case": case, "airlight": air, "expected": expected})
    tb = BUILD / "tb_dehaze_group.v"
    tb.write_text(TB.replace("// GENERATED_CASES", "\n".join(cases)), encoding="utf-8")
    compiled = BUILD / "dehaze_group.vvp"
    command = ["iverilog", "-g2012", "-Wall", "-s", "tb_dehaze_group", "-o", str(compiled),
               *map(str, ROOT.glob("*.v")), str(tb)]
    result = subprocess.run(command, capture_output=True, text=True)
    (BUILD / "compile.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    run = subprocess.run(["vvp", str(compiled)], capture_output=True, text=True, timeout=45)
    (BUILD / "simulation.log").write_text(run.stdout + run.stderr, encoding="utf-8")
    (BUILD / "reference_vectors.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(run.stdout, end="")
    if run.returncode:
        raise RuntimeError(run.stderr or run.stdout)
    (BUILD / "summary.json").write_text(json.dumps({"status": "pass", "guided_cases": 6,
        "dehaze_cases": 7, "checks": ["exact independent integer reference", "automatic airlight",
        "guidance and source data dependence", "CE stalls", "output backpressure",
        "frame tags and framing", "invalid command", "malformed frame response"],
        "synthesis": "not_run", "board": "not_run"}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
