# B37：宽数量L2、重复前导同步、索引纹理与整数LayerNorm

基线`46630205095a13ab95e1b5bebea0094c2a390390`。按`goal.txt`和用户五类
重点方向推进，四通道各交付一个独立能力。45个有限子进程中44PASS、1个历史
夹具FAIL，16次成功仿真；原FAIL与显式两项修复分别保留，不改写首轮状态。
累计148包、315个规范HDL文件、317个模块声明，静态源码闭包未发现命名碰撞。

| 新包 | 实际能力 | 有限状态 |
|---|---|---|
| [itch_l2_delta_book](../cores/storage/itch_l2_delta_book/README.md) | ITCH原子双腿增量、38位聚合量、post-BBO及失效传播 | 首轮11PASS/4sim |
| [repeated_half_sync](../cores/signal_processing/repeated_half_sync/README.md) | 时域未知重复前导的双半能量归一化、持续命中与P相位 | 首轮9PASS/1夹具FAIL，显式修复2PASS；共4成功sim |
| [indexed_texture_sampler](../cores/image_processing/indexed_texture_sampler/README.md) | 驻留索引纹理/调色板，实际仿射纹理→RGB/Z渲染 | 首轮11PASS/4sim |
| [signed8_layer_norm](../cores/acceleration/signed8_layer_norm/README.md) | 精确中心统计、驻留逐元素仿射和signed8推理流 | 首轮11PASS/4sim |

L2核复用未改的72位同步RAM，维护最多64个总价位。32位价格和每腿数量
保真，38位聚合量覆盖64个最大32位订单量；全表扫描寻找键/空槽和未触及
最佳价。remove/add写前验证，同键先减后加，完整移除旧价位后可在满表
复用槽。单条held响应同时提交净数量与post-BBO。不是撮合器，也不保留
单笔order ID；实际例子连接B36订单状态。若L2在上游订单提交后拒绝增量，
例子先显式INVALIDATE上游再对外答复，不声称回滚。有限例子自然制造FULL
并核对旧报价仍在、替换后的订单也已提交。864条core命令、5184保持时钟、
849次真实future offer、12次运行中复位，实际例子16结果。

重复同步核对相邻两个L点复数段计算P=Σconj(previous)*current与两段总能量E。
用精确整数不等式`|P|²<<18 >= threshold_q16*E²`判断`4|P|²/E²`阈值，并确认H次
连续命中后只报一次事件。三环同步RAM按当前batch有效范围遮蔽未初始化项，
复用复数MAC和宽串行乘法，无宽除法展开。实际12位/L16例子把signed29 P
接入已有atan2并保持元数据。位置属于accepted-sample时间；CW亦可能命中，
它提供粗重复窗口，不承诺精确符号边界或误报率。频偏解释固有模1/L歧义，
不是完整OFDM接收机。首次并发夹具漏计历史填充时间，原FAIL证据完整保留；
显式修复仅作用于该夹具首次等待预算，不重跑已成功core配置。首次并发等待
按279拍预热、207拍既有尾部及8拍余量设为494，实测487；后续仍为400。
修复只编译/仿真实际相位例子，原向量逐字复制且不重新生成。修复例子比较
153条相位/元数据结果，含132次尾部时延检查、961次warmup II检查、868保持
时钟、47条batch命令及7次复位。数值、精度与尾部时延断言均未放宽。

纹理核具有单独的index RAM与RGBA palette RAM，完整加载并PUBLISH后跨请求
驻留。三级全局反压流水依次读index、palette并输出；每个请求均退休结果，
UV越界透明、alpha0不可见。管理请求先阻止新lookup，再等流水真正排空。
实际例子复用B33三角形raster的RGB属性作为half-up仿射UV，接采样器及B35
RGB/Z store；透明与越界结果不传给store，因此不会写Z。primitive的深度、
写mask保留至所有采样退休，DONE/END覆盖sampler及store排空。有限检查比较
696条采样与384条RGB/Z输出，含2帧/19三角形命令；最大纹理只完整加载一次
65536索引和256色，再做72稀疏采样。默认逻辑RAM40960位，最大532480位，
最大存储风险HIGH；这些是结构预算，不是实测资源或硬件帧率。

LayerNorm保留精确S=sum(x)、Q=sum(x²)，形成T=NQ-S²+N²epsilon，再对N*x-S
做分级RNE开方/除法。没有先取整均值/方差；逐元素gamma/beta/shift驻留，
beta在重量化舍入后加，最终饱和signed8。T0显式定义normalized=0并置退化标志。
实际signed32→8弹性量化例子保留LAST、输入clip/inexact与单样本在途生命周期。
有限4profiles覆盖1/F0、9/F12、最大256/F16与实际8/F12例子：3152普通比较、
61错误marker、另8个优先级输出；673向量配置回应、29运行中复位、11250输出
保持时钟，含明确的量化样本在途复位。保持staged integer契约，不声称与浮点
框架位精确或模型质量等价。其默认2880/max11520位RAM，风险MEDIUM。

四包均是原创Apache-2.0组合控制/数据通路，前置固定外部参考仅只读技术与
许可证核对：MIT订单簿、GPL GNU Radio公式/语义、MIT Project F、BSD PyTorch。
未复制、翻译、导入或执行外部实现。新调用的原路径stream_atan2此前仅在工作区
存在，本批只补入该源及限定`-text`属性；它首次纳入Git/累计导出，资格来自
本批有限相位连接证据，不继承未经核对的旧状态。其余成熟依赖原字节保留。

交叉审查为A审root、root审B、B审C、C审A，未发现剩余源码阻断。所有有效
执行输入、独立向量、原始stdout/stderr和失败记录保留。未运行综合、PnR、STA、
上板、PPA、合并编译或旧包回归；均保持HW_UNVERIFIED。持续目标active。
