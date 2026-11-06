# B38：信用预留、符号EVM²、Sprite矩形合成与INT4 ReGLU

基线`816d461b12fd402f6a146ca74c7491c7afbd3091`。按`goal.txt`及用户指定
的图形/视频、金融、DSP、通信与低精度AI方向维持四通道开发。本批首轮43项
有限子进程全部PASS、16次成功仿真，无失败、超时、修复或重试。新增四个
能力包，累计152包、325个规范HDL文件和327个模块声明，未发现声明碰撞。
正式状态由逐包交付清单、累计快照和closeout记录限定。

| 新包 | 新增能力与实际组合 | 有限状态 |
|---|---|---|
| [pretrade_credit_ledger](../cores/storage/pretrade_credit_ledger/README.md) | 账户限额/ticket预留、IOC前准入/完成后释放和故障失效 | 11PASS/4sim |
| [symbol_evm_measure](../cores/signal_processing/symbol_evm_measure/README.md) | 精确复数误差/参考能量、峰值和量化EVM²，实际QAM16判决参考 | 10PASS/4sim |
| [rgba_sprite_blit](../cores/image_processing/rgba_sprite_blit/README.md) | 矩形命令、裁剪/翻转和已提交片元排空，实际索引纹理→alpha帧合成 | 11PASS/4sim |
| [int4_reglu](../cores/acceleration/int4_reglu/README.md) | 双驻留INT4投影、ReLU门控乘积和signed8量化，实际signed32输入桥 | 11PASS/4sim |

信用账本使用未改的同步RAM存放账户128位记录及票据136位记录，支持最多
16账户/64票据，ticket和额度均64位。原子reserve用65位加法检出进位；重复
ticket、金额0、未配置账户、超限及满表等拒绝不变更普通状态。release使用
已存账户/金额，限额重配不能小于used；INVALIDATE保留失效负载并要求CLEAR
开启新epoch。默认6400、最大10752逻辑RAM位，风险MEDIUM。真实例子只处理
buy-limit IOC，先保留limit×quantity精确64位的在途预算；正常完成在所有fill
已退休后释放整额，再公开done。后端异常则保守失效，不宣称回滚已成交结果
或完整清算余额。其用途是准入期间的并发暴露上限。三个core profile核对944
条命令及完整RAM账户/票据set，含5664保持时钟、926次真实future offer、15次
运行中复位。实际例子核对15管理、12簿维护、16订单、6次已退休fill、14次done，
另有reset取消的在途订单；pending管理命令实际阻塞21拍。故障注入仅在TB，
发生于一次真实fill后，核对失效的33额度hold及已有成交效应继续保留。

EVM核用单个未改vector_l2sq按四个标量计算每个复数符号的error和reference
平方和，累积宽度随最大符号数推导。输出精确两能量、最早同值峰及其位置，
再复用迭代除法得到`RNE((error<<16)/reference)`、uint32饱和标志。reference0
显式ZERO_REFERENCE，不对0/0给正常比率。D8..16、最大4096符号，最大配置仅
短N≤37定点检查，不播放4096全长。实际例子复用原QAM16最近点索引，适配
CE/异步低子复位与普通握手；诊断不丢样。判决参考会低估误判符号，未提供
自动相位/增益/定时对齐、EVM百分比或校准仪器结论。首轮122结果、655样本、
91次尾部时延与334次II检查；II8/实际桥II9、最大尾部等待71拍是有限仿真观察。

Sprite去重确认B35已完整提供straight-alpha精确/255混色、重叠RMW与帧读回，
B37已提供索引纹理采样，因此本批只新增矩形命令服务及实际连接管理。源矩形
先完整检查，再用signed18求destination与viewport交集；完全离屏常数时间
结束，不遍历巨大无效区域。flip仍相对原始矩形计算。三请求配额支持在途
采样；透明响应退休但不送store，DONE/END/纹理管理等待最后store写提交。
实际连接使用不变的sampler与RGB/Z store，固定ALWAYS/no-Z-write。三个core
profile合计430查询/324可见片元，实际两帧384 RGB/Z读回；共140接受命令，
136次DONE核对和11次复位；其中133次DONE实际退休，3次held DONE被复位取消，
另4条命令在核对DONE前复位。默认174080、最大1187840逻辑RAM位含未使用的Z存储，
最大容量风险HIGH，未实测器件适配或帧率。

ReGLU复用一个未改INT4 matvec，以row2j/2j+1交错存gate/value，查询仅缓存
一次。先将两个分支分别量化signed8，再`max(0,gate)*value`，经驻留逐元素
scale/shift/zero输出signed8。只加单个gate槽与共享16/33位寄存乘法，不复制
查询或hidden帧RAM。误差、clip和gate闭合均按pair报告；输出metadata先预检，
再由原matvec预检分支配置，形状/配置/LAST错误不泄漏普通输出prefix。实际
32→8弹性输入桥用sign-bit toggle加128，独立累计输入量化flags，明确一槽
pending复位。有限核对303普通向量+77错误marker+8真实future-offer结果，
1979输入样本、5329配置、194命令、1767保持时钟和33次复位。默认4840/
最大68512位矩阵、查询及输出metadata payload，另有原子核branch metadata；
风险MEDIUM，不是完整MLP或模型精度声明。

外部前置均固定版本、只读核对具体实现/许可证，未复制、翻译、导入或执行：
Apache2 exchange-core风险准入/释放边界、GPL3 GNU Radio EVM公式、MIT ProjectF
sprite扫描，以及BSD3 PyTorch激活语义/固定arXiv GLU abstract。原路径
vector_l2sq此前未跟踪且无canonical alias，本批仅首次提交实际调用源和限定
`-text`属性；QAM16原子核此前已跟踪，本批首次纳入累计canonical闭包并核对
不可变BASE原字节。其余共享源码全部保留，不继承未核对的旧资格。

本批不运行综合、PnR、STA、上板、PPA、合并编译或旧包回归；均保留
HW_UNVERIFIED。交叉审查、执行输入、计划、独立向量、原始stdout/stderr和
有限收据随包归档。持续目标保持active。
