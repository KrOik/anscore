# B35：行情接收、价位撮合、带宽测量与图形片元

本批基线 `bbb761eb39c475ed52c7c42414a724e3f1ba6cae`，沿用四条开发通道，
以 `goal.txt` 和五类应用方向为依据。新增4项能力，累计140个包；旧136个包的
快照对象逐项保留。下面结果仅对应封存的有限检查，全部为 HW_UNVERIFIED。

| 新包与调用入口 | 功能增量 | 有限证据 |
|---|---|---|
| [moldudp64_itch_rx](../cores/communication/moldudp64_itch_rx/README.md) | 完整MoldUDP64数据报校验、会话/严格64位序列准入、7类ITCH5订单事件 | 9个子进程PASS，3次仿真，306包/139事件 |
| [occupied_spectral_bandwidth](../cores/signal_processing/occupied_spectral_bandwidth/README.md) | 运行时等尾功率分位边界、精确总量/保留量/两尾统计 | 10个子进程PASS，4次仿真，84响应/15724输入/60次精确延迟检查 |
| [fragment_rgb_depth_store](../cores/image_processing/fragment_rgb_depth_store/README.md) | 坐标片元的RGB/Z读改写、深度测试、透明混合与完整光栅导出 | 10个子进程PASS，4次仿真，54116个RGB/Z输出 |
| [price_level_ioc_matcher](../cores/acceleration/price_level_ioc_matcher/README.md) | 汇总L2价位的买卖IOC逐级撮合、扣量、成交与取消余量 | 11个子进程PASS，4次仿真，715维护/130 IOC/128成交，另有实际例子1成交 |

合计40个实际执行的有限子进程PASS、15次成功仿真。本批无失败、超时或重试。
每个检查使用20秒子进程期限，先保存精确执行源，再生成并保存向量，首个失败
即停止后续检查。原始stdout/stderr、向量和源副本均保留并记录SHA256。
没有综合、布局布线、STA、上板、PPA测量、组合全库编译或继承资产回归。
本批结果不会改变B34色调映射128×128全回放的历史TIMEOUT结论。

金融接收包先完整校验数据报再回放事件；合法零长/未知消息仍消耗序号，
心跳/结束消息有独立语义，65位求和拒绝序号回绕。它是单缓冲协议端点，
不提供重传或完整订单簿。价位撮合包独占既有订单簿，通过BEST、限价比较和
SUB完成交易；扣量确认后才发布成交，输出停顿期间不接受维护或后续IOC。
它处理汇总价位，不提供单笔订单身份和时间优先队列。两个包提供各自实际
接口例子，未声称行情事件已直接转换为可交易订单簿。

带宽测量用一块功率RAM和一个分时乘法器，计算精确整数交叉乘积；低界严格
大于阈值，高界大于等于阈值。100%请求排除前后零功率，零总量独立返回
NO_POWER。结果是离散bin边界/跨度，调用方负责频率轴和测量方法，未宣称
连续频带或监管认证。实际I/Q例子连接未改的mag_squared，完整最大4096bin
配置和1024bin例子均有有限仿真。

图形存储串行完成同地址片元读改写，提供ALWAYS/LESS/LEQUAL/NEVER深度模式、
独立Z写使能、RGB通道mask和精确/255透明混合。最大128×128的3个完整帧回放
49152像素通过；实际triangle_depth64例子连接未改的三角形光栅器，核对5个
重叠三角形形成的4096像素结果。最大存储655360bit，架构风险明确为HIGH；
不能把有限仿真当成器件容量或时序证据。计数饱和路径仅源码检查。

新增包的实现前均完成语义去重和只读外部主源/许可证审查。参考分别来自
Nasdaq官方规范和固定MIT解析器、eCFR与固定BSD SciPy参考、固定Zlib
TinyRenderer、固定Apache-2.0 exchange-core。未复制或执行外部实现。
各包SOURCES文件保存具体版本和引用范围，生产依赖全部在仓库内闭合。

复用保持原路径和原字节：两侧price_level_order_book及其ordered dictionary/
同步RAM、mag_squared、triangle_rgb_raster。快照的canonical清单对共享源只
列一次，未修改成熟依赖，未以包装或位宽变化重复计新能力。

交叉审查为A审撮合、B审图形、C审行情、root审带宽；均无阻断项。撮合测试
中的busy虚拟offer属于可撤回的对抗刺激，不作为合法未来事务一直保持到
接收的证据；该覆盖边界已写入README和delivery。B另行审查静态快照脚本。

每包根目录及example/files.f均从包根解析。B35_DELIVERY.json桥接精确执行源、
当前交付源及证据；[累计快照](snapshots/source_20261106_b35.json)和
[源码结构审计](snapshots/source_20261106_b35_structure.json)记录完整调用闭包、
module去重与继承基线。[审计脚本](snapshots/audit_source_20261106_b35.py)只做
源码完整性检查，读取继承HDL的已提交B34字节，不调用编译器。旧全库checker
不支持此证据格式，保持NOT_RUN。

本批只提交四个新包和具名B35文档/快照，不触碰工作区其他改动。成功VVP在
提交和逐字节核验后按receipt中的路径/哈希逐个清理，清理记录另见closeout。
持续开发目标保持active，本批是有效进展。
