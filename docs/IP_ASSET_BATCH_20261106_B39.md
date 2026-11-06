# B39：分片重组、行情恢复、突发频偏校正与局部绿色均衡

基线 `1e9e9130cef71127d2c8d2762affe815b067b9f5`。按用户确认的
`goal.txt` 维持 root 加三个 Worker 的四开发通道。本批补充两个通信/行情
状态服务、一个实时信号校正服务和一个 ISP 空间校正服务；AI 方向已有
B38 驻留 INT4 ReGLU。本批不重复这些基础算子。

| 新包 | 新增实际能力与组合 | 有限资格 |
| --- | --- | --- |
| [ipv4_fragment_reassembly](../cores/communication/ipv4_fragment_reassembly/README.md) | 乱序分片负载、未知末端长度和覆盖所有权；真实报头校验核→重组→同步 RAM | 12 PASS、1 保留 FAIL、4 sim |
| [moldudp64_recovery_manager](../cores/communication/moldudp64_recovery_manager/README.md) | 会话缺口目标、已发请求、进展与显式重试；真实 ITCH 接收器→管理器→20 字节重传请求 | 11 PASS、4 sim |
| [burst_cfo_correct](../cores/signal_processing/burst_cfo_correct/README.md) | 重复前缀获取频偏并从 sample0 回放整突发；真实同步/atan2→sincos→分时精确复乘 | 10 PASS、4 sim |
| [raw_green_equalize](../cores/image_processing/raw_green_equalize/README.md) | 空间局部、边缘门控 Gr/Gb 均衡；真实 RAW10 均衡→旧 Bayer demosaic | 12 PASS、1 保留 FAIL、4 sim |

IPv4 服务以 src/dst/id/protocol 为单上下文 key，13 位 offset 按 8 字节
解释；17 位起止运算先全宽检查，再访问 RAM。非末片长度须为 8 的倍数。
终片可先到并建立总长；重叠片（含相同重复）和终点冲突在收 payload 前
整片拒绝且保留旧上下文。LAST 错误则失效整个上下文，不泄漏普通输出。
完整覆盖后先退休 status，再按序回放；末字节退休前不能接新命令。
每 8 字节一个 ownership 位的成立条件和独立字节模型均随包说明。默认
512/最大4096字节，RAM 4096/32768逻辑位、bitmap64/512位，风险MEDIUM。
实际例接收 packed 固定20字节报头，调用未改校验核，五组二 word 逐组折叠，
避开原子核的18位累加诊断。不是 raw Ethernet parser、全协议栈或自动
超时服务；owner 要用 FLUSH/reset 过期。四个成功仿真核对361命令、855输入
字节、735回放字节、27次复位、3256保持拍、4次真实 future FLUSH。

行情恢复管理器区分已接收的 next、见过但被严格接收器丢弃的 exclusive
target 和 outstanding 请求的 until。full64 非模序号，hint 普通消息数用
65位相加检查溢出；heartbeat/end 的特殊 count 不作为普通数量相加。
ISSUE 截断到 REQUEST_MAX，重复 hint 不重复发已在途请求；任何实际 progress
清 outstanding，再请求剩余后缀，适应服务端单 UDP 只返回请求的一部分。
RETRY 是外部显式动作，没有假定 RTT 定时。真实例等待最后 ITCH event 退休，
再更新管理器、生成完整20字节 big-endian 请求；最后请求字节和 public
completion 都持有事务所有权。默认16/最大32上下文，280位同步 RAM 记录，
4480/8960 payload bits，另有有效位；例含原2048字节接收存储，共16664逻辑
payload bits。不是 payload 重排缓存、socket、UDP/IP TX 或可靠投递保证。
核心3836个核对响应含1918次实际 future GET；例核对24 completion、6完整
请求及19字节被复位取消事务的已退休前缀、1个实际 ITCH event。

频偏校正核缓存 signed12 IQ，前32样本是两个未知的 L16 半段。先精确求
P 与能量并作归一化阈值判断，再用 atan2 signed24 生成
`FCW32=-(signextend(phase24)<<4)`，从 index0 相位0回放全突发。
principal 分支为 [-Fs/32,Fs/32)，估计码距半周边界4码内拒绝；不检测
分支外物理 alias，不提供绝对相位或帧定位。Q2.16 sincos、共享四次串行
乘法、完整积和、RNE 与 signed12 饱和；完整数学预算相对精确整数 P 的
理想旋转给出每分量2LSB保守界，不宣称真实噪声载波测量精度。
MAX32..4096，默认256；burst RAM6144/98304位，原前缀 rings1952位另计。
风险默认MEDIUM/最大HIGH。首轮包括4096完整回放，8590记录、11047输入样本、
248命令、48复位、4故障恢复、646 lane clips；8502次 phase/coeff/exact-IQ
核对（每项），10812次输入II及8386次输出II检查。有限观察II9/1/103，
最大仿真5.187秒；这些不是器件时钟或线速数据。

绿色均衡只在非边界 green 位置读取原始四对角、另一绿色相位的 donor。
diag range 和 center/diag 均值差通过阈值门后，输出
`(4*center+sum(diag)+4)>>3`；R/B、边界和 thin 图原样。平坦 Gr=a/Gb=b
得到 `(a+b+1)>>1`。现有 AWB 已能分别提供 Gr/Gb 全局增益，本批新增的是
空间局部、纹理/边缘门控。真实例明确转换 CFA ABI，并仅在旧 demosaic
支持的8/10位域内组合；独立核另支持 RAW12。旧窗口明确用寄存器行缓存，
不能写成 BRAM：默认 RAW12/W64 行 payload3144位，W512为24648位；实际组合
第二组窗口另计。最大资源风险HIGH。四个成功仿真共32768逐像素输出核对、
136命令、128 checked DONE、16复位；RAW12和真实RAW10 RGB链均已执行。

本批47个有限子进程留下45 PASS、2 FAIL，16次成功仿真。IPv4 首轮例的
零负载向量错误地预期 decoded RANGE2，实际报头 total20 按原契约应返回
BAD_HEADER8；只改一行预期和独立有效性判定，复审后2 child定向通过。
ISP 首轮多行测试台在永久阻塞输出时仍等待整帧输入，形成供给死锁并触发
有限 TB watchdog；只改 held-first-output 取消场景，驱动至首输出后复位，
复审后6 child通过。两处生产 RTL 均未改，精度、输入、时限均未放宽，旧
成功配置未重跑；原失败镜像、源、plan、向量和原始 stdout/stderr 永久保留。

新增包都记录接口、依赖、数值/存储预算、去重、固定官方只读参考及许可证。
参考包括 RFC791/lwIP BSD-style、Nasdaq MoldUDP64/Apache2 Nassau、GPL GNU Radio
公式和 GPL RawTherapee 应用边界；没有复制、翻译、导入或执行其源。
只首次提交原有未跟踪 sincos 源及限定 `-text`，不导入其 legacy 包或旧资格。
另外四个已跟踪原路径源首次纳入 canonical 闭包，并核对不可变 BASE 原字节。

累计156包、338个规范 HDL 文件、340个 module 声明，无声明碰撞。累计快照
保留152个父包对象；新交付的当前/归档源、plan、向量、raw 和工具哈希均作
静态回读。只提交命名的本批路径；无远端 push、新 tag 或共享源改写。
所有新版本保持 HW_UNVERIFIED，不运行综合、PnR、STA、上板、PPA、合并编译
或旧回归。持续目标保持 active。
