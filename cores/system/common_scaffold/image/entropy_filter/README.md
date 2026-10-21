# 局部灰度 Shannon 熵

`entropy_filter_frame.sv` 对每个像素的 3×3、5×5 或 7×7 邻域建立完整 **256 灰阶直方图**，输出局部 Shannon entropy，单位 bits，unsigned Q20。它与 JPEG 熵编码、随机数熵源和全局 GLCM 特征不同。固定 WIDTH/HEIGHT 各 1..32，窗口尺寸逐帧可配置。边缘复制最近像素，不缩小边缘窗口，也不把输入灰度减少到少量等级。

实现已完成本地数值/协议仿真及隔离 Gowin 综合，尚未上板、布局布线或时序验收。

## 算法、精度和资源

对于窗口内像素数 n=9/25/49，灰阶 g 的出现次数 c[g]：

```
H = -sum((c[g]/n)*log2(c[g]/n)), g=0..255
term[n,c] = round_half_up(-c/n * log2(c/n) * 2^20)
m_entropy_q20 = sum(term[n,c[g]])
```

c=0 或 c=n 的贡献严格为 0。`generate_rom.py` 使用 Python Decimal 70 位精度生成 192×20 bit 窄 ROM；地址为 `{window_bank[1:0], count[5:0]}`，三个 bank 分别为 n=9/25/49。大于 n 的未使用项填 0；正常直方图不会访问它们。ROM 是可复现、已冻结的 `entropy.mem` 资产，不需要运行时计算浮点 log。

每个贡献最近舍入到 Q20，没有最终再次舍入。假设非零 bin 数为 B，熵误差不超过 `B/(2*2^20)` bits；B≤n，因此三种窗口的保守界分别为 0.000004291535、0.000011920929、0.000023365021 bits。实际逐像素误差及 SciPy/skimage 差异见 `test_evidence.json`。输出除以 1,048,576 即为 bits。量化结果可能略高于精确 `log2(n)`，在上述界内；不作上界截断掩盖误差。

直方图计数为 6 位，可容纳最多 49 个样本。单项 `-p log2(p)` 最大约 0.530738 bits，20 位 Q20 足够；有效项总和≤`log2(49)+49/2^21`，23 位 Q20 足够。常量窗口熵精确为 0，所有值互异时逼近 `log2(n)`。255 灰阶和 0 灰阶同样参与直方图。

RTL 先完整捕获灰度帧到同步 RAM。每个输出像素重新清零全部 256 bin，逐 tap 同步读取帧 RAM，再对同步直方图执行带等待周期的读改写，之后扫描全部 bin，通过同步 ROM 读取贡献并累加。没有异步帧读、异步直方图读或并行 256 项 log 电路；不宣称每周期一个像素。每像素无停顿约 256+5n+5×256 个核心周期，另外有输出/状态开销，CE 和输出背压可无限延长。

最大 32×32 隔离综合：372 LUT 类（含 117 ALU、16 MUX），191 FF，2 DPX9B + 1 SPX9，0 DSP；7×5 配置 390 LUT 类。两配置 `check -assert` 零问题，详见绑定 RTL/ROM 哈希的 `synthesis_evidence.json`。

## 接口、错误和恢复

START 的 `start_valid/start_ready` 握手锁存 `cfg_size`，只能是 3、5、7。配置随后可改变，不影响当前帧。START 清除旧响应元数据和错误。WIDTH/HEIGHT 越界时使用安全深度 1 并返回错误，不构建负深度存储器。

输入为 `s_pixel[7:0],s_valid,s_ready,s_sof,s_eol,s_last`，行优先，恰好 WIDTH×HEIGHT 像素；首像素 SOF、每行末 EOL、最终像素 LAST。错误标记被记住，仍消耗剩余 N 像素，然后失败 DONE，**不输出错误帧的任何像素**。

输出为 `m_entropy_q20[22:0],m_valid,m_ready,m_sof,m_eol,m_last`，与输入同尺寸/顺序。输出 valid 遇到背压或 CE=0 保持，熵值及全部标记同步保持。所有传输（含 START、输入、输出和 DONE）都要求 CE=1；上游/下游应只统计启用周期的 valid/ready 交集。输入/START ready 显式包含 rst_n 和 CE。

`done_valid` 保持到 CE=1 且 `done_ready=1`；busy 从接受 START 到 DONE 被接受保持为 1。DONE 阶段不接收新 START。错误码 1=非法静态/动态配置，2=输入标记错误，3=非法内部状态，4=直方图不可能的计数溢出。错误后接受 DONE，再完整发送新帧即可恢复。

低有效同步 `rst_n` 优先于 CE，CE=0 也能复位。复位取消当前帧和已产生的输出前缀；上游须清除尚未被接受的 valid。存储内容不复位，下一个完整捕获会覆盖所有会读到的帧像素，每个邻域重新清零直方图，避免旧帧污染。没有 abort 或超时端口；缺少输入时等待，复位可取消。

## 验证与命令

`run_tests.py` 独立使用 Counter/math.log2 建立每个像素的 256 bin 和定点参考；实际调用 SciPy `stats.entropy(base=2)` 与 skimage `filters.rank.entropy`。skimage 在显式 edge pad 后裁剪，保证完整复制边界窗口，与其默认边缘缩小行为不同。每次 RTL 开始扫描直方图时，测试台对全部 256 bin 和质量守恒逐项比较；所有输出 Q20 值和标记逐像素比较。

覆盖随机、常量、冲激、棋盘、近白低对比、窗口内全不同灰阶、全部核尺寸、1×1/单行/单列/32×32；192 个 ROM 项由独立 float 计算验证并复现 Decimal 生成文件；随机 CE、输入间隙、输出背压；配置锁存；非法配置、六类错误标记且无输出；所有处理状态/持久输出/DONE 的 CE0 reset 和不同 RAM 内容污染后的完整恢复；非法状态和直方图不可能计数故障显式失败。

```
python -B cores/system/common_scaffold/image/entropy_filter/generate_rom.py
python -B cores/system/common_scaffold/image/entropy_filter/run_tests.py
python -B cores/system/common_scaffold/image/entropy_filter/run_synthesis.py
```

生成和综合只使用自动清理的 TemporaryDirectory，保留紧凑 JSON 证据、源码、窄 ROM 和说明。未修改共享 runner/.f、原 48 项或密码学源码，也未访问 JTAG。

网络参考：已读取 scikit-image 官方 rank.entropy 文档，公式及 n_bins 语义作为算法参考；实际 SciPy 与 skimage 调用均执行于测试。来源和网络获取状态见 `references.json`。代码独立编写，无上游源码复制。
