# GW2A-18C wave2 IP package (40 units)

Vision / communication / system / reliability / BNN selftest IPs for Tang Primer 20K (GW2A-LV18PG256C8/I7, 27 MHz).  Each package wraps the validated `st_<unit>` selftest cell; golden digests come from independent Python models in `../tools/`.

Evidence: `../doc/VALIDATION_LOG.md`, unit dumps in `../sim/`.

| # | IP | tag | digest | description |
|---|---|---|---|---|
| 0 | `gw2a_w2_isp_dpc` | DPC | `660DE1FA` | ISP defect-pixel correction |
| 1 | `gw2a_w2_isp_demosaic` | DEM | `43C5DA1F` | Bayer demosaic (RGGB) to RGB via neighbor averaging on a 3x3 window |
| 2 | `gw2a_w2_isp_awb` | AWB | `AF39F01C` | Auto white balance |
| 3 | `gw2a_w2_isp_gamma` | GAM | `61B5D82E` | Gamma correction via 256-entry LUT stored in BSRAM (DPX9B) |
| 4 | `gw2a_w2_isp_csc` | CSC | `CE41D92D` | RGB<->YCbCr color-space conversion, fixed-point 8 |
| 5 | `gw2a_w2_isp_rgb2gray` | GRY | `9D413162` | RGB to grayscale |
| 6 | `gw2a_w2_canny_grad` | CGR | `9764CD67` | Canny stage 1 |
| 7 | `gw2a_w2_canny_nms` | NMS | `E28D6593` | Canny stage 2 |
| 8 | `gw2a_w2_canny_dth` | DTH | `E2A5329F` | Canny stage 3 |
| 9 | `gw2a_w2_canny_hyst` | HYS | `6785454B` | Canny stage 4 |
| 10 | `gw2a_w2_feat_harris` | HAR | `AB859D8F` | Harris corner response from Ix/Iy window products |
| 11 | `gw2a_w2_feat_fast` | FST | `E1DEB6B0` | FAST feature detector |
| 12 | `gw2a_w2_feat_lbp` | LBP | `45C677F3` | Local binary pattern |
| 13 | `gw2a_w2_feat_hog` | HOG | `0AB2FBF5` | Histogram of oriented gradients over image cells |
| 14 | `gw2a_w2_img_integral` | INT | `18ED7B54` | Integral (summed-area) image for O(1) box filters |
| 15 | `gw2a_w2_img_scaler` | SCL | `A34F3413` | Nearest/bilinear image scaler with configurable ratio |
| 16 | `gw2a_w2_img_histogram` | HST | `F14561DD` | 256-bin image histogram with backpressured clear |
| 17 | `gw2a_w2_hist_clahe` | CLA | `A267A0F3` | Contrast-limited adaptive histogram equalization |
| 18 | `gw2a_w2_match_sad` | SAD | `A661F628` | Template matching by sum-of-absolute-differences search |
| 19 | `gw2a_w2_img_crop` | CRP | `450E7855` | Axis-aligned region-of-interest crop on a pixel stream |
| 20 | `gw2a_w2_frame_diff` | FDIF | `6A760EBD` | Frame differencing |
| 21 | `gw2a_w2_bg_model` | BGS | `17CD4105` | Running-average background model with foreground mask |
| 22 | `gw2a_w2_mot_bbox` | BBOX | `221B2F39` | Motion bounding box |
| 23 | `gw2a_w2_ccl_bbox` | CCL | `84EA8E24` | Connected-component labeling with per-label bounding boxes (two-pass, union-find in w2_dpram banks) |
| 24 | `gw2a_w2_meas_proj` | PRJ | `1DBD11E7` | Row/column projection (histogram profile) of a binary image |
| 25 | `gw2a_w2_can_ctrl` | CAN | `DC301204` | CAN 2 |
| 26 | `gw2a_w2_eth_mac_mii` | MAC | `7DC3E176` | Ethernet MAC, MII nibble interface, preamble/FCS handling |
| 27 | `gw2a_w2_pwm_gen` | PWM | `89356055` | PWM generator with programmable period/duty |
| 28 | `gw2a_w2_qei_dec` | QEI | `6E057083` | Quadrature encoder interface |
| 29 | `gw2a_w2_step_drv` | STP | `AAF87DCF` | Stepper motor driver |
| 30 | `gw2a_w2_dma_sg` | DMA | `92C91DF3` | Scatter-gather DMA |
| 31 | `gw2a_w2_ila_core` | ILA | `17852826` | Integrated logic analyzer |
| 32 | `gw2a_w2_crc32_eth` | CRC | `CE9832E0` | Ethernet CRC32 (0xEDB88320) serial/byte engine |
| 33 | `gw2a_w2_prbs31` | PRBS | `DBA2F926` | PRBS31 generator/checker for link test |
| 34 | `gw2a_w2_mem_bist` | MBST | `C9D87DF5` | Memory BIST |
| 35 | `gw2a_w2_bnn_conv3x3` | BC3 | `CE422C28` | Binarized 3x3 convolution |
| 36 | `gw2a_w2_bnn_dense` | BDN | `8792E554` | Binarized dense layer |
| 37 | `gw2a_w2_tmr_voter` | TMR | `DCA39FBD` | Triple-modular-redundancy voter with per-input disagreement flags |
| 38 | `gw2a_w2_wdt_win` | WDT | `B93E6C10` | Window watchdog |
| 39 | `gw2a_w2_lfsr_prng` | LFSR | `9867D947` | LFSR/PRNG with programmable taps and seed |
