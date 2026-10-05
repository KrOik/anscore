# isp/scale — polyphase video scaler (36-tap)

Status: RTL + bit-exact model + simulation regression passing (13 configs x
3 stall profiles + checker-mutation proof). Isolated `synth_gowin` runs;
**P&R, board verification and production integration not yet done**.

`scale_poly6_stream.v` is a separable 6x6-tap Lanczos-3 scaler: each output
pixel is computed from a 6x6 = 36-pixel neighbourhood, unlike the common
4-point bilinear kernel. RGB888, runtime image dimensions, stream handshake
per `infra/stream` contract.

Files:

- `scale_poly6_stream.v` — RTL (line banks, vertical sweep, horizontal
  polyphase window, output drain, runtime divider/config)
- `scale_lanczos3.vh` — generated 64-phase x 6-tap Q1.11 coefficient table
- `gen_scale_coeffs.py` — regenerates the table + `scale_coeffs.json`
- `scale_model.py` — bit-exact golden model
- `tb_scale_poly6.sv` — stream testbench (random input gaps / output stalls)
- `test_scale.py` — regression driver; writes `evidence/sim_<ts>/`
- `SPEC.md` — interface, algorithm, limits, verification

Integration sketch:

```verilog
scale_poly6_stream #(.MAX_W(1920)) scaler (
    .clk(pixclk), .rst_n(rst_n),
    .s_tdata(rgb_in), .s_tvalid(in_v), .s_tuser(in_sof),
    .s_tlast(in_eol), .s_tready(in_rdy),
    .m_tdata(rgb_out), .m_tvalid(out_v), .m_tuser(out_sof),
    .m_tlast(out_eol), .m_tready(out_rdy),
    .cfg_valid(cfg_v), .cfg_ready(cfg_rdy),
    .cfg_in_w(12'd1280), .cfg_in_h(12'd720),
    .cfg_out_w(12'd1920), .cfg_out_h(12'd1080),
    .cfg_done(), .cfg_error(), .marker_error(), .busy());
```

Quick check:

```
python cores/signal_processing/dsp_isp_library/isp/scale/gen_scale_coeffs.py   # regen coeffs
python cores/signal_processing/dsp_isp_library/isp/scale/test_scale.py         # sim regression
python cores/signal_processing/dsp_isp_library/isp/scale/synth_scale.py        # synth reports
```
