# 去雾与灰度导向滤波

主入口为 `img_dh_dehaze_frame` 和 `img_dh_guided_frame`。两者均有完整帧内数据通路、同步帧 RAM、配置快照、命令响应、tag、共享时钟使能和背压。无需外部窗口或软件先行计算中间图像。完整 RGB DCP 顶层已更新为 v96d 共享迭代算术，在最大3×3、半径0..1的限定配置下通过实际50MHz时序及三次独立SRAM板测。共享的 `img_dh_guided_refine` 另有 v73 四帧400像素证据；默认大尺寸与连续视频吞吐仍待验证。本目录不接入既有格密码 board top。

## 完整 DCP 去雾：img_dh_dehaze_frame

默认最大尺寸 32×32、最大半径 3；运行尺寸由命令指定，最大可参数化至 512×512、半径 7，实际可用尺寸受器件 BRAM 限制。依次执行：

1. 内部 RGB888 帧 RAM 采集，检查 SOF/EOL。
2. 使用 clamp 边界的 `(2r+1)²` RGB 空间暗通道；同步直方图累积。
3. 自动大气光模式：从暗通道直方图求最高 `ceil(N*permille/1000)` 个像素的门限，在所有暗通道值不低于门限的像素中选择 RGB 和最大的像素。同亮度使用后一个像素。门限处同值候选全部纳入，因此候选数可能超过 K。`permille=1` 表示 0.1%。自动 A 来自当前帧；关闭自动模式时使用命令的 RGB A。
4. 每通道使用各自 A 归一化后进行空间最小值，计算 `t=max(0,1-omega*min_window(min_c(Ic/Ac)))`。这一路不是旧模块的标量 dark/A 近似。
5. 可选的真实 gray-guided 透射率细化，包括第一遍 I/p/I²/Ip box 统计、协方差/方差系数 a/b、第二遍 a/b box 统计及 q 重建。guide 为 `(77R+150G+29B+128)>>8`。
6. `Jc=sat8((Ic-Ac)*32768/max(t,t0)+Ac)`，RGB888 有序输出。

`omega/t0/t` 为无符号 Q1.15，1.0=32768；omega=0..32768，t0=1..32768。A 任一分量为零时按 1 处理，避免黑帧或手动零值除零。每通道归一化比值 `(Ic*32768+Ac/2)/Ac` 舍入，omega 乘积加 16384 后右移 15。RGB 恢复有符号除法向零截断并饱和至 0..255。没有天空语义、运动补偿或神经网络去雾；这些不是 DCP 算法的必需步骤。

v96d 将归一化与RGB恢复的六类除法共享一个八位分块有符号divider，每次接受后
656个CE沿完成；透射率乘法使用144个CE沿的共享乘法器。增加内部处理延迟，
数值、舍入、响应与像素顺序保持。直方图计数位宽由DEPTH界定，累加比较显式
保留进位；未用CE放宽时序。生产top只将冻结候选的模块声明改名，其他字节一致。

限定板测候选 `board/tang25k/build/image_dehaze_frame_selftest_25k_20261017_v96d_dcp_full`
覆盖10命令、41真实RGB输入/输出、4预期错误，包括auto/manual A、零A通道、
omega=0/32768、t0=1饱和、错误SOF及非法命令；两个命令实际启用guided，非恒定
3×3的透射率经细化发生变化。真实50MHz、CE1/4，修正LUT/BRAM库60.32/63.42MHz，
setup/hold全过。自检top13571LUT/4222FF/17实际BRAM/0DSP，含ROM/checker/UART。
三次独立SRAM各确认0x1281b并严格匹配51字节：

```text
DCP PASS F=0A I=0029 O=0029 E=0000 D=5512B18B C=F
```

位流SHA `063fb76b8719648e1e0042dd53146849548d241aa7b6ab17a7389a7aaa34783c`；
逐次记录与范围见候选 `board_validation_summary.json`。该范围不包含默认32×32、
任意参数组合或连续视频。生产集成证据为 `evidence/production_v96d_20261017`，
包含旧源/文档/manifest备份、module-name-only变换与五项生产源测试。

命令端口：`cmd_valid/ready`、`cmd_width/height[15:0]`、`cmd_dark_radius[3:0]`、`cmd_auto_airlight`、`cmd_airlight_rgb[23:0]`、`cmd_airlight_permille[9:0]`、`cmd_omega/t0[15:0]`、`cmd_guided_enable`、`cmd_guided_radius[3:0]`、`cmd_guided_epsilon[31:0]`、`cmd_tag[TAG_WIDTH-1:0]`。自动模式要求 permille=1..1000；guided 模式要求 epsilon=1..65535（8-bit guide 的平方单位）。关闭的可选功能不检查其未使用参数。

输入 `s_data[23:0],s_valid,s_ready,s_sof,s_eol`；输出 `m_data[23:0],m_valid,m_ready,m_sof,m_eol,m_eof,m_tag`；响应 `rsp_valid/ready,rsp_error[3:0],rsp_tag,rsp_airlight_rgb[23:0]` 和 `busy`。RGB 约定 R 位于 23:16，G 位于 15:8，B 位于 7:0。

## 可复用完整灰度导向滤波：img_dh_guided_frame

默认最大 64×64、最大半径 3。内部 `img_dh_guided_refine` 为共享实现，输入帧与 a/b 系数 RAM 均为同步读取。source/guide 是同一个原子像素事务中的两个数据域，不能各自独立前进。

- 命令：`cmd_valid/ready,width/height[15:0],radius[3:0],epsilon[31:0],tag`（名称均带 `cmd_` 前缀）。epsilon=1..65535，使用 8-bit guide 的平方单位。
- 输入：`s_guide[7:0]`、`s_p[15:0]`（Q1.15，0..32768）、`s_valid/ready,s_sof,s_eol`。
- 输出：`m_q[15:0]`（Q1.15）、`m_valid/ready,m_sof,m_eol,m_eof,m_tag`。
- 完成：`rsp_valid/ready,rsp_error[3:0],rsp_tag,busy`。

8-bit source 可左移 7 位接入；输出右移 7 位转回 8-bit。该映射输入最大为 32640，输出若达到 32768，8-bit 适配层应饱和而不是截断成零。

令 n 为 box 面积，I 为 guide，p 为 source。第一遍算 `a=trunc(((nΣIp-ΣIΣp)<<16)/(nΣI²-(ΣI)²+n²epsilon))`、`b=trunc(((Σp<<16)-aΣI)/n)`；第二遍算 `q=clamp(trunc((IΣa+Σb)/(n<<16)),0,32768)`。所有 box 均复制边缘。a/b 保留相对 p 的额外 16 个小数位，乘加使用 64-bit 临时值，除法向零截断。这是定点 gray-guided filter，不使用均值滤波替代。epsilon 的整数最小值为 1，不支持小于一个灰阶平方的正 epsilon。

v73 保持数值、截断及像素协议，增加内部处理周期：三次有符号除法共用八位分块
restoring divider，每次 accept 后656个CE沿完成；A的六项及B/Q乘法共用low64
shift/add乘法器，每次 accept 后144个CE沿完成。邻域小乘积单独寄存，宽加减使用
四位分组进位。所有帧/系数RAM仍同步读取。默认尺寸不等于实测吞吐；这是逐窗口
遍历的多遍帧处理实现。生产文件直接展开三份冻结helper的内容，继续支持原单文件
编译；与候选相比仅展开include，模块内容逐字节核对。

限定上板证据为 `board/tang25k/build/dehaze_guided_refine_selftest_25k_20261017_v73_allmul`：
1×1/r0、5×3/r1、16×12/r2和16×12/r3，共400像素；独立整数参考、复制边界、CE4及
输出/响应背压。修正LUT/BRAM时序库最低52.51MHz，hold通过；自检top总量5373 LUT、
2747 DFF、12 BSRAM、0 DSP，包含checker/ROM/UART。三次独立SRAM加载均严格匹配
160字节，摘要为00002EE0/C6C801CF/1BCCF88B/00000000，逐次核对JTAG 0x1281b。
这项覆盖只属于guided-refine阶段，不表示整个RGB DCP去雾链、默认64×64或连续视频通过。

## 事务、错误及流控制

`clk_en && valid && ready` 才发生任何命令、像素或响应传输；CE=0 保持状态和已挂起输出。一个命令处理一个完整帧，参数和 tag 在命令接受时快照，响应被接收前不接收下一命令。第一个像素必须 SOF，每行末像素必须 EOL，不使用外部帧结束脉冲。m_eof 与末输出同行。暂停/背压不改变图像、tag、帧标记。若源未交付全部 width×height 像素，模块等待后续像素；取消事务需复位。

`rsp_error=0` 成功，1 表示非法命令并且不采集像素，2 表示采集的 SOF/EOL 不匹配（guided 还包括 p>32768），3 表示内部状态/子滤波器错误。格式错误依然消费规定像素数并可输出诊断结果，调用者必须以最终 response 判断该帧是否可用；错误不伪装为成功，也不会永久锁住下一命令。输出与响应在背压期间保持稳定。

## 保留小核与兼容入口

`img_dh_rgb_min`、`img_dh_window_min`、`img_dh_airlight_candidate`、`img_dh_transmission`、`img_dh_restore` 保留原有外供窗口/侧带的低层算术接口。旧 `img_dh_dehaze` 是兼容性的 scalar-dark 外供窗口流水线，不能作为完整 raw-frame 去雾入口；其默认 EXTERNAL_WINDOW=0 仍按旧约定显式拒绝。新开发请选上面的 `img_dh_dehaze_frame`，已有旧接口不会被静默重解释。`img_dh_guided_refine` 已有完整算法，非占位核。

## 最小整组开发检查证据

从仓库根目录运行：

```powershell
. ./scripts/env.ps1
$dhfiles = Get-ChildItem cores/system/common_scaffold/image/dehaze/*.v | ForEach-Object { $_.FullName }
iverilog -g2012 -Wall -t null $dhfiles
python cores/system/common_scaffold/image/dehaze/check_group_reference.py
python -B cores/system/common_scaffold/image/dehaze/sim/run_production_arithmetic.py
```

已完成一次全目录编译及一组独立 Python 任意精度整数参考模型对照，结果 `PASS dehaze_group guided_cases=6 dehaze_cases=7 cycles=8323`。覆盖非恒定 guide/source、常量 guide、radius=0、1×1 clamp、黑帧/零 A、自动 top-permille A、manual A、guided 开关、omega=0、非法命令、格式错误、tag、CE 和输出背压。证据与生成测试平台保存在 `reference_build/{compile.log,simulation.log,summary.json,reference_vectors.json,tb_dehaze_group.v}`。这组检查用于确认新入口完整数据依赖及接口闭环，不表示所有参数组合、旧小核、板级、时序或资源均已验收。没有修改原有 UART digest/合约或格密码存储结构。

v73生产回写后相同6 guided/7 DCP案例PASS，新增处理周期使总周期为224201，原
golden未改；证据为 `reference_build_20261017_025013_497716`。旧RTL、旧divider
测试与文档保存在 `evidence/production_v73_20261017/before`，回写来源和include
展开哈希见同目录provenance。独立生产算术bench覆盖148232加减、321乘法、272除法
和786 solve；临时仿真镜像自动清理。外部资料的URL、内容SHA及采用差异见候选
`EXTERNAL_DESIGN_REFERENCES.md`及公共 `evidence/20261017_external_reference_index.md`。

v96d生产回写后，POR、完整51UART、checker故障、中途divider复位、旧v96c逐拍
接口/状态/直方图lockstep全部PASS。原6 guided/7 DCP独立整数黄金组也PASS，
1209108物理cycles，原timeout和黄金均未修改；证据
`reference_build_20261017_045340_031836`。本轮新组仿真镜像及临时测试镜像已清理。
复跑命令：

```powershell
python -B cores/system/common_scaffold/image/dehaze/evidence/production_v96d_20261017/run_integration.py
```
