# B49：驻留码本、逐订单撮合、FFT FIR 与多停靠点渐变

基线：`05b9614c3962e9d4ae934c4b9c7bd315cc01aed4`（B48 最终提交）。
本批严格四条通道，交付四个实际 RTL 功能包、独立模型、完整离线源清单、
真实组合示例及有限检查。四包当前均有成功的有限 RTL/示例证据，全部仍为
**HW_UNVERIFIED**；没有综合、映射、PnR、STA、上板、PPA 或历史工程回归。

| 通道与包 | 可用能力 | 实际示例 |
|---|---|---|
| root：[signed8_codebook_search](../cores/acceleration/signed8_codebook_search/) | 驻留 signed8 码本的精确平方距离搜索、最低索引平局、次小距离差、码字重建及 signed9 残差 | 残差连接既有 RNE/饱和重量化核 |
| A：[price_time_order_matcher](../cores/acceleration/price_time_order_matcher/) | 单品种逐订单限价撮合，maker 价格、价格优先及同价 FIFO，完整64位 ID 取消/查询 | 两客户端轮询仲裁、成交流client标识及分别返回的完成valid |
| B：[fft_overlap_save_fir](../cores/signal_processing/fft_overlap_save_fir/) | 实际系数 FFT、输入 FFT、频点复乘、归一化 IFFT、重叠历史及自动有限尾部 | 实数系数/输入适配器，并显式保留虚部量化残差 |
| C：[multistop_linear_gradient](../cores/image_processing/multistop_linear_gradient/) | signed Q10.8 二维坐标投影、PAD/REPEAT/REFLECT、多停靠点及最终有理 RNE RGBA 插值 | 实际既有 Porter-Duff 合成，含13种合法模式 |

可调用入口与限制见 [B49 增量功能索引](IP_INDEX_20261107_B49.md)。各包新增的
QUALIFICATION 与 DELIVERY 是当前执行记录；封存 README/manifest 的未执行
字样保留其执行前状态。底层核的历史资格不自动转移给本批组合。

## 五份实际回执与保留的失败

| 所属/尝试 | 数值准备 | HDL PASS | HDL FAIL | HDL TIMEOUT | 成功仿真 | 原始镜像 |
|---|---:|---:|---:|---:|---:|---:|
| root，唯一尝试 |4|11|0|0|4|4|
| A，唯一尝试 |3|11|0|0|4|4|
| B，唯一尝试 |4|11|0|0|4|4|
| C，首次尝试 |5|3|1|0|0|1|
| C，独立 followup01 |0|12|0|0|5|5|
| 合计 |16|48|1|0|17|18|

共65个实际子进程：16次准备和49个 HDL 子进程，其中64 PASS、1 FAIL。
没有自动重试。C 首次最小配置仿真在 EOF 检查处以 `extra vector rows` 退出；
独立文本回读未发现额外逻辑行，只见尾部 LF，实际 fscanf 返回值未被打印。
原回执、TB、向量与失败镜像完整保留。其另行批准的 followup01 只更换复制 TB
的 EOF 消费块，使用 fgetc 逐字符检查空白；生产 RTL、原模型与既有依赖未改。
followup 复用原五份封存向量，不重跑准备，采用独立计划、guard、输出目录及镜像。

| 回执 | 状态 | SHA256 |
|---|---|---|
| [root](../cores/acceleration/signed8_codebook_search/reports/20261106T181832559017Z/results.json) |PASS|`a414acd84e3f3787a5f6cceaa56e2f689861b72b9f8ec872272e490b848c175f`|
| [A](../cores/acceleration/price_time_order_matcher/reports/20261106T183141267050Z/results.json) |PASS|`23181675d26c3172289e0369d657834195d7ff74355128a24abdc0c410b74489`|
| [B](../cores/signal_processing/fft_overlap_save_fir/reports/20261106T185726607567Z/results.json) |PASS|`404c920f9609d6371e8023a386c56b8e00155914b4e33090827875ca611db718`|
| [C 首次](../cores/image_processing/multistop_linear_gradient/reports/20261106T184434034464Z/results.json) |FAIL_STOP|`afa70ae8be75c8f96a4496f892dd400caf69d008bf1f2515afd6eef6debaba92`|
| [C followup01](../cores/image_processing/multistop_linear_gradient/followup01/reports/20261106T190048543353Z/results.json) |PASS|`67a3ca2da438d21aeaf213773c44b346441aa959745c7e4d33e143927ce8e18b`|

这些回执共保留65份 initial、65份 terminal、64份 validated、130份原始输出流
及18个原始 VVP 镜像。失败子进程没有 validated PASS 记录。所有目标均已退出，
无活动子进程或清理 helper。每次执行前均完成 root 与独立 Worker 全文审查、
最终源码/工具/计划哈希核验；子进程20秒、树终止辅助5秒、唯一目标退出观察2秒。
仿真 initial 先以 exclusive/fsync 持久化预检查镜像 SHA，之后才创建进程；
terminal 在解析 marker 前保存，validated 是独立侧车。该证明来自已审源码和
保留记录链，不扩张为独立时间戳认证。二进制留在忽略的工作目录，不进入 Git。

## 实际覆盖及主要边界

- 码本：132个查询回复、17832个配置回复、2551个重建/编码分量、43878次保持
  检查和53次复位。含末行唯一胜者、最大距离16646400、平局、完整前缀、残差
  ±255、RNE/裁剪以及旧编码尾部与新命令不同 shift/tag 的重叠。没有训练、
  近似搜索或应用准确率声明；距离差不是概率。
- 撮合：主向量与实际示例共581个完成、49个成交、3088个保持周期。它们不含
  复位前导的额外命令/成交。18个核心复位探针与示例两个 reset pulse 分开计数。
  最大向量含31个 maker 扫描。NEW 在任何成交前必须已有空槽，满簿保守拒绝；
  没有市场/IOC、原子改单、风控、自成交防护、行情会话或交易场所资格。复位
  取消账簿 epoch，不逆转外部已接受成交。
- FFT FIR：111个配置、284个命令、921个 tap、10067个实际输入、10687个数值
  输出、131个标记、37693次保持；另有4个向量复位与44个定向复位（含初始复位）。
  31个独立已知时域响应断言覆盖2576样本。接受数值是逐级定点 FFT/复乘/IFFT
  链，不能声称理想卷积 exact。完整 M=N 尾部仅在 N2/N8/N64 闭环；N256 的
  M=N 持续/历史与首块尾部复位已测，完整256块尾部明确未测。内部 FFT 故障路径
  只读源审查，未做故障注入。
- 渐变：成功 followup 的五次仿真共75案例、3175主输出、12700主保持检查、
  40个 live-reset fixture、40个恢复输出、10个未来查询结果及5个管理竞争结果。
  这些不是全部 reset pulse 或管理命令总数，也不累加首次未完成仿真。颜色空间由
  调用者约定；没有 gamma/色彩转换、完整 SVG/CSS、帧缓存或显示系统资格。

## 支持源、离线闭包与索引范围

本批新增八个生产/示例 HDL，并显式纳入一个原样工作区支持源
`cores/acceleration/stream_fft/rtl/stream_fft.sv`：17313字节，SHA256
`e40a46cb051b2efbdf504221c91779a65e1787dffb5fbcf7db28b87ee660b535`。
它在基线树中不存在，属于原工作区原创 Apache-2.0 源，本次按新增必要桥接
依赖纳入；只纳入这一 RTL 与其内嵌 ROM，不纳入旧 FFT manifest、脚本或历史
硬件报告，也不继承旧资格。其余所用成熟源保持原字节，证明见各包依赖文档。

四包的 files.f 和 example/files.f 都从各自包目录解析，含实际依赖的相对路径；
可手动离线调用。旧 `scripts/ip_assets.py` catalog 尚未接入此正式支持源闭包：
它要求 standalone dependency 对应 manifest，而本批不引入旧 FFT manifest。
工作区额外文件带来的偶然发现不能作为正式可调用证明。当前入口是本批增量
索引与封存文件清单；旧 catalog/schema 适配须另行审查，不能扩张本批已测状态。

FIR 源估计为两个共享实乘法算子、四块复数 N-word RAM，默认8192bit、最大
49152bit 逻辑 payload，另有 scalar/ROM；不是两个物理 DSP 或 BRAM 数量。
物理 packing/乘法映射 MEDIUM、串行延迟 HIGH、无指定器件故适配 UNKNOWN。
所有四包的器件资源、频率、功耗、外部 IO 和板级适配均未由本批建立。

B 的 review_revisions/01 八份未批准、未执行候选文本只留工作区，排除正式集合
和 staging；不删除、不执行、不作为 PASS 证据。所有失败、原始镜像及继承的
保留/清理拒绝记录继续保存。

## 静态快照与提交状态

父批次的权威成功入口是 [B48 followup01 source](snapshots/b48/followup01/source.json)
和 [structure](snapshots/b48/followup01/structure.json)，其原失败与更正由
[RECOVERY](snapshots/b48/RECOVERY.md) 解释。不能继续引用未产生的 B48 原始
source/structure 路径作为成功证据。父域为192包、420规范 HDL、422模块声明。

B49 的预期入口为 [source.json](snapshots/b49/source.json)、
[structure.json](snapshots/b49/structure.json) 和 [closeout.json](snapshots/b49/closeout.json)。
本文起草时，这些静态/提交 gate 尚未完成；四包有限 PASS 不代表全库静态或提交
已完成。196包、429规范 HDL、431模块声明只是192+4、420+9、422+9的候选
算术，必须由最终独立静态审计确认，模块冲突也须重新检查。若有独立修订，应
另加明确 recovery 指针并保留原失败。最终执行前冻结本文及增量索引；实际状态
以其后独立生成的快照/closeout为准。
