# B30 C 只读候选简报

日期：2026-11-05。状态：**候选准备完成，等待 root 选择及 authoring 通知；B30 baseline 尚未建立。**

推荐 **A：灰度稳定极值区域检测（MSER 的单侧面积变化变体）**。它在已存在的完整 max-tree 上新增真正的跨灰度稳定性选择，输出可重建区域的种子、阈值、面积与精确变异分数。备选 **B：局部空间约束的整数超像素分区**；第三顺位 **C：8-bit 灰度 JPEG-LS 无损编码**。三者均未在当前能力库中找到等价生产实现；C 的标准码流验证成本最高，不建议作为本轮首选。

本次只读文件、检索上游 HTTPS 内容并写本简报。没有创建包、RTL、模型、向量、准备计划或基线；没有 Git 写入、共享 docs 修改、工具版本/编译/仿真/综合检查、任何旧准备/模型/回归执行、上游安装/构建/执行或子代理委派。上游源码只进入内存，未写入仓库或生产依赖。

## 1. 当前能力集合与语义去重

读取 B28 的 112 包路径及各包 README 能力摘要，再加入 B29 已有四包，合计 **116**：image_processing 29、signal_processing 29、acceleration 29、storage 25、system 4。B29 发布快照在本次读取时尚未生成，故没有把尚不存在的快照写成已经检查的 baseline。

绑定：
- B28 清单 docs/snapshots/source_20261105_b28.json，SHA256 f43bd71e5e6ad99582e05c2b39ab6c46daf730739339386b7460a0db1d6e2858。
- B29 四项为 ram_ordered_dictionary、exact_1d_tv_denoise、grayscale_anisotropic_diffusion、exact_directed_hamiltonian_cycle；读取 .git/anscore-b29-features.json，SHA256 c130c779cb1075c0d945a98a65833ad8f142fbb5979d5ddbb8d2d97ef18cf9ad。
- 按 B28 顺序再追加上述四路径，以逐行 LF 和末尾 LF 编码的 116 路径清单 SHA256：a656d99165942a2a0c9b8552f119e5b2b554adf26d6f9172d9888338f8f20888。

范围同时覆盖 cores/image_processing 的 34 个直接目录、common_scaffold/image 的 124 个直接目录、dsp_isp_library/isp 的 20 个直接目录，以及 signal_video、extended_library 的实际功能入口。目录数量包括 legacy、candidates、review、sim 等，不能当成独立 IP 数。读取 IMAGE_EXTENSIONS、ISP 的 SPEC/README 能力摘要、isp_stream 的核心/复用/旁路契约；重点逐语义读取最接近候选的实际 RTL。

在 cores 下检索 2,969 份生产文档及 V/SV 文本；排除 evidence、failure_archive、history、board、simulation、sim、tb、vectors、fixtures、candidates、reports、verification、build/legacy 与 review 拷贝。SLIC/superpixel 只命中旧 Hu 来源中的排除说明；MSER/extremal region 只命中 max-tree 来源中的检索记录；JPEG-LS/LOCO-I/CharLS 只命中 B28 来源中的未采用备选说明。没有把这些说明当成实现，也不把关键词无命中当成库外不存在的证明。

| 已有实际功能 | 与候选的边界 |
|---|---|
| grayscale_max_tree 的 canonical parent/level/area；grayscale_area_opening；GLSZM | 层级、属性滤波或等灰度区域计数均已存在；没有 Δ 祖先面积变化、局部稳定性比较和稳定区域选择。A 必须增加这些实质运算，不能只重发树。 |
| kmeans_rgb_frame、完整 Lab→K-means→RGB 量化器 | 已有真正的全帧颜色 Lloyd 更新；没有固定网格局部候选中心、空间项、稳定区域 ID 以及每个输出区域的连通保证。 |
| mean_shift_frame | 实际对每个原像素独立迭代 joint spatial/RGB mode，输出 mode/support/converged；不是多个公共中心的交替分配，也不产生连通超像素分区。B 因此仍有不同的服务结果。 |
| FH graph segmentation、watershed、binary CCL、RAG、max-tree | 自适应边证据分区、种子泛洪、前景分组、接触边和阈值层级都已存在；不能以重新命名或单纯标签后处理冒充 SLIC。 |
| 完整 Canny、FAST/Harris/Shi–Tomasi、BRIEF/旋转 BRIEF、多尺度前端、HOG/LBP、Hough | 多尺度前端实际为 Gaussian pyramid + FAST9/NMS/centroid/rotated BRIEF，不是 MSER；A 不再加入重复角点/描述子流水。 |
| HE/CLAHE、Niblack/Sauvola、NLM/双边/Wiener、导向/Retinex、PM 扩散、1-D exact TV | 均有实际算法，排除这些作为 B30“新增降噪/增强”候选。A/B 输出区域，C 输出标准压缩字节，均不同于这些强度估计。 |
| L1/L∞/精确平方 EDT、Chamfer、Hausdorff；thinning/重构/洞填充/拓扑 | 已有完整距离/形态/拓扑服务，排除“新距离变换”“骨架”之类重复方向。 |
| RAW/Bayer/BLC/AWB/CCM/Gamma/LSC、chroma、卷积/gradient/median/morphology、remap/scale/stats | ISP 已覆盖完整采样、颜色、窗口、几何和测量；本轮不新建重复 ISP 包装。isp_stream 的实际 RAW→RGB/control/旁路并不提供 A/B/C。 |
| GIF LZW、QOI、PNG、TIFF、BMP、RAW、baseline JPEG 编解码 | JPEG 灰度 encoder 实际是 DCT→量化→差分 DC/AC RLE/Huffman→JPEG/JFIF；C 则新增 LOCO-I 预测、上下文自适应 Golomb 与 run interruption，不是同一编码器或简单无损参数。 |
| 其余 116 项：图论/离散优化、数论/代数/统计、RAM/调度和事务服务 | 通用 DSU、树和算术可以作为后端复用；本身没有从像素生成所提稳定区域、局部超像素或 JPEG-LS 码流的契约。 |

最近实际 RTL 的只读绑定：

| 文件 | SHA256 |
|---|---|
| cores/image_processing/grayscale_max_tree/rtl/grayscale_max_tree.sv | 39d42c70847386e1094fbc6faa3a346cb3af721ff75cbf4a4632769b6364d2e5 |
| common_scaffold/image/kmeans_segmentation/kmeans_rgb_frame.sv | fac0a4fd89af8306f72dec8d90a5e9381a72591c0e9c1d20959bbe4ff2ba1203 |
| common_scaffold/image/lab_kmeans_quantizer/lab_kmeans_quantizer.sv | 7a14187ed39efaca6d2acfab6d4cf2bda5d090a095175e657be5ad66568bbbae |
| common_scaffold/image/mean_shift/mean_shift_frame.sv | 899a9f1835408f42a6fb4c83884ff869d520ebe70f3730bdef272d96eec71022 |
| common_scaffold/image/jpeg_gray_encoder/jpeg_gray_encoder.sv | f44612cfb66d6d8568961565dfc211c2762ab3c7898aebc078a2494baf5fe474 |
| cores/image_processing/isp_stream/rtl/isp_stream_core.v | 6cccafe289ec7b0aeee439db2b696b0db15d2c13d3298127ce5edd7c19c668b7 |

表中 common_scaffold 相对 cores/system。没有修改或重新执行这些源码及其历史测试。

## 2. 上游只读检索和许可

web 搜索入口实际返回 HTTP 500，之后改为直接读取官方文档、GitHub API 和固定提交的 raw 文件，没有安装或执行其代码。以下是本次实际取得的资料，不是待查链接。

| 候选 | 实际资料与固定版本 | 许可及使用边界 |
|---|---|---|
| A/MSER | [VLFeat 官方说明](https://www.vlfeat.org/overview/mser.html)；[mser.c](https://github.com/vlfeat/vlfeat/blob/1b9075fc42fe54b42f0e937f8b9a230d8e2c7701/vl/mser.c) 的定义、Δ ancestor、variation、邻级选择和过滤段 | 文件头指向 BSD；完整 [COPYING](https://github.com/vlfeat/vlfeat/blob/1b9075fc42fe54b42f0e937f8b9a230d8e2c7701/COPYING) 为 BSD-2-Clause。官方明确其单侧稳定性定义与原论文并非完全相同；本地应如实命名，不能声称逐位复现原论文或浮点 VLFeat。 |
| B/SLIC | 同一固定提交的完整 [slic.c](https://github.com/vlfeat/vlfeat/blob/1b9075fc42fe54b42f0e937f8b9a230d8e2c7701/vl/slic.c)，含空间/颜色联合特征、局部四中心、Lloyd 及连通小区域处理 | 同一 BSD-2-Clause，文件头归属 Vedaldi/Fulkerson。所提整数灰度、固定迭代与连通分裂是明确受限变体，不以浮点 C 输出作为 bit-exact golden。 |
| C/JPEG-LS | [JPEG 委员会官方概览](https://jpeg.org/jpegls/index.html)；CharLS 2.4.2 解引用到 36dd3307e070d8fbc765c3ba890b7e681046fa39；读取 [scan.h](https://github.com/team-charls/charls/blob/36dd3307e070d8fbc765c3ba890b7e681046fa39/src/scan.h) 的 regular/run 编码段、完整 regular/run context 和 bit writer | 各头部 SPDX BSD-3-Clause；完整 [LICENSE.md](https://github.com/team-charls/charls/blob/36dd3307e070d8fbc765c3ba890b7e681046fa39/LICENSE.md) 为 BSD-3-Clause。T.87 规范全文和独立互通执行尚未完成，故 C 的准入风险高于 A/B。 |

关键下载内容的 SHA256：

| 内容 | bytes | SHA256 |
|---|---:|---|
| VLFeat MSER 官方说明 HTML | 15,504 | 77e2c8287895cd3e2ee1f5ee5ce136f9bdc81b4b69dbf5c53de931f8f8f175be |
| 固定 mser.c | 30,291 | 2f0ec3813d4d119bfdaa4b5f6749f97ee04af0fc9957ef0325d9cd12817a5064 |
| 固定 slic.c | 14,119 | db4b0c4e1ed45cc4b6b1717ee4d71dda201fccd01b4922307fd9c632d6804c8b |
| 固定 VLFeat COPYING | 1,365 | 33b9f7703327199088d74f884b19997a0084180f984724720095a7cb412c4d89 |
| CharLS LICENSE.md | 1,536 | e293ccc327ee42f4e723e73aac39b23ffc40655cc6f8baec5c046f2e7d093695 |
| CharLS scan.h | 37,279 | 013f9a23d2a0e85ad93569211bb40b0e6558ed15bd3bd6d24edccc6c7af8bd1d |
| CharLS context_regular_mode.h | 3,153 | 202af82bb2393b54c37929e1103fec1043cf879b5b86bbafa7835218e72fc52c |
| CharLS context_run_mode.h | 2,975 | a7d87389c5fd7449d73c0b4126e3beac9878d233d4a4685f4840a3b54c165d06 |
| CharLS encoder_strategy.h | 4,663 | 8919c6b1dd9e2f8fb27c3d1d61c1fb92711fba62490273fa03ab536c64860808 |
| JPEG 官方概览 HTML | 7,576 | 85617680d8e2077b894c9c3abb86bb34c606040e72a4b6700703ff60fecd8af5 |

目前没有第三方代码进入交付物。推荐根据公开数学/协议独立编写 bounded RTL 和独立参考；若之后决定采用、翻译或分发任何具体上游代码，应在实际 authoring 中保留对应许可证、归属和修改说明。BSD 文档核对不等于专利清查或对库外权利的保证。

## 3. A：稳定极值区域检测，推荐

### 新接口和数值契约建议

- 原始 unsigned8 灰度 raster，WIDTH/HEIGHT 各 1..16，默认 8×8；CONNECTIVITY 为静态 4 或 8；TAG_W 1..32。N=WIDTH*HEIGHT。
- 首个实际接受像素锁存 tag、bright/dark polarity、Delta=1..255、min_area/max_area 和非负 max_variation 的 8-bit 分子 P、非零 8-bit 分母 Q。面积合法 1<=min_area<=max_area<=N。
- 明确采用 VLFeat 风格的单侧区域变异，不称原始对称 MSER 的完全实现。bright 使用 f 的 upper tree；dark 使用 g=255-f 的 upper tree。只需一次极性变换和一次树构建。
- 对每个 canonical node v，找到包含它、灰度距离不超过 Delta 的最大祖先 t；灰度间隙是真实 intensity gap，不能把“走 Delta 个节点”当作 Delta 灰度。根处截停，不绕回。
- 精确变异为 V(v)=(A(t)-A(v))/A(v)。保留分子、分母，不使用浮点、除法、容差或饱和。
- 初始化 canonical stable 标志。只对灰度恰相差 1 的 distinct child/parent 比较两分数；较小者保留，较大者取消，相等时父保留。若灰度间隙>1，紧邻阈值代表同一集合，不强行跨间隙比较。最终固定排除全局根；要求 min_area<=A<=max_area 且 V<P/Q。min_diversity 固定为 0（不做重复区域抑制），不拟合 ellipse。
- 每帧仍返回恰好 N 个 raster-order 记录：index/canonical/selected/original level/area/variation numerator/denominator、SOF/EOL/LAST、first tag/status。selected=1 的 index 即区域 seed，可按 polarity、level 和 connectivity 从原图重建完整区域。非canonical 的数值字段规范为零；根 selected=0。N=1 因而正常返回一条未选择记录。
- 记录所定义的 pairwise flags、根排除、严格变异上界与面积包含边界均应在 authoring 前冻结，不能由软件浮点误差或测试结果反推修改。

### 架构、复用和预算

直接复用已经提交、Apache-2.0 且已具普通 ready/valid 的 grayscale_max_tree RTL，**不运行其旧 regression/preparation**。新增控制器接收它的 N 条 tree 记录，存入本帧 node RAM；完成后串行 Δ 祖先遍历、精确分数比较、flag 写回和最终回放。子树完成最后一条后虽可返回 capture，外层仍阻止新帧，直至自己的最后输出退休。reset 同时取消外层和子核，避免复位后旧 child output 混入 fresh frame。

每个 node 仅保存 level(8)、parent(IW)、area(CW)、canonical(1)、variation numerator(CW)、selected(1)，其中 IW=max(1,clog2 N)，CW=max(1,clog2(N+1))。新增逻辑 RAM 为 N*(10+IW+2CW)：默认 N64 为 1,920 bits，N256 为 **9,216 bits**。结合旧树核公开逻辑 RAM（默认3,968、最大13,056），合计 **5,888 / 22,272 bits**，约0.72/2.72KiB。标量、读寄存器和输出寄存器另计。单个9×9串行 shift/add 比较通路可做两个交叉乘积；完整18-bit乘积足够，不需要 DSP、通用除法、额外原图或每区域 mask RAM。

单端口 clocked-read node bank 分开读/消费/写，避免多口树阵列和同址碰撞依赖。对所有 N 个节点，每条祖先路径最多 N，新增祖先访存最多约2N²拍，分数比较与扫描 O(N)；合并旧核给出的全域最坏491,787拍后，先给完整服务约 **0.65M拍/最大帧** 的纸面预算，最终应从新 FSM 精确重算后冻结。它不含源空隙/输出背压，不是实测速度、Fmax 或物理资源承诺。默认风险 LOW/MEDIUM；最大风险 MEDIUM，主要在树访存与 RAM 粒度。

原 max-tree 是已提交依赖，不触及 B29 中受保护的原 divider。后续 files.f/DEPENDENCIES 应精确绑定这个已有 source/hash；离线导出须带齐它的生产源与许可。若交付约定要求独立目录内完整闭包，应在 authoring 开始时选定合法的 dependency packaging 方式，不能在执行后再悄悄改旧路径或 seal。

### 固定有限输入计划建议

这是将来可冻结的选择，不是已生成向量或已批准执行：

| 固定 profile（W,H,K,T） | 固定完整主帧 |
|---|---|
| P0=(1,1,4,1) | 0、255 两常值；各一份错误 SOF/EOL，共4帧 |
| P1=(7,1,4,3) | 升阶、平坦段、中心嵌套、跨 Δ 间隙；两 marker error，共6帧 |
| P2=(4,4,8,8) | 对角连通、鞍点合并、同灰不同 flat-zone 被高灰连接、变异相等父优先，共4帧 |
| P3=(8,8,4,8)，默认 | 嵌套台阶、分支合并、相等分数、严格变异阈值相等、面积上下界、固定完整字节图；另4帧配置错误（Delta0、Q0、min_area0、min>max），共10帧 |
| P4=(16,16,8,32)，最大 | 常值、256灰升/降 ramp、checkerboard、嵌套、固定完整字节图，共6帧 |

共 **30个主帧**，按每个具名 case 单独指定极性和配置，不作几何×极性×Delta×阈值的 Cartesian 展开。P3 的手工图必须在准备阶段提供差异证书：level gap 与 node-count gap 不同、严格等号拒绝、分支局部稳定性、变异相等父优先。独立 oracle 用逐阈值 connected sets/Fraction 计算结果，不调用旧 max-tree oracle，也不按 RTL bank/祖先 FSM 写法计算。

固定10个 reset target：R0 partial capture、R1 child histogram work、R2 child link work、R3 child tree 输出中途、R4 新 Δ 祖先非根读取、R5 新乘积 pending、R6 selected flag 写回前、R7 首条正常输出 held、R8 最大 profile 末条 held、R9 配置错误输出 held。R0..7 用默认 profile，R8 用最大，R9 用默认错误；各自后接一份完整固定 fresh frame，新增10份完整 fresh 输出。只观察这几个集成边界，**不继承旧核全部状态复位矩阵**。检查 first config/tag 锁存、下一帧真实 offer 阻塞、所有字段背压稳定及取消后无陈旧输出。

最大 profile 六主帧预先分为三组，每组固定两帧；默认 reset 一组，最大末条 reset 和错误 held 各一组。不能在 timeout 后再拆组、缩图、换刺激或延长限制。每个 compiler/simulator 进程树硬限20s、首失败停止、原始stdout/stderr和NOT_RUN尾保留、无自动重试。具名静态拒绝仅 W0/W17/H0/H17/K6/T0/T33，避免无意义参数笛卡尔积。预估每个最大主 child 不超过约1.3M有效拍；20s墙钟仅为预设终止限，目前没有实际计时证据。

## 4. B：局部空间约束整数超像素，备选

### 真正新增的服务

从实际灰度生成相互共享中心、受空间邻域约束并最终4连通的区域分区；结果可直接供 RAG/区域统计后端使用。它不等同于已有颜色量化，也不把 mean-shift 的每像素 mode 当成公共分区。明确称 **SLIC-style 整数灰度受限变体**，不承诺原论文或 VLFeat float 的逐位标签。

建议 WIDTH/HEIGHT 各1..16，固定 grid step S=4，C=ceil(W/4)*ceil(H/4)<=16；I=1..8、M=0..32 首像素锁存，默认8×8/I4/M8。初始化中心为各截断 tile 中心，无随机种子；首版不加入3×3梯度挪动。每像素只比较原始网格相邻的最多2×2个中心，候选集合由固定格位决定，不能因中心移动丢失覆盖。

整数中心 (cx,cy,cg)，距离精确为：

    D = 16*(g-cg)^2 + M^2*((x-cx)^2+(y-cy)^2)

D 最大1,501,200，21-bit unsigned足够；三类差先扩位再平方。按距离最小、再原网格 ID 最小决定标签。每一轮对完整旧中心分配所有像素，然后中心分别取 sum/count 的 nearest-half-up；空中心保留旧值。执行恰好 I 轮更新后，再作一次只分配 pass，输出对应最终中心的标签。没有自适应提前停机，也不加入多通道/Lab/任意区域数选项。

随后对每种标签的每个4连通分量独立分裂，发布该分量最小 row-major 地址作为 canonical region ID；不合并小区域，不假定一个网格中心最终只对应一个连通分量，最终 region 数可高于 C。该步骤是实际 connectivity 服务，不能只给 disconnected label 而称连通超像素。输出 N 个 raster records：canonical label、原像素、标记、first tag/status；附 frame region count 即可，不增加 bbox/ellipse/外部聚类模型。

### 架构与预算

灰度/标签 RAM、C项中心及 packed sums/count RAM，单个约11×11的分时乘法路径及一个定宽串行除法路径。合法中间界：gray sum<=65,280（16bit），x/y sum<=3,840（12bit），count<=256（9bit）。数据相关状态不能用32-bit integer偷放大。源码中的乘法可由目标映射 DSP 或 LUT；这里没有测量映射，不强制零DSP。

连通分裂可实际复用已提交 DSU，对相同 cluster-label 的右/下边发 UNION，再扫描 FIND；rank representative并非最小地址，需另外做 root→minimum归约后输出，禁止直接把 DSU root 当canonical label。最大N256时，DSU parent/rank约3,072 logical bits；frame/labels约4,096，center+stats约1,040，root minimum再2,048，合计约 **10,256 bits**（另计标量、读输出寄存器）。这是纸面预算，不是BRAM映射数。若选择 BFS 而非DSU，需在 authoring 首次冻结前比较队列/visited和清除成本，只选一种，不做实现候选批跑。

最大 I8、四候选/像素的距离工作8,192次；含均值更新、最终分配、CCL与回放先预算 **0.25M有效拍/帧**，待FSM精确核算。单端口访问与乘法寄存切开长路径。风险 MEDIUM；区别于A，它需要新的完整聚类控制器及CCL集成，维护成本更高。

### 固定有限计划

固定 P0=1×1、P1=7×5、P2=8×8默认、P3=16×1、P4=16×16最大，绝不展开全部形状/迭代数/M。每profile固定4帧，共20主帧：常值、分离同灰斑、step/不对称位置、固定字节图；I/M逐case具名指定，含I1/I8、M0/M32的实际数值计算。P2另加I0、I9、M33三个配置错误，共23主帧。常值tie、empty center、整数半值、移动后仍用固定grid候选、一个原cluster label产生多个连通分量，须各有准备期证书，不能在HDL后换case凑覆盖。

固定7个reset：capture、center-read、square/product、sum-write、division、CCL union/result、last-output held；各接完整fresh frame。最大主四帧预先分两组两帧，默认reset一组，最大held一组。独立oracle用简单列举候选/整数和、集合flood-fill做分裂；不复用RTL调度或旧DSU测试。比较每个像素标签和统计，检查所有输出region确实4连通及ID最小。逐进程树20s硬限和首失败策略同A；20s可行性是纸面工作量判断，尚未运行。

## 5. C：灰度 JPEG-LS 无损编码，第三顺位

这是完整新码流能力，不能用“JPEG quality=100”、PNG stored blocks或QOI替代。建议8-bit单分量、NEAR=0、ILV=0、Pt=0、默认T1/T2/T3=3/7/21、RESET=64，WIDTH/HEIGHT各1..32，默认16×16。输出实际SOI/SOF55/SOS、标准scan、EOI；首版不做near-lossless、RGB、多scan、restart或自定义MAXVAL。

必须同时实现MED预测、梯度量化/符号归并、365 regular contexts、两个run-interruption contexts、受限Golomb和run-index状态；仅regular mode不是完整JPEG-LS。CharLS bit writer实际在熵字节FF后插入单个0bit、下一字节承载7个数据bit，不能套用baseline JPEG的FF00字节转义。编码/码流结束、run末行、负误差模RANGE与context rescale是主要风险。

接口建议先捕获完整N个实际像素并检查SOF/EOL，再开始输出header/scan，保证marker错误不会先泄露一段貌似有效文件；输入tag/config归首像素。完整raster加两行工作历史、串行单context读改写、32/64bit受控bit reservoir，无DCT/乘法/除法要求。按每regular context不超过48bits的保守预算，365*48=17,520bits；加两run contexts<=128、32×32原图8,192、两行544及约128bit writer，合计约 **26.5K logical bits**，标量另计。最终A/B/N/C的紧字宽必须从完整标准中间域证明，不能把这个预算直接当已证明的最窄宽度。预计单像素几十拍、最大约0.1M有效拍，纯逻辑风险MEDIUM，标准一致性和参考独立性风险HIGH。

固定4个profile：1×1、13×7、16×16默认、32×32最大。每个固定4帧，共16主帧：常值、ramp、交替极值、固定字节图；最大中的固定图应预先设计出regular context的RESET=64 rescale、两种RItype、Golomb escape和实际FF后7bit路径证书。另在默认加SOF/EOL各一错误，共18主帧。固定6次reset：capture、context-read、context-write、run interruption、bit flush、EOI held；各接完整fresh frame。最大四主帧预先两组；比较完整header/scan字节，并用独立decoder重建每像素。不能只做自家encoder/decoder闭环或只看压缩长度。

**本候选仍需在authoring前补齐T.87全文的规范核对和参考策略**：若采用可离线的固定CharLS片段/已审阅参考移植，必须实际处理BSD-3-Clause归属并明确其与RTL参考的独立性；若独立编写std-lib oracle/decoder，则需要从标准定义而非RTL逐行翻译。当前没有构建/调用CharLS，未取得本地互通或20s执行证据，因此排第三，不将其写成已经通过准入的首选。

## 6. 选择和停止点

| 方向 | 新能力强度 | 真实现有复用 | 最大logical RAM纸面量 | 主要风险 | 顺位 |
|---|---|---|---:|---|---:|
| A 单侧稳定极值区域 | 在跨阈值层级上新增精确稳定性/区域选择 | 已提交max-tree直接实例 | 22,272 bits，含树核 | 祖先灰度间隙、分数tie、局部min及集成ownership | 1 |
| B 局部整数超像素 | 新空间约束共享中心+连通分区 | 可用已提交DSU | 约10,256 bits | 空中心/量化/固定候选与canonical CCL | 2 |
| C JPEG-LS无损编码 | 新的完整标准预测压缩码流 | 部分通用stream/bit writer概念；不复用DCT | 约26.5K bits | 规范细节、run/context更新、FF bit stuffing与独立互通 | 3 |

建议 root 选择 A。它用现有已提交树核承担已经存在的层级构建，新增计算本身小而明确；数值完全整数、无外部运行时依赖，有限case能集中验证真正新风险。B可作为下一轮候选；C适合另立标准码流专项。

本简报采用 fpga-rtl-pareto 的算法/数值/架构预算方法；没有因加载技能启动仿真、综合、PnR或候选搜索。以上周期与存储均为纸面设计预算，所有新能力仍为NOT_AUTHORED / NOT_RUN / HW_UNVERIFIED。**到此停止，不建立B30 baseline、不创建package、不冻结/准备/执行计划；等待root选择与authoring通知。**
