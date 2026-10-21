# 同步 3×3 窗口

`img_window3x3_valid_draft` 使用两行同步 RAM 和每行两个历史像素，输出
row-major 3×3 窗口。`m_taps[n*PIXEL_W +: PIXEL_W]` 的 n=0..8 对应
左上到右下；`m_center` 为中心像素，`m_x/m_y` 为原图中心坐标。

仅裁边输出：W×H 原图产生 (W−2)×(H−2) 个窗口，中心坐标从 (1,1)
到 (W−2,H−2)。`m_sof`/`m_eol` 按裁边结果重新生成，`m_eof` 标最后一个
窗口。它不是原尺寸 ZERO/REPLICATE 填充窗口。Bayer 需要据 `m_x/m_y`
传中心坐标奇偶；滤波器直接使用 `m_taps`。不自动改变 Bayer 排列定义。

原生共同 CE 协议，所有握手均为 `clk_en && valid && ready`。先握手
`cfg_valid/ready`，输入非零宽高且均至少 3；宽度不能超过 MAX_WIDTH。
之后发送完整 W×H 像素，输入 SOF/EOL 必须符合配置。输入每像素先发
同步行读，下一 enabled beat 更新行存储与横向历史，II 至少为 2；输出
背压时继续等待，不能按 II=1 连续源直接连接。

帧响应 `rsp_valid/ready` 等到最后一个窗口被下游接受后才发出。
`rsp_error=0` 表示正常帧处理结束，1=配置错误，2=输入帧标记
错误，3=内部状态错误。标记错误仍按配置像素数消费并输出，使用方须丢弃
错误帧。缺少像素会等待，没有超时或自动重同步。异步复位取消在途帧，
不清 RAM；计数逻辑在前两行禁止发布窗口以隔离旧内容。

窗口随 RAW8/10/12×四相 Bayer 前端通过小图独立整数参考组级回归，包含 CE、背压、标记错误及响应时序。运行 `python cores/system/common_scaffold/image/pipelines/run_group_regression.py` 保留新的时间目录证据；该检查不等于独立窗口穷举验收。2026-10-17 的v70窗口/八滤波与v84完整RAW Bayer有限帧候选均通过修正时序库50MHz门限及三次独立SRAM/UART核对；此为限定参数的整链证据。旧 draft 文件名保留兼容。

完整 RAW 前端板测证据：`../../board/tang25k/build/image_bayer_frame_selftest_25k_20261017_v84_porreg/board_validation_summary.json`。RAW8/10/12、四排列、13帧/实例，总1941输入与1035 RGB，最大11×8；六个生产行RAM映射SPX9。实际50MHz，每16拍启用13拍；完整自检top为3149 LUT/1621 FF/14 BRAM/0 DSP，修正库最低54.68MHz/hold通过。该资源包含三lane及ROM/checker/UART，不是单窗口资源；不代表默认1920宽、padding或持续视频签核。生产窗口RTL与板测候选逐字节相同。
