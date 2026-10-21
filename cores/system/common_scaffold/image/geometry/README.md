# 图像几何与采样 RTL

本目录提供独立的流式、外存及内部帧缓存入口。已执行全目录编译及一次组级独立 Python 数值参考回归（28 个帧/命令场景，加 3 种入口的中途复位）。没有修改原有顶层、UART 合约或构建脚本；未综合、未进行形式验证或板级验收，面积与频率尚未闭合。

推荐入口：需要直接输入/输出完整图像时使用 `img_geo_frame_buffered`；需要抗混叠缩小、非整数面积重采样或 SSAA resolve 时使用 `img_geo_area_resample`；整数倍插值放大使用 `img_geo_integer_upsample`。需要接外部 BRAM/DDR 时使用原有 `frame_writer` 与 `frame_transform`。

## 功能范围

| 功能 | 对应模块/模式 | 本轮代码行为 |
|---|---|---|
| 像素反转/负片 | `img_geo_pixel_invert` | unsigned 像素按位反转，保留 SOF/EOL；支持逐像素开关 |
| 裁剪 | `img_geo_crop_decimate` | 输入完整源帧，输出 ROI；无需帧缓存 |
| 整数降采样 | `img_geo_crop_decimate` | ROI 内按 step_x/step_y 抽点；输出宽高为向上取整的 ROI/step |
| 任意比例缩放 | `img_geo_frame_transform`, mode=1 | 坐标反向映射，最近邻或双线性插值，源图来自外部帧存储 |
| 插值上采样/扩大采样网格 | mode=1 且目标尺寸更大 | 最近邻或双线性；不宣称恢复真实高频细节 |
| 90°/180°/270° 旋转 | mode=2/3/4 | 按顺时针定义旋转，通过逆坐标随机读源帧 |
| 水平镜像/垂直翻转 | mode=5/6 | 修改逆坐标，像素值不变 |
| 任意角度旋转、平移、仿射 | mode=7 | 主机提供逆向 2×3 矩阵，可表达旋转中心、裁剪和平移 |
| 透视校正 | mode=8 | 主机提供逆向 3×3 单应矩阵，执行齐次坐标除法 |
| 帧存储读取 | `img_geo_frame_sampler` | 一次一个请求，返回数据/错误；双线性每像素四次读 |
| 帧存储写入 | `img_geo_frame_writer` | 流式源图写入外部帧存储，写应答后推进坐标 |
| 同步内部帧缓存完整变换 | `img_geo_frame_buffered` | 输入一帧，内部完成 writer→同步 RAM→transform，输出目标帧，保持命令 tag 与完成像素数 |
| 面积降采样/SSAA resolve | `img_geo_area_resample` | 对每个目标像素足迹进行精确 box 面积积分，各 packed lane 独立处理，支持非整数比例 |
| 整数倍插值上采样 | `img_geo_integer_upsample` | scale=1..15，完整内部帧缓存、双线性插值、有效命令与帧错误终态 |
| 旧模块名兼容 | `img_geo_super_resolution_stub` | 已替换原来的全拒绝占位，转接到整数双线性上采样；名称保留用于源码兼容 |

`crop_decimate` 的抽点以及 `frame_transform` 的 nearest/bilinear 缩小仍没有专门的抗混叠积分；需要面积平均时选用新增 `area_resample`。Lanczos、双三次及多相滤波不在当前接口范围，未支持的 filter 编码直接返回错误。插值上采样与 SSAA resolve 均已实现；本目录没有学习超分辨率模型或训练权重，不宣称恢复真实高频细节。

## 流控与配置

全部端口使用共同 `clk/rst_n/clk_en`。复位为低有效异步复位。所有流、配置、完成和存储请求/响应，只有 `valid && ready && clk_en` 为真才发生传输。这是原生 CE 握手，不能直接当作无 CE 的 AXI-Stream/AXI 存储端口。外部控制器若运行于不同 CE 或总线协议，必须使用桥接/弹性缓存。

输出在 `valid && !ready` 或 `clk_en=0` 时保持有效数据、地址、错误及边界信号稳定；内部状态只在启用时推进。配置在 `cfg_valid && cfg_ready && clk_en` 接受并锁存，完成通过 `rsp_valid/rsp_ready` 保持到接受。一个完整帧完成后才能接受下一份配置。

SOF 标记首个输出像素；EOL 标记每行末像素；帧存储变换额外输出 EOF 标记最后一个像素。输入裁剪和帧写入模块按配置宽高计数并检查 SOF/EOL：错误后仍按配置像素总数消耗完该帧，再报告 E_FRAME；没有丢失像素时的自动重同步或超时。因此源端必须提供完整的配置长度。

`img_geo_raster_coords` 的完成是全部坐标已经交给后级；`img_geo_frame_transform` 的完成则等待最后一个真实像素被下游接受。不要把坐标完成当作图像输出完成。

## 帧存储接口

`mem_req_addr`、`cfg_base_addr` 和 `cfg_stride` 全部以一个 packed pixel word 为单位，不是 byte。例：RGB888 的一整个 24-bit RGB 值占一个地址；每个像素的三个 8-bit lane 独立插值。`stride >= src_width`，每个像素只占一 word；不能直接输入每行字节数。

读取：`mem_req_valid/ready` 接受地址，`mem_req_read=1`；稍后 `mem_rsp_valid/ready` 返回 packed pixel 和 `mem_rsp_error`。写入模块对应 `mem_req_write=1`、`mem_req_data` 和无数据写应答。每个模块最多一个未完成请求。外部响应必须晚于请求接受的那个时钟沿，支持背压且必须最终应答；当前没有内存超时。

`img_geo_frame_buffered` 已内置单口同步帧 RAM 和请求/应答连接，并在完整捕获成功后启动变换，不需要外部软件逐像素 replay。捕获与读取分阶段进行，不需仲裁。`img_geo_area_resample` 同样使用同步帧 RAM；复位不清空 RAM，只有完整的合法输入帧才会发布。

以上内部帧入口的 `MAX_WIDTH/MAX_HEIGHT` 默认 64×64，仅限制源帧；可按可用片内/外部存储资源增大。目标宽高支持 1..65535，输出耗时随像素数增加。RGB888 默认每个入口分配 98,304 bit 源帧空间，实际 BRAM 映射尚未综合确认。各入口是可选实现，不需要同时实例化。

外存链路仍可以使用：流输入 → frame_writer → 外部同步 BRAM/DDR → frame_transform → 流输出。需由系统保证写入帧完成，并在变换期间保持源帧稳定。外部链路的存储仲裁、DDR PHY、burst 桥接、双缓冲由系统提供。本目录没有异步整帧读数组。

参数范围：`PIXEL_W` 为 1..16，`LANES >= 1`，`ADDR_W` 为 1..32。像素 lane 是 unsigned 全范围强度，不隐含 alpha 或颜色空间规则。非编译期合法参数的支持尚未实现。

`integer_upsample` 与旧名称适配器的 `DATA_W` 必须等于 `PIXEL_W*LANES`，默认 24=8×3；非 8-bit lane 要显式传入 `PIXEL_W/LANES`。cfg_width/height 为源帧尺寸，cfg_scale 为两个方向共同的整数倍。零倍数、结果尺寸超过 65535 或源帧超出 RAM 上限均返回 E_CONFIG，不消耗输入。

## 逆映射与插值

源、目标宽高均为 16-bit 非零像素数量，即 1..65535。映射输入为目的整数坐标，输出为无符号 Q16.8 源坐标。缩放采用 `src_x = dst_x * src_width / dst_width`、y 同理的 asymmetric 网格，尚未提供 half-pixel/align-corners 选项。

直接旋转 90°/270° 要求目标宽高分别为源高/宽；identity、180°、镜像、垂直翻转要求源目标大小相同。不满足时配置返回 E_CONFIG。缩放、仿射和透视可以使用不同目标尺寸。

矩阵参数 `h00..h22` 为有符号 Q16.16。仿射计算 `sx=h00*x+h01*y+h02`、`sy=h10*x+h11*y+h12`；透视再除以 `w=h20*x+h21*y+h22`。仿射 mode=7 忽略最后一行；透视 mode=8 的单位矩阵对角线为 65536。系数由主机提供，RTL 不进行矩阵求逆、相机标定或控制点拟合。仿射通过算术右移截断；透视的 signed division 向零截断，负坐标近边界存在有限精度截断差异。

支持的 filter 为 0=nearest，1=bilinear。nearest 对 Q8 小数四舍五入，恰好半像素向上，边缘限幅；bilinear 权重分辨率 1/256，每个 lane 四点加权并四舍五入，右/下邻点越过边缘时复制边缘像素。源外坐标输出 `BORDER_DATA`，不发送内存读。后续可添加边界镜像、wrap、透明 mask 等策略。

`area_resample` 不使用点采样 filter 编码，而是对源像素的分片常数模型积分。目标 x 对应源区间 `[x*src_w/dst_w,(x+1)*src_w/dst_w)`；以 dst_w 为单位计算与各源单元的精确整数交叠，y 同理。输出为 `round(sum(pixel*overlap_x*overlap_y)/(src_w*src_h))`，正数恰好一半向上。整数 2×2 SSAA resolve 因而等于四像素平均，非整数比例也不会遗漏边缘面积。该 box 滤波有限抑制混叠，不代表理想带限重建。

当前生产逆映射使用共享迭代除法器和寄存矩阵计算，双线性采样使用分段部分积流水。下述 v89m 只对指定小帧配置给出物理资源/时序证据；面积重采样和其他参数组合仍需独立验证。本目录未接入密码顶层。

## 错误约定与待完成内容

| 编码 | 含义 |
|---|---|
| 0 | OK |
| 1 | E_CONFIG：零尺寸、stride/尺寸不符等 |
| 2 | E_FRAME：SOF/EOL 不匹配配置光栅 |
| 3 | UNSUPPORTED：未知操作或滤波编码 |
| 4 | E_DIVZERO：透视齐次分母为零 |
| 5 | E_MEMORY：外部存储应答失败 |
| 6 | E_ADDRESS：地址超出 ADDR_W 范围 |
| 7 | E_COORD：采样输入越界但未提供 border 标记 |

frame_transform 在非法配置时不发出帧；逐像素映射/读存储错误用边界像素完成该位置并继续，完成响应累计第一个错误。下游应按错误标记/整帧完成状态决定是否丢弃输出。frame_writer 出错后不回滚已写内容，错误帧不可发布为完整有效源帧。

`frame_buffered` 与 `area_resample` 捕获 SOF/EOL 错误后仍消耗配置长度，随后返回 E_FRAME，不输出该源帧。所有内部帧入口都保持完成响应到 `rsp_valid && rsp_ready && clk_en`；完成表示最后一个输出已经被下游接受。没有自动补足缺失输入像素或超时机制，源端必须提供配置长度，异常截断后可用复位中止事务。

验证命令（仓库根目录）：

```powershell
python cores/system/common_scaffold/image/geometry/sim/run_geometry_group.py
```

脚本先以 `iverilog -g2012 -tnull` 编译全部 geometry RTL，然后生成一个组级仿真，使用独立整数 Python 参考比对：RGB 恒等/三种直角旋转/双向翻转、nearest/bilinear 放缩、单像素边界、仿射越界、透视与除零、面积重采样/SSAA、旧接口整数上采样、无效配置、错误帧标记。覆盖输入停顿、CE 暂停、输出背压、命令接受后配置扰动、完成响应持有，以及 3 种入口中途复位。`crop_decimate` 和 `pixel_invert` 本轮仅纳入全目录编译，未新增单独数值验收。

最近证据：`sim/build_20261015_203311/result.json`，`step_0.log`/`step_1.log` 编译成功，`step_2.log` 为 `GEOMETRY_GROUP PASS cases=28` 加 3 个 reset-abort PASS。脚本每次保留独立时间目录，不删除已有证据。

待工程优化：吞吐提升、共享迭代乘除单元、行/采样缓存、外存 burst、超时与无复位重同步、广泛参数/随机长帧覆盖，以及综合资源/时序与板级评估。本目录没有接入密码顶层；组级仿真通过不构成 ≤15K LUT/≤4 DSP 资源承诺。


## v89m 生产集成和板级验收

已回写 `rtl/img_geo_inverse_map.v` 与 `rtl/img_geo_frame_sampler.v`，其余四个 frame-chain RTL 字节未改。
逆映射的 58-bit radix-2 除法共享使用，29-bit 分段幅值、减法和符号恢复均注册；
矩阵乘积、全精度求和及范围判断分级，完整检查 Q16.8 以上所有坐标位。
缩放正常/错误响应为 240/1 CE，仿射 2 CE，透视正常/错误为 241/2 CE；直接模式保持 0 CE。
采样器的垂直乘法拆为窄部分积并精确重组，不在中间舍入；最后一次 RAM 响应后 7 CE 发布双线性输出。

独立 mapper 161 个整数黄金向量和旧越界缺陷负向对照、六配置各 433 基准+28 定向采样、
旧 RTL 对拍、9 处复位重放、新级 CE 暂停及 18176 个乘积边界对拍均通过。
实际生产路径另已通过六配置采样、正常/故障注入/复位帧、两项 POR wrapper、11 mapper 交易、
原 28 场景 geometry group；临时 staging 已清理。生产回归结果见
`sim/production_geometry_v89h_20261017/final_geometry_candidate_result_image_geometry_frame_selftest_25k_20261017_v89m_20261016T225445Z.json`。
历史 runner 目录名保留，实际候选参数明确为 v89m。

冻结源码的 seed3 路由最终 55.03 MHz，但 placement45.53MHz 使原严格全报告门禁失败；该记录保留。
同一冻结源码的独立 seed7 达到 54.88/57.06 MHz，setup、hold、全部资源及 pack 门禁通过：
7627 LUT、1774 FF、1 个实际 BRAM、0 DSP。实际 50 MHz、CE13/16，无 multicycle 例外。
位流 SHA256 为 `58141e7fa27b716f45767978de9354c8d1afaaa6dc747b2a36e64be422a9fbb4`。
三次独立 SRAM 加载均检测 IDCODE `0x1281b`、完整 34B 匹配，CRLF 后观察不少于 0.1 秒且无额外字节：

```text
GEO89 PASS D=70A68FFB P=000000B6
```

物理范围限灰度 8bit、源上限 4×3、14 命令、168 输入、182 输出、2 个预期错误；
不能扩大为 RGB 大帧时序或连续视频吞吐验收。board top 与其辅助测试逻辑未复制进生产 RTL。
完整字节备份、生产 SHA、回归和三板证据索引见
[release_summary.json](evidence/production_v89m_20261017/release_summary.json)。
外部固定版本 Vitis、ZipCPU 和 FPGA Design Elements 的许可、URL、HTTP/SHA 及设计差异见候选参考文件；
借鉴流水和定点宽度方法，保留本地数值/CE/背压/错误合同，未导入第三方源码。
