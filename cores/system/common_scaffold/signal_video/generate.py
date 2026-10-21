"""Generate legacy templates; preserve functional adapters; --check is read-only."""
import argparse
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
FUNCTIONAL = {
    'cip_image_window': {'dependencies': ['../image/window/img_window3x3_valid_draft.v'], 'limitations': 'Cropped3x3 windows serialized as nine full-width words, two synchronous row memories; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_framebuffer': {'dependencies': [], 'limitations': 'External-memory aligned32-bit frame capture/replay/write/read with stride and single outstanding request; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_dehaze': {'dependencies': ['../image/dehaze/img_dh_dehaze_frame.v', '../image/dehaze/img_dh_guided_refine.v'], 'limitations': 'RGB full DCP frame pipeline, manual/auto atmosphere and optional guided transmission; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_dark_channel': {'dependencies': ['rtl/cip_image_dehaze_scalar_frame.v'], 'limitations': 'RGB min then replicated-border spatial min, runtime radius; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_transmission': {'dependencies': ['rtl/cip_image_dehaze_scalar_frame.v', '../image/dehaze/img_dh_transmission.v'], 'limitations': 'Scalar dark/A transmission, distinct from full normalized RGB DCP; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_recover': {'dependencies': ['rtl/cip_image_dehaze_scalar_frame.v', '../image/dehaze/img_dh_restore.v'], 'limitations': 'RGB radiance restoration with paired auxiliary Q1.15 transmission; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_guided_filter': {'dependencies': ['../image/filters/rtl/img_filter_guided.v', '../image/dehaze/img_dh_guided_frame.v', '../image/dehaze/img_dh_guided_refine.v'], 'limitations': 'Gray8 paired source/guide two-pass local-statistics filter, radius0..3; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_nlm_denoise': {'dependencies': ['../image/filters/rtl/img_filter_nlm.v', '../image/filters/rtl/img_filter_nlm_serial_engine.v', '../image/filters/rtl/img_filter_exp_weight.v'], 'limitations': 'Gray1..12 full search/patch SSD exponential-weight NLM; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_affine': {'dependencies': ['rtl/cip_image_projective_frame.v', '../image/geometry/rtl/img_geo_frame_buffered.v'], 'limitations': 'Atomic signed Q16.16 inverse affine matrix load and nearest/bilinear sampling; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_perspective': {'dependencies': ['rtl/cip_image_projective_frame.v', '../image/geometry/rtl/img_geo_frame_buffered.v'], 'limitations': 'Atomic signed Q16.16 inverse homography load, division and nearest/bilinear sampling; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_stitch': {'dependencies': ['../image/multiframe/img_mf_auto_stitch.v', '../image/multiframe/img_mf_dual_frame_store.v', '../image/multiframe/img_mf_translation_sad.v'], 'limitations': 'RGB fixed-shape extended-canvas SAD integer translation registration/manual offset stitching; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_super_resolution': {'dependencies': [], 'limitations': 'Gray8 programmable four-convolution compact subpixel2x CNN, trained quantized weights required; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_scaler': {'dependencies': ['../image/geometry/rtl/img_geo_frame_buffered.v', 'rtl/cip_image_bicubic_frame.v'], 'limitations': 'Runtime-size packed-channel nearest/bilinear/Catmull-Rom bicubic scaling with Q8 asymmetric coordinates; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_downsample': {'dependencies': ['../image/geometry/rtl/img_geo_area_resample.v', '../image/geometry/rtl/img_geo_crop_decimate.v', '../image/geometry/rtl/geo_serial_divider.v'], 'limitations': 'Exact antialiased area reduction or integer-step point decimation, packed unsigned channels; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_upsample': {'dependencies': ['../image/geometry/rtl/img_geo_integer_upsample.v'], 'limitations': 'Packed8-bit integer1..15x bilinear upsampling; not learned super-resolution; see FUNCTIONAL_IMAGE_ABI.md'},
    'cip_image_clahe': {'dependencies': ['rtl/cip_image_clahe_frame.v', '../image/histogram/rtl/img_hist_ratio_u8.v', '../image/histogram/rtl/img_hist_clahe_interp.v', '../image/histogram/rtl/img_hist_serial_multiply.v'], 'limitations': 'Runtime-size gray8 strict clipped multi-tile CDF with actual-center interpolation with odd and partial edge tiles; see FUNCTIONAL_IMAGE_ABI.md'},
    "cip_image_canny": {
        "dependencies": ["../image/filters/rtl/img_edge_canny.v"],
        "limitations": "Same-size gray Canny, GRAY_BITS1..12 in DATA_W<=32 transport, full8-connected hysteresis; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_bilateral_filter": {
        "dependencies": ["rtl/cip_image_bilateral_frame.v", "../image/window/img_window3x3_valid_draft.v", "../image/filters/rtl/img_filter_bilateral3x3.v", "../image/filters/rtl/img_filter_exp_weight.v"],
        "limitations": "Cropped3x3 scalar bilateral, GRAY_BITS1..12 in DATA_W<=32 transport, Q8.8 sigmas; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_temporal_denoise": {
        "dependencies": ["../image/filters/rtl/img_filter_temporal_denoise.v"],
        "limitations": "Scalar grayscale recursive filtered-history temporal blend with motion bypass and fresh-history mode; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_osd": {
        "dependencies": ["../image/multiframe/img_mf_rgb_blend_pipe.v"],
        "limitations": "Full-raster RGB888 alpha/color-key overlay and bypass, upstream rasterized assets required; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_fusion": {
        "dependencies": ["../image/multiframe/img_mf_rgb_blend_partial_pipe.v", "../image/multiframe/cip_fusion_scalar_multiply.v"],
        "limitations": "Co-registered two-frame scalar/RGB888 Q8 weighted fusion, atomic stream pairing and rounded exact arithmetic; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_background_model": {
        "dependencies": [],
        "limitations": "Internal synchronous Qn.8 EWMA grayscale model, foreground freeze and background/difference/mask/lossless-model outputs; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_frame_difference": {
        "dependencies": [],
        "limitations": "Scalar unsigned grayscale paired/history absolute difference or strict-threshold mask, runtime frames and synchronous history RAM; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_mirror_flip": {
        "dependencies": ["rtl/cip_image_permute_frame.v"],
        "limitations": "Word-preserving identity/horizontal/vertical/both frame permutation, runtime bounded dimensions; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_rotate": {
        "dependencies": ["rtl/cip_image_permute_frame.v", "rtl/cip_image_rotate_angle_frame.v", "../image/geometry/rtl/img_geo_frame_buffered.v"],
        "limitations": "Lossless right-angle rotation and centered signed-Q16.16 arbitrary-angle nearest/bilinear sampling; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_histogram": {
        "dependencies": ["rtl/cip_image_histogram_frame.v", "../image/histogram/rtl/img_hist_ratio_u8.v"],
        "limitations": "Gray8 runtime-size frame histogram, 256 lossless serialized unsigned 32-bit bin counts; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_he": {
        "dependencies": ["rtl/cip_image_histogram_frame.v", "../image/histogram/rtl/img_hist_ratio_u8.v"],
        "limitations": "Gray8 runtime-size same-frame normalized CDF-min HE, constant-frame preservation; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_morphology": {
        "dependencies": ["rtl/cip_image_morph_frame.v"],
        "limitations": "Bounded same-size grayscale erode/dilate/open/close/gradient with programmable 3x3 mask; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_sobel": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_edge_gradient3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "Cropped grayscale Sobel, display or lossless serialized Gx/Gy/L1 magnitude; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_prewitt": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_edge_gradient3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "Cropped grayscale Prewitt, display or lossless serialized Gx/Gy/L1 magnitude; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_laplacian": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_edge_laplacian3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "Cropped four-neighbor Laplacian, absolute display or lossless signed response; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_mean_filter": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_filter_kernel3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "Rounded 3x3 grayscale mean, synchronous row buffers and cropped frame output; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_gaussian_filter": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_filter_kernel3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "Rounded fixed 3x3 Gaussian, synchronous row buffers and cropped frame output; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_median_filter": {
        "dependencies": ["rtl/cip_image_window_filter_frame.v", "../image/filters/rtl/img_filter_kernel3x3.v", "../image/window/img_window3x3_valid_draft.v"],
        "limitations": "3x3 grayscale median, synchronous row buffers and cropped frame output; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_bayer_demosaic": {
        "dependencies": ["../image/pipelines/img_bayer_window_frontend_draft.v"],
        "limitations": "RAW8/10/12 low-bit input to cropped RGB888, four Bayer phases; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_awb": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "../image/isp/img_isp_awb_auto.v"],
        "limitations": "RGB888 gray-world feedback, previous-frame gains; completion waits for next-frame update; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_gamma": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "../image/isp/img_isp_gamma_lut.v"],
        "limitations": "RGB888, double-buffered atomic 768-byte RGB LUT loading and frame-boundary enable/bypass; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_ccm": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "../image/isp/img_isp_ccm.v"],
        "limitations": "RGB888, atomic 12-word signed Q6.10 matrix/integer-bias bank load and same-size frames; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_color_convert": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "../image/isp/img_isp_colorspace.v"],
        "limitations": "RGB888 <-> approximate BT.601 full-range YCbCr444, mode0/1; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_brightness_contrast": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "rtl/cip_rgb_brightness_contrast.v"],
        "limitations": "RGB888, signed brightness, unsigned Q8.8 contrast, configurable pivot; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_invert": {
        "dependencies": ["rtl/cip_image_pointwise_frame_ctrl.v", "../image/geometry/rtl/img_geo_pixel_invert.v"],
        "limitations": "1..32-bit masked inversion, same-size stream frames; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_image_threshold": {
        "dependencies": ["rtl/cip_image_threshold_fixed.v", "../image/histogram/rtl/img_hist_otsu_frame.v", "../image/pipelines/img_adaptive_threshold_frame.v"],
        "limitations": "Fixed, same-frame Otsu and cropped adaptive mean/Gaussian modes; grayscale and bounded dimensions; see FUNCTIONAL_IMAGE_ABI.md",
    },
    "cip_fft_stream": {
        "dependencies": ["../dsp/rtl/cip_dsp_fft.v", "../dsp/rtl/cip_dsp_fft_twiddle.v"],
        "limitations": "16-bit serialized words, fixed elaborated 2..256-point FFT/IFFT; see FUNCTIONAL_DSP_ABI.md",
    },
    "cip_cordic_stream": {
        "dependencies": ["../dsp/rtl/cip_dsp_cordic.v"],
        "limitations": "16-bit words, paired x/y input and lossless six-word result; see FUNCTIONAL_DSP_ABI.md",
    },
    "cip_cic_decimator": {
        "dependencies": ["../dsp/rtl/cip_dsp_cic_decimator.v"],
        "limitations": "Parameterized CIC with shifted saturated legacy-width output; see FUNCTIONAL_DSP_ABI.md",
    },
    "cip_resampler_stream": {
        "dependencies": ["../dsp/rtl/cip_dsp_resampler.v"],
        "limitations": "Polyphase FIR; fixed elaborated UP/DOWN, full packet tail; see FUNCTIONAL_DSP_ABI.md",
    },
    "cip_iir_biquad_stream": {
        "dependencies": ["../dsp/rtl/cip_dsp_iir_biquad.v"],
        "limitations": "Signed direct-form-I biquad; see FUNCTIONAL_DSP_ABI.md for commands and formats",
    },
    "cip_fir_stream": {
        "dependencies": ["../dsp/rtl/cip_dsp_fir.v"],
        "limitations": "Signed serial FIR; see FUNCTIONAL_DSP_ABI.md for commands and formats",
    },
}
SPECS = [
    ("cip_fir_stream", "signal", "FIR filtering; coefficient bank/loading pending"),
    ("cip_iir_biquad_stream", "signal", "Biquad filter; coefficients/scaling pending"),
    ("cip_fft_stream", "signal", "FFT/IFFT; length, scaling and ordering pending"),
    ("cip_cic_decimator", "signal", "CIC decimation; rate/stages/scaling pending"),
    ("cip_resampler_stream", "signal", "Rational resampling; phase/filter pending"),
    ("cip_cordic_stream", "signal", "CORDIC; rotation/vectoring formats pending"),
    ("cip_image_dehaze", "image", "Dehaze pipeline: dark channel, atmosphere, transmission, recovery pending"),
    ("cip_image_dark_channel", "image", "RGB minimum plus spatial minimum; window/edge handling pending"),
    ("cip_image_transmission", "image", "Transmission estimate/refinement; guided filter pending"),
    ("cip_image_recover", "image", "Recover radiance with atmospheric light and transmission floor pending"),
    ("cip_image_scaler", "image", "Arbitrary scaling; nearest/bilinear/bicubic selection pending"),
    ("cip_image_rotate", "image", "90/180/270 and arbitrary rotation; inverse mapping/frame buffer pending"),
    ("cip_image_downsample", "image", "Filtered decimation; low-pass and integer/rational rates pending"),
    ("cip_image_upsample", "image", "Interpolation upsampling; nearest/bilinear/bicubic pending"),
    ("cip_image_super_resolution", "image", "Model-based super-resolution; weights, tiling and inference pending"),
    ("cip_image_window", "image", "Line-buffered windows; kernel and border policy pending"),
    ("cip_image_color_convert", "image", "RGB/YUV conversion; matrix, range and rounding pending"),
    ("cip_image_framebuffer", "image", "Frame-store arbitration and read/write scheduling pending"),
    ("cip_image_bayer_demosaic", "image", "Bayer interpolation; RGGB/BGGR/GRBG/GBRG and 8/10/12-bit modes pending"),
    ("cip_image_gamma", "image", "Gamma correction; per-channel LUT loading and frame-atomic bank switch pending"),
    ("cip_image_awb", "image", "Automatic white balance; statistics, gain estimation and clipping pending"),
    ("cip_image_ccm", "image", "3x3 signed color correction matrix, offsets, rounding and saturation pending"),
    ("cip_image_histogram", "image", "Histogram accumulation, bin readback and per-frame bank switch pending"),
    ("cip_image_he", "image", "Histogram equalization; CDF/LUT mapping and frame buffering pending"),
    ("cip_image_clahe", "image", "CLAHE; tiles, clip redistribution and LUT interpolation pending"),
    ("cip_image_brightness_contrast", "image", "Brightness offset and contrast gain about configurable pivot pending"),
    ("cip_image_mean_filter", "image", "Spatial mean filtering and border policy pending"),
    ("cip_image_gaussian_filter", "image", "Spatial Gaussian filtering; separable coefficients and borders pending"),
    ("cip_image_median_filter", "image", "Spatial median filtering; kernel shape and borders pending"),
    ("cip_image_bilateral_filter", "image", "Bilateral denoising; spatial/range weights and normalization pending"),
    ("cip_image_guided_filter", "image", "Guided edge-preserving filter; guide input and local statistics pending"),
    ("cip_image_temporal_denoise", "image", "Temporal denoising; prior frame and motion-sensitive weighting pending"),
    ("cip_image_nlm_denoise", "image", "Non-local means; search/patch windows and weight normalization pending"),
    ("cip_image_sobel", "image", "Sobel gradients, magnitude and signed range pending"),
    ("cip_image_prewitt", "image", "Prewitt gradients, magnitude and signed range pending"),
    ("cip_image_canny", "image", "Gaussian, gradient, NMS, dual thresholds and connected hysteresis pending"),
    ("cip_image_laplacian", "image", "Laplacian edge detection and signed response pending"),
    ("cip_image_threshold", "image", "Binarization; fixed, Otsu and adaptive threshold modes pending"),
    ("cip_image_morphology", "image", "Erode, dilate, open, close and gradient; binary/grayscale kernels pending"),
    ("cip_image_affine", "image", "Affine transform; inverse mapping, interpolation and frame store pending"),
    ("cip_image_mirror_flip", "image", "Horizontal mirror and vertical flip; line/frame reorder pending"),
    ("cip_image_invert", "image", "Intensity inversion; channel mask and bit-depth range pending"),
    ("cip_image_perspective", "image", "Projective rectification; inverse homography, division and borders pending"),
    ("cip_image_osd", "image", "OSD alpha/key overlay; foreground stream/assets and placement pending"),
    ("cip_image_frame_difference", "image", "Frame difference; previous frame, threshold and optional mask pending"),
    ("cip_image_background_model", "image", "Background update/model; learning rate and foreground mask pending"),
    ("cip_image_stitch", "image", "Image stitching; calibrated transforms, overlap, seam/blend pending"),
    ("cip_image_fusion", "image", "Image fusion; aligned dual inputs, weighting and output normalization pending"),
]


def rtl(name, family, description):
    image = family == "image"
    config = ("""    input wire [15:0] cfg_src_width, cfg_src_height,
    input wire [15:0] cfg_dst_width, cfg_dst_height,
    input wire [3:0] cfg_mode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire [31:0] cfg_frame_base, cfg_frame_stride,
    input wire [31:0] cfg_aux_base,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [15:0] coeff_addr,
    input wire [31:0] coeff_data,
    input wire [DATA_W-1:0] aux_data,
    input wire aux_valid, aux_sof, aux_eol,
    output wire aux_ready,
    output wire mem_req_valid, mem_req_write,
    output wire [31:0] mem_req_addr, mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_req_ready, mem_rsp_valid,
    input wire [31:0] mem_rsp_rdata,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    input wire s_sof, s_eol,
    output wire m_sof, m_eol,
""" if image else """    input wire [7:0] cfg_opcode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire s_last,
    output wire m_last,
""")
    last_in, last_out = ("s_eol", "m_eol") if image else ("s_last", "m_last")
    extra = ("assign m_sof = 1'b0;\nassign mem_req_valid = 1'b0;\n"
             "assign mem_req_write = 1'b0;\nassign mem_req_addr = 32'b0;\n"
             "assign mem_req_wdata = 32'b0;\nassign mem_req_wstrb = 4'b0;\n"
             "assign mem_rsp_ready = 1'b0;\nassign coeff_ready = 1'b0;\nassign aux_ready = 1'b0;\n") if image else ""
    return f"""// Generated by signal_video/generate.py. Status: PLACEHOLDER, not functional.
// {description}
// Configuration is reserved and currently ignored; ALL commands return UNSUPPORTED.
// Native shared-CE protocol. No pixels/samples or memory requests are accepted.
module {name} #(parameter DATA_W={24 if image else 16}, parameter TAG_W=8)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [TAG_W-1:0] rsp_tag,
    output wire [1:0] rsp_error,
{config}    input wire [DATA_W-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid,
    input wire m_ready
);
{extra}cip_unsupported_stream #(.DATA_W(DATA_W), .TAG_W(TAG_W)) guard (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_tag(cmd_tag),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_tag(rsp_tag), .rsp_error(rsp_error),
    .s_data(s_data), .s_valid(s_valid), .s_last({last_in}), .s_ready(s_ready),
    .m_data(m_data), .m_valid(m_valid), .m_last({last_out}), .m_ready(m_ready)
);
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files = {HERE / "rtl" / f"{name}.v": rtl(name, family, desc)
             for name, family, desc in SPECS if name not in FUNCTIONAL}
    for name in FUNCTIONAL:
        if not (HERE / "rtl" / f"{name}.v").is_file():
            raise SystemExit(f"missing hand-maintained functional adapter: {name}")
    manifest = {"schema_version": 1, "modules": [
        {"name": name, "path": f"rtl/{name}.v", "status": "functional" if name in FUNCTIONAL else "placeholder", "family": family,
         "dependencies": FUNCTIONAL[name]["dependencies"] if name in FUNCTIONAL else ["../common/rtl/cip_unsupported_stream.v"],
         "limitations": FUNCTIONAL[name]["limitations"] if name in FUNCTIONAL else desc,
         "simulation": "functional adapter test in run_tests.py" if name in FUNCTIONAL else "see run_tests.py evidence; not a functional algorithm test", "board": "not_run"}
        for name, family, desc in SPECS]}
    files[HERE / "manifest.json"] = json.dumps(manifest, indent=2) + "\n"
    for path, content in files.items():
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                raise SystemExit(f"generated file differs: {path}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    print(f"SIGNAL_VIDEO_GENERATED {'CHECK' if args.check else 'WRITE'} PASS modules={len(SPECS)}")


if __name__ == "__main__":
    main()
