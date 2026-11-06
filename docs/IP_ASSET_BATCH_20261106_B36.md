# B36：订单状态、谱相干度、三场去隔行与量化注意力

基线 `8ba6835fe51ad285b926cd24e3ba4d172aefce26`。继续按 `goal.txt` 和用户指定的
五类应用方向开发。四通道各自实现一个独立功能，优先复用原有成熟构件，
不改写其源码。四包首次有限执行共44个子进程PASS、17次成功仿真，
无失败、超时或重试。累计快照为144包、306份canonical HDL源文件、308个
模块声明；源清单闭包与名称冲突静态审计PASS，未运行合并编译或旧包回归。

| 新包 | 实际功能增量 | 本批有限证据 |
|---|---|---|
| [itch_order_state](../cores/storage/itch_order_state/README.md) | 单标的64位订单ID持久状态与原子复合L2增量 | 首轮11个子进程PASS，4次仿真 |
| [paired_spectral_coherence](../cores/signal_processing/paired_spectral_coherence/README.md) | 双复数谱跨段精确互谱/功率累积与Q16幅值平方相干度 | 首轮10个子进程PASS，4次仿真 |
| [three_field_deinterlace](../cores/image_processing/three_field_deinterlace/README.md) | 前后同奇偶场运动判别、5方向空间插值及当前场保真输出 | 首轮12个子进程PASS，5次仿真 |
| [int4_key_attention](../cores/acceleration/int4_key_attention/README.md) | 驻留INT4 key、U8 query、近似softmax与signed8 value归约 | 首轮11个子进程PASS，4次仿真 |

订单状态核复用两份原路径 `ram_hash_table`，用64位键保留完整order ID，
每份64位value保存price32/remaining32，由实例区分买卖侧。总容量限制与
全局ID唯一预检避免侧向容量缺口。Replace先检查旧ID和新ID，再删旧插新，
支持满表替换；可预期错误在写前拒绝。逻辑/容量错误锁定faulted，管理命令
可恢复。单条held响应同时给旧/新记录与复合增量，消费者按一次事务处理。
实际例子串联B35接收器。网络gap、交易会话恢复和重新播种由外部控制器负责；
接收器的包序列提交不等于订单状态更新或下游增量成功。它没有宣称提供L2
价位汇总：同价多订单需要更宽聚合量，既有32位价位服务不足以自动闭合。

谱相干度输入为频点/窗口对齐的两路复数谱，精确累积Sxx、Syy及Σconj(X)Y，
用全宽平方/乘积及RNE除法求Q16 MSC。先扩展到17位再共轭，完整覆盖signed16
最小值。公共归一化尺度在比值中消掉；零能量显式无效，K=1非零时必为1，
不以此声称统计诊断有效。复用cplx_mac、串行乘法和fp_div_iter，默认约1.14KiB
累积RAM，最大约4.81KiB；未保存所有输入FFT帧，也未新增重复FFT。实际例子
用每路一个holding slot容纳偏斜谱流，负责配对握手；它不执行FFT或时间校准。
helper的同步/异步复位及CE差异在新包装中显式处理，算术异常终止剩余batch。

三场去隔行按P,C,N完整捕获后回放，保留C场行；缺失行用P/N三点运动阈值
选择时间平均，或在0,-1,+1,-2,+2五个方向上按三项绝对差最小成本插值。
边界逐样本clamp，tie顺序固定，平均half-up；输出决策类型和方向可核验。
它是原创、明确定义的有限triplet服务，不宣称YADIF兼容、运动补偿或无缝
场率吞吐。原有双场deinterlace和完整HE/CLAHE实现已在去重阶段检查，保持
原样。所有公开传输均为CE-qualified，实际RGB诊断例子沿用相同契约。
有限检查比较28224个输出，覆盖15次marker中断、20次复位和14657个输出
保持时钟；包含三帧128×64图像，最大几何未仿真。最大逻辑RAM1179648位，
存储风险HIGH；该数字为源码结构推导，不是综合测量。

注意力核复用驻留矩阵向量核、16lane三遍softmax及21位整数除法器。
运行时1..16个token、1..1024个query维度、1..32个value维度；INT4 key与
signed8 value跨query保留。近似权重的和可以不同于255，因此最终按实际权重
和做signed RNE，保持常量value及凸组合数值范围。score量化/指数LUT/倒数表
均明确定义，不声称与浮点框架或具体模型精度等价。私有CE重放适配器完整
消费48个softmax feed后才归约value，不把其保留p_vld直接当公开valid使用。
实际boot例子自动配置两个token并核对三次query的六个输出通道。

注意力有限夹具核对2876配置、102个query终止、444普通输出和54错误marker，
另有3个真实持续offer优先级流程。15个reset场景、1473个输出停顿时钟与实际
例子均通过。最大1024列仅语法检查，数值profile为1/9/64列，未扩张覆盖声明。
源码周期预算和实际硬件频率分开记录；本批不做综合、PnR、STA、板测或PPA。

订单状态核有限检查完成899条命令（332管理、567事件）、5394个响应保持
时钟、884次真实后续offer、12次运行中复位；组合例子处理6个包、8条结果。
架构风险MEDIUM，未注入私有写后INTERNAL故障，不宣称具备回滚能力。
谱相干度完成537条响应、791对边界内输入、157条命令、24次复位及8个
注入故障。四包的参数上限、串行服务周期和资源风险均分别列于包内。

源码交叉审查闭环为A审root、root审B、B审C、C审A，均无阻断项。
这是有限源码/仿真证据；四包均保持HW_UNVERIFIED。

外部前置只读审查包括Nasdaq规范/固定MIT解析器、固定BSD SciPy CSD/coherence、
固定LGPL FFmpeg技术对照和固定BSD PyTorch注意力说明。未复制、翻译或执行
外部实现。各包SOURCES记录固定版本、实际文件及许可证；本地实现为原创
Apache-2.0，并保留所有离线源码、数据、测试向量和调用清单。

离线导出补充4份依赖路径：cplx_mac、img_hist_serial_multiply、
ips_softmax_fixed及原始integer_divider。前三份已在基线提交且未修改；最后
一项原路径尚未跟踪，其字节与基线已提交的扩散包内副本完全相同，本批仅
补入该源文件。保留旧包/旧files.f和原140包快照对象，新增exact-byte alias，只在
组合canonical清单中使用原始路径一次，不把路径迁移计为新能力。其余已在
canonical清单内的依赖继续复用。

最终仅提交四个新包、具名B36文档、累计源码快照及上述divider原路径文件。
212份新包交付文件均有SHA256清单。工作区其他修改保持原样。
成功临时VVP与只读参考副本在提交和路径/hash核验后逐个清理；保留全部执行
源归档、原始日志和失败证据。持续目标保持active，本批完成不等于开放目标终止。
