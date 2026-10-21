"""Test rejection templates separately from functional DSP and image adapters."""
from pathlib import Path
import sys
import tempfile
import hashlib
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "integration"))
from tooling import evidence_dir, execute, sim, write_json
from generate import SPECS, FUNCTIONAL
sys.path.insert(0, str(HERE.parent / "dsp"))
from resampler_reference import fixtures as resampler_fixtures
from cic_adapter_reference import fixtures as cic_fixtures
from cordic_adapter_reference import fixtures as cordic_fixtures
from fft_adapter_reference import fixtures as fft_fixtures
LEGACY_SPECS = [spec for spec in SPECS if spec[0] not in FUNCTIONAL]


def bench():
    instances = []
    for i, (name, family, _) in enumerate(LEGACY_SPECS):
        if family == "image":
            config = f"""
      .cfg_src_width(16'd640),.cfg_src_height(16'd480),.cfg_dst_width(16'd320),.cfg_dst_height(16'd240),
      .cfg_mode(4'd0),.cfg_param0(32'd1),.cfg_param1(32'd2),.cfg_frame_base(32'h1000),.cfg_frame_stride(32'd1920),
      .cfg_aux_base(32'h2000),.coeff_valid(1'b1),.coeff_ready(coeff_ready[{i}]),.coeff_addr(16'd0),.coeff_data(32'h123),
      .aux_data(24'habcdef),.aux_valid(1'b1),.aux_sof(1'b1),.aux_eol(1'b1),.aux_ready(aux_ready[{i}]),
      .s_sof(1'b1),.s_eol(1'b1),.m_sof(sof[{i}]),.m_eol(last[{i}]),
      .mem_req_valid(mem_valid[{i}]),.mem_req_write(mem_write[{i}]),.mem_req_addr(mem_addr[{32*i}+:32]),
      .mem_req_wdata(mem_wdata[{32*i}+:32]),.mem_req_wstrb(mem_wstrb[{4*i}+:4]),
      .mem_req_ready(1'b1),.mem_rsp_valid(1'b1),.mem_rsp_rdata(32'hdeadbeef),.mem_rsp_error(1'b0),
      .mem_rsp_ready(mem_rsp_ready[{i}]),"""
            tied = ""
        else:
            config = f".cfg_opcode(8'd0),.cfg_param0(32'd1),.cfg_param1(32'd2),.s_last(1'b1),.m_last(last[{i}]),"
            tied = (f"assign sof[{i}]=0; assign mem_valid[{i}]=0; assign mem_write[{i}]=0; "
                    f"assign mem_addr[{32*i}+:32]=0; assign mem_wdata[{32*i}+:32]=0; "
                    f"assign mem_wstrb[{4*i}+:4]=0; assign mem_rsp_ready[{i}]=0; "
                    f"assign coeff_ready[{i}]=0; assign aux_ready[{i}]=0;")
        instances.append(f"""{name} #(.DATA_W(24),.TAG_W(8)) u{i}(
      .clk(clk),.rst_n(rst_n),.clk_en(ce),.cmd_valid(cv),.cmd_ready(cr[{i}]),.cmd_tag(tag),
      .rsp_valid(rv[{i}]),.rsp_ready(rr),.rsp_tag(rt[{8*i}+:8]),.rsp_error(err[{2*i}+:2]),
      {config}
      .s_data(24'h123456),.s_valid(1'b1),.s_ready(sr[{i}]),.m_data(md[{24*i}+:24]),.m_valid(mv[{i}]),.m_ready(1'b1));
      {tied}""")
    return """`timescale 1ns/1ps
module tb_signal_video;
localparam N=NUM_MODULES;
reg clk=0,rst_n=1,ce=0,cv=0,rr=0;
reg [7:0] tag=0;
always #5 clk=~clk;
wire [N-1:0] cr,rv,sr,mv,sof,last,mem_valid,mem_write,mem_rsp_ready,coeff_ready,aux_ready;
wire [N*8-1:0] rt;
wire [N*2-1:0] err;
wire [N*24-1:0] md;
wire [N*32-1:0] mem_addr,mem_wdata;
wire [N*4-1:0] mem_wstrb;
INSTANCES
task tick; begin @(posedge clk); #1; @(negedge clk); end endtask
task safe;
begin
  if(sr !== 0 || mv !== 0 || sof !== 0 || last !== 0 || md !== 0 || mem_valid !== 0 || mem_write !== 0 ||
     mem_addr !== 0 || mem_wdata !== 0 || mem_wstrb !== 0 || mem_rsp_ready !== 0 || coeff_ready !== 0 || aux_ready !== 0)
     $fatal(1,"placeholder dataplane activity");
end endtask
task check_response(input [7:0] expected);
integer j;
begin
  if(rv !== {N{1'b1}}) $fatal(1,"missing response");
  for(j=0;j<N;j=j+1) begin
    if(rt[8*j+:8] !== expected || err[2*j+:2] !== 2'b01) $fatal(1,"bad response module %d",j);
  end
  safe();
end endtask
initial begin
  #1;rst_n=0; #2; rst_n=1; @(negedge clk);
  cv=1;tag=8'h31;repeat(3)tick();
  if(rv !== 0) $fatal(1,"accepted while CE disabled"); safe();
  ce=1;tick();check_response(8'h31);
  tag=8'h72;rr=0;repeat(4)begin tick();check_response(8'h31); if(cr !== 0)$fatal(1,"overwrote pending response");end
  ce=0;rr=1;repeat(3)begin tick();check_response(8'h31);end
  ce=1;tick();check_response(8'h72);
  cv=0;tick();if(rv !== 0)$fatal(1,"duplicate response");safe();
  cv=1;tag=8'hff;rr=0;tick();check_response(8'hff);
  rst_n=0;#1;if(rv !== 0 || cr !== 0)$fatal(1,"reset did not flush");safe();
  $display("SIGNAL_VIDEO PASS modules=%0d rejection_only=1",N);$finish;
end
initial begin #20000;$fatal(1,"timeout");end
endmodule
""".replace("NUM_MODULES", str(len(LEGACY_SPECS))).replace("INSTANCES", "\n".join(instances))


def main():
    evidence = evidence_dir("signal_video")
    execute([sys.executable, HERE / "generate.py", "--check"], HERE, evidence / "generated_check.log")
    adapter_runners = [('run_image_adapter_tests.py', 'image_adapter_tests.log'), ('run_pointwise_tests.py', 'pointwise_adapter_tests.log'), ('run_ccm_tests.py', 'ccm_adapter_tests.log'), ('run_gamma_tests.py', 'gamma_adapter_tests.log'), ('run_bayer_tests.py', 'bayer_adapter_tests.log'), ('run_window_filter_tests.py', 'window_filter_adapter_tests.log'), ('run_edge_tests.py', 'edge_adapter_tests.log'), ('run_morph_frame_tests.py', 'morphology_adapter_tests.log'), ('run_histogram_frame_tests.py', 'histogram_adapter_tests.log'), ('run_permutation_tests.py', 'permutation_adapter_tests.log'), ('run_rotate_angle_tests.py', 'rotate_angle_adapter_tests.log'), ('run_frame_difference_tests.py', 'frame_difference_adapter_tests.log'), ('run_background_tests.py', 'background_adapter_tests.log'), ('run_fusion_tests.py', 'fusion_adapter_tests.log'), ('run_osd_tests.py', 'osd_adapter_tests.log'), ('run_temporal_tests.py', 'temporal_adapter_tests.log'), ('run_bilateral_tests.py', 'bilateral_adapter_tests.log'), ('run_canny_tests.py', 'canny_adapter_tests.log'), ('run_scaler_tests.py', 'scaler_adapter_tests.log'), ('run_bicubic_tests.py', 'bicubic_adapter_tests.log'), ('run_downsample_tests.py', 'downsample_adapter_tests.log'), ('run_upsample_tests.py', 'upsample_adapter_tests.log'), ('run_clahe_tests.py', 'clahe_adapter_tests.log'), ('run_window_tests.py', 'window_adapter_tests.log'), ('run_framebuffer_tests.py', 'framebuffer_adapter_tests.log'), ('run_dehaze_adapters_tests.py', 'dehaze_adapters_tests.log'), ('run_guided_nlm_tests.py', 'guided_nlm_adapter_tests.log'), ('run_projective_tests.py', 'projective_adapter_tests.log'), ('run_stitch_tests.py', 'stitch_adapter_tests.log'), ('run_super_resolution_tests.py', 'super_resolution_adapter_tests.log')]
    # Independent runners own unique temporary/evidence directories.
    with ThreadPoolExecutor(max_workers=3) as pool:
        # CLAHE now covers odd/partial tiles and 1x1 tiles at three widths;
        # retain the full reference workload under concurrent PNR/simulation.
        futures = {pool.submit(execute, [sys.executable, HERE / runner], HERE, evidence / log,
                               (2400 if runner == 'run_bicubic_tests.py' else
                                1800 if runner == 'run_super_resolution_tests.py' else
                                1800 if runner == 'run_clahe_tests.py' else 600)): runner
                   for runner, log in adapter_runners}
        for future in as_completed(futures):
            future.result()
            print(f"{futures[future]}: PASS", flush=True)
    tb = evidence / "tb_signal_video.sv"
    if LEGACY_SPECS:
        tb.write_text(bench(), encoding="utf-8")
    sources = [HERE.parent / "common/rtl/cip_unsupported_stream.v", *sorted((HERE / "rtl").glob("*.v")),
               *sorted((HERE.parent / "dsp/rtl").glob("*.v"))]
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines()
                if line.strip() and not line.startswith('#')]
    tracked=[*sources,*sorted((HERE/"sim").glob("*.v")),*sorted(HERE.glob("*.py")),
             *sorted((HERE.parent/"dsp").glob("*.py"))]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    resampler_results=[]
    cordic_results={}
    cic_results=[]
    fft_results=[]
    with tempfile.TemporaryDirectory(prefix="cip_signal_video_") as temporary:
        for name, bench_path, marker in [
            *([("tb_signal_video", tb, "SIGNAL_VIDEO PASS")] if LEGACY_SPECS else []),
            ("tb_cip_fir_stream", HERE / "sim/tb_cip_fir_stream.v", "FIR_ADAPTER PASS outputs=69 responses=11"),
            ("tb_cip_iir_biquad_stream", HERE / "sim/tb_cip_iir_biquad_stream.v", "IIR_ADAPTER PASS outputs=69 responses=13")]:
            image = Path(temporary) / f"{name}.vvp"
            execute(["iverilog", "-g2012", "-s", name, "-o", image, *sources, bench_path],
                    HERE, evidence / f"{name}_compile.log")
            output = execute(["vvp", image], HERE, evidence / f"{name}_simulation.log")
            if marker not in output:
                raise RuntimeError(f"missing success marker: {marker}")
            print(output.strip())
        for up,down,taps in [(3,2,11),(2,5,13),(5,1,7),(1,4,9)]:
            label=f"resampler_adapter_u{up}_d{down}"
            folder=Path(temporary)/label
            folder.mkdir()
            counts=resampler_fixtures(folder,up,down,taps)
            image=folder/"test.vvp"
            execute(["iverilog","-g2012","-s","tb_cip_resampler_stream",
                     f"-Ptb_cip_resampler_stream.UP={up}",f"-Ptb_cip_resampler_stream.DOWN={down}",
                     f"-Ptb_cip_resampler_stream.TAPS={taps}","-o",image,*sources,
                     HERE/"sim/tb_cip_resampler_stream.v"],HERE,evidence/f"{label}_compile.log")
            output=execute(["vvp",image,f"+folder={folder}"],HERE,evidence/f"{label}_simulation.log")
            if ("RESAMPLER_ADAPTER PASS" not in output or f"outputs={counts['outputs']}" not in output
                or f"packets={counts['packets']} responses={taps+16}" not in output):
                raise RuntimeError("Missing resampler adapter success marker")
            resampler_results.append({"up":up,"down":down,"taps":taps,"responses":taps+16,**counts})
            print(output.strip())
        for rate,stages,shift in [(1,1,0),(8,3,9),(8,3,0),(3,2,1)]:
            label=f"cic_adapter_r{rate}_n{stages}_s{shift}"
            folder=Path(temporary)/label
            folder.mkdir()
            counts=cic_fixtures(folder,rate,stages,shift)
            image=folder/"test.vvp"
            execute(["iverilog","-g2012","-s","tb_cip_cic_decimator",
                     f"-Ptb_cip_cic_decimator.RATE={rate}",f"-Ptb_cip_cic_decimator.STAGES={stages}",
                     f"-Ptb_cip_cic_decimator.SHIFT={shift}","-o",image,*sources,
                     HERE/"sim/tb_cip_cic_decimator.v"],HERE,evidence/f"{label}_compile.log")
            output=execute(["vvp",image,f"+folder={folder}"],HERE,evidence/f"{label}_simulation.log")
            if ("CIC_ADAPTER PASS" not in output or f"outputs={counts['outputs']}" not in output
                or f"packets={counts['packets']} responses={counts['packets']+3}" not in output):
                raise RuntimeError("Missing CIC adapter success marker")
            cic_results.append({"rate":rate,"stages":stages,"shift":shift,**counts})
            print(output.strip())
        folder=Path(temporary)/"cordic_adapter"
        folder.mkdir()
        cordic_results=cordic_fixtures(folder)
        image=folder/"test.vvp"
        execute(["iverilog","-g2012","-s","tb_cip_cordic_stream","-o",image,*sources,
                 HERE/"sim/tb_cip_cordic_stream.v"],HERE,evidence/"cordic_adapter_compile.log")
        output=execute(["vvp",image,f"+folder={folder}"],HERE,evidence/"cordic_adapter_simulation.log")
        if ("CORDIC_ADAPTER PASS words=756 packets=14 responses=32 stalls=111111" not in output):
            raise RuntimeError("Missing CORDIC adapter success marker")
        print(output.strip())
        for log_n in range(1,9):
            label=f"fft_adapter_n{1<<log_n}"
            folder=Path(temporary)/label
            folder.mkdir()
            counts=fft_fixtures(folder,log_n)
            image=folder/"test.vvp"
            execute(["iverilog","-g2012","-s","tb_cip_fft_stream",
                     f"-Ptb_cip_fft_stream.LOG_N={log_n}","-o",image,*sources,
                     HERE/"sim/tb_cip_fft_stream.v"],HERE,evidence/f"{label}_compile.log")
            output=execute(["vvp",image,f"+folder={folder}"],HERE,evidence/f"{label}_simulation.log")
            if ("FFT_ADAPTER PASS" not in output or f"words={counts['words']} packets=10 responses=43 stalls=1111" not in output):
                raise RuntimeError("Missing FFT adapter success marker")
            fft_results.append(counts)
            print(output.strip())
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):
        raise RuntimeError("Source changed during adapter tests")
    write_json(evidence / "result.json", {"status": "PASS", "modules": len(SPECS),
        "legacy_rejection_only": len(LEGACY_SPECS), "functional_adapters": list(FUNCTIONAL),
        "tested": "Placeholder rejection checks only when placeholders remain; registered functional DSP and image adapters: numeric outputs, commands/tags/errors/CE/backpressure/reset",
        "resampler_cases":resampler_results,"cic_cases":cic_results,"cordic":cordic_results,"fft_cases":fft_results,"source_sha256":hashes,
        "board": "not_run"})
    print(f"evidence={evidence}")


if __name__ == "__main__":
    main()
