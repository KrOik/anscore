# 可配置复数 Gabor 帧卷积

实际灰度复数 Gabor 滤波：主机生成实部和正交虚部系数，RTL 对两者分别完成完整二维卷积，输出带符号实部/虚部响应。支持逐帧重新配置方向、波长、相位、Gaussian sigma、纵横比和量化精度；这些参数通过主机生成的系数进入 RTL。不是仅返回输入或固定方向差分的占位实现。

本模块完成本地功能仿真及隔离 Gowin 综合；**尚未上板验收**。未修改共享注册表、原 48 项或密码学模块。

## 算法与数值

对核坐标 `x,y = -r..r`：

```
xr = x*cos(theta) + y*sin(theta)
yr = -x*sin(theta) + y*cos(theta)
g  = exp(-0.5*((xr/sigma)^2 + (gamma*yr/sigma)^2))
real = g*cos(2*pi*xr/wavelength + phase)
imag = g*sin(2*pi*xr/wavelength + phase)
```

`coefficients.py` 将每个分量乘 `2^fraction`，最近舍入、恰半远离零，检查 signed16 溢出并拒绝，绝不静默截断。角度单位为弧度；核边长 1/3/5/7，fraction 0..14，sigma 0.05..32，wavelength 0.1..128，gamma 0.05..16。非有限数和越界值拒绝。

`--zero-dc` 在浮点采样核上分别减均值，再独立量化；量化后可能有少量 DC 残差，JSON 的 `dc_quantized` 明确报告，不承诺量化核严格零和。没有强制 L1/能量归一化，输出增益由核决定。

行优先核系数 `C[j,i]` 对应真正卷积：

```
A[y,x] = sum(C[j,i] * image[clamp(y+r-j), clamp(x+r-i)])
out = sign(A) * floor((abs(A) + (shift ? 2^(shift-1) : 0)) / 2^shift)
```

边界采用复制最近像素。1×1、单行、单列及比图像更大的核均合法。输出两个 signed32 响应；不进行 8 位饱和、取绝对值、幅度或相位计算，后续纹理/方向能量模块可使用这两个正交响应。

RTL 也接受全部 signed16 自定义卷积系数，`cfg_shift` 0..20。单积范围 `[-8,355,840, 8,355,585]`，49 项累加范围 `[-409,436,160, 409,423,665]`，signed32 累加充分。舍入使用 33 位无符号绝对值和加法，最大半单位 `2^19`，不会溢出。实时复数乘法由一个串行移位加法器依次处理每个 tap 的两个分量，无 DSP。

## 事务与恢复

固定参数 WIDTH/HEIGHT 各 1..32。非法静态尺寸使用安全深度 1，START 返回错误，不构建零/负深度数组。

所有传输都要求 `rst_n && ce && valid && ready`（输出及 DONE 也仅在 CE=1 时接受）。`rst_n` 为低有效同步复位，优先于 CE；CE=0 时保持状态、输出、DONE 和存储读寄存器。上游必须在复位时清除尚未接受的 valid。`busy` 从接受 START 到 DONE 被接受一直为 1。

1. START：`start_valid/start_ready`；锁存 `cfg_size` 和 `cfg_shift`，配置之后可改变。每次接受 START 都清除旧输出元数据与错误。
2. 核上传：`c_valid/c_ready`；`c_real,c_imag` 为 signed16。必须传恰好 size² 个系数，行优先，只有首项 `c_first=1`、末项 `c_last=1`。未处于核上传状态时不接受系数。
3. 帧上传：`s_valid/s_ready`；恰好 WIDTH×HEIGHT 个灰度像素，行优先，首像素 SOF、每行末 EOL、最终像素 LAST。
4. 处理与输出：同步帧 RAM、同步复数系数 RAM，逐像素、逐 tap 两次 8 周期串行乘法。输出 `m_real,m_imag,m_sof,m_eol,m_last,m_valid`；受背压或 CE=0 时全部保持，直到 CE=1 且 m_ready=1。
5. DONE：`done_valid` 保持至 CE=1 且 done_ready=1，返回空闲。DONE 阶段不再接受 START/系数/像素。无超时和 abort 端口；缺少输入会正常等待，复位可取消任意阶段。

错误码：0 成功；1 非法静态/动态配置；2 核标记错误；3 帧标记错误；4 非法内部状态。核标记错误立即 DONE，不继续发送剩余核；帧标记错误继续接收完整 N 像素，然后错误 DONE，**无任何输出前缀**。消费者不应对错误帧继续等待像素。错误后 DONE 握手，再上传完整新核及帧即可恢复，不依赖旧 RAM 内容。

## 独立参考与验证

`run_tests.py` 使用独立逐 tap 整数 oracle 产生每个像素的预期响应、符号和标记，同时实际调用：

- SciPy `signal.convolve2d`：先明确 edge pad，valid 卷积；所有原始整数响应完全一致。
- OpenCV `filter2D`：OpenCV 运算是相关，因此先反转量化核，再用 CV_64F 和 BORDER_REPLICATE；原始响应误差小于 1e-5。
- OpenCV `getGaborKernel`：上游源码将坐标倒序存入 Mat，本生成器使用自然坐标，比较前翻转 Mat；虚部使用相位 `phase-pi/2` 的 cosine 核。12 组复数系数逐项量化完全一致。

覆盖常量、冲激、棋盘、随机、负/正满幅系数、49 项最坏累加、正负恰半舍入、1×1/单行/单列/32×32、全部核尺寸、不同 shift；随机 CE/输入空隙/输出背压，配置锁存，错误标记无输出、持久 DONE、非法状态、全阶段 CE=0 reset 和不同内容污染 RAM 后完整恢复。详细数量与实际版本见 `test_evidence.json`。

```
python -B cores/system/common_scaffold/image/gabor_filter/coefficients.py --size 7 --theta 0.785398 --phase 0.3 --fraction 12
python -B cores/system/common_scaffold/image/gabor_filter/run_tests.py
python -B cores/system/common_scaffold/image/gabor_filter/run_synthesis.py
```

综合在 7×5 和 32×32 配置执行 `synth_gowin -top synth_top -nodsp; check; stat`，计入所有 LUT/MUX/ALU 后均低于 15K，DSP=0；完整单元计数与 RTL 哈希见 `synthesis_evidence.json`。这是隔离面积检查，不宣称 P&R 时序或板上性能。两块同步存储在最大配置映射为 SPX9 + DPX9B。测试/综合生成文件全部置于自动清理临时目录，只保留紧凑 JSON 证据。

网络参考来源与读取内容哈希见 `references.json`。实现独立编写，未拷贝上游代码。
