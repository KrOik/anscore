# 2026-11-05 第二十九批与累计116包源码快照

基线 `481863a7318d510ca6717c1690a7107f363525de`，开发分支
`development/ip-assets-20261104`。本地稳定分支 `stable/source-20261105-b29`，
附注标签 `snapshot/source-20261105-b29`。原56个稳定引用保持不变，无push，Goal继续active。

|新增功能包|独立能力|当前有限证据|
|---|---|---|
|[ram_ordered_dictionary](../cores/storage/ram_ordered_dictionary/README.md)|任意unsigned键持久GET/PUT/DELETE、SEEK_GE、inclusive RANGE及CLEAR|3配置、22资格记录、9次仿真；430 CMD、617 REC、27 PROBE|
|[exact_1d_tv_denoise](../cores/signal_processing/exact_1d_tv_denoise/README.md)|带双向跳变的1D L2+TV精确有理解，原序输出|6配置、26有效记录、10次仿真；186 REC、198次输入握手|
|[grayscale_anisotropic_diffusion](../cores/image_processing/grayscale_anisotropic_diffusion/README.md)|四邻域有理PM导通扩散，运行时系数表与帧RAM迭代|5配置、26记录、11次仿真；2246 REC、36 FRAME、122完整ITER|
|[exact_directed_hamiltonian_cycle](../cores/acceleration/exact_directed_hamiltonian_cycle/README.md)|有符号缺边图的精确最小代价有向Hamilton环及完整见证|5配置、25有效记录、12次仿真；595 IN、344 REC、86 FRAME|

本批19组固定配置、99条有效资格记录：74 PASS、25 EXPECTED_REJECT，其中42次仿真。
实际启动112个资格child，包含2条原始失败和11条被新TB编译取代的历史成功编译；
32个历史NOT_RUN槽位独立保留。有效片段明确引用各receipt的record索引，失败receipt
不被改写成PASS。四次准备各执行一次；HDL期间只读已存储的元组、hash与证书，未重算模型。
B原首child只检查给定literal目标的KKT证书，不求解TV；修复后沿用原成功记录，没有重跑。
每个compiler/simulator进程树硬限20秒，最长有效child 5.687秒。
四包当前均为LINT_PASS、有限UNIT_SIM_PASS、HW_UNVERIFIED。

包内作者README/COST与原封印保留其历史NOT_RUN文字；当前状态以本页、累计manifest的
effective_segments和原始receipt为准。有限输入及具名参数证据不能扩展为任意参数证明。

## 调用、数值与架构

四包提供实际RTL、完整files.f、全端口最小示例、参数/接口说明、固定TB及许可证。
均为单时钟普通ready/valid，无公共CE或CDC；dictionary异步低有效复位，其余同步高有效。
有效输入或输出背压无界时，不承诺绝对完成时间。

dictionary支持CAPACITY1..32、键/值1..32位。已排序的packed canonical RAM配合串行
binary lower_bound和行移动；替换满表已有键合法，新键满表拒绝后不写入。RANGE按升序
返回ROW并以单独END结束；一次命令持有所有权直到RESULT/END退休。reset/CLEAR使旧行
逻辑不可见。默认RAM2048 bits，无乘法器；默认存储风险LOW、映射/控制时序MEDIUM。

TV支持N1..64、signed DATA_W2..24、TAG_W1..32，非负lambda随首输入捕获。两组同步bank、
一个共享shift/add比较器执行精确分数比较，输出分子/正分母可不约分；实际104行使用
等价未约分编码，按交叉乘积严格相等，无容差。默认/最大payload RAM672/3968 logical bits，
结构风险MEDIUM。完整向量捕获后求解，始终ready输出退休间隔两拍。

扩散支持宽高1..32、迭代0..16、8bit输入输出及UQ8.8内部像素，dt=1/8。256x9运行时
系数表避免逐像素重复除法；共享乘法器、W24整数除法器及ping-pong同步帧RAM。
默认/最大logical RAM10496/35072 bits，最大风险MEDIUM。TABLE/ITER raw是汇总记录；
逐系数、写入和held-cycle判据由编译TB断言检查，并非每项内部检查都单独打印到raw。
原始流含22 TABLE及2 TABLE_ABORT、122 ITER及2 ITER_ABORT、4 PROBE、12 RESETEDGE；
2198主行与48 reset-fresh行合计2246 REC。

Hamilton环支持N2..12、signed W2..24、TAG_W1..32，完整见证固定根0；缺环和输入错误
显式汇总。subset DP使用两个同步存储bank、共享加法/比较和parent回溯。同权选择为
reverse-lexicographic，不能称forward lexicographic。默认/最大payload RAM21723/747076
logical bits，默认MEDIUM、最大HIGH风险，工作量与存储随N指数增长。

以上位数、周期和风险是源码预算，不是测得的BRAM/DSP、面积、Fmax、功耗或设备适配。
未执行综合、PnR、STA、上板、继承数值矩阵或扩展回归。

## 原失败与限定续跑

root原attempt01有7 PASS（2 lint+5 compile），首main_p0_0在time0因TB尾部读取报
trailing fixture content失败，之后17项NOT_RUN。原141-byte raw没有IN/REC；七份夹具
数字字段恰好用完且仅余LF。实际$fscanf返回值未记录，不推定其具体值。132份原输入/
流/receipt/五份VVP完整保留。仅TB末尾换成signed integer $fgetc循环，允许ASCII9/10/13/32
直至-1，其余字节仍失败。attempt02只执行原计划[2:]的23项：5次新compile、12次simulation、
6次reject；沿用2旧lint，旧5compile列为superseded。新成功VVP审查后删除，旧5份永久保留。
实际另有2 ABORTREC、40 OFFER、6 PROBE、18 RESETEDGE、6 RESETDONE。

B原attempt_01有10 PASS（stored KKT、version、2 lint、6 compile），首normal_p0在
IN1/HOLD3/REC1/FRAME1后因TB FIXTURE_TRAILING_DATA失败，15项NOT_RUN。296-byte raw、
179份原文件和六份VVP完整保存；六份夹具均止于END加LF，无额外token，实际扫描返回值
未知。仅TB尾读取改同类严格whitespace $fgetc循环。repair_01只执行旧计划[4:]的22项：
6compile+10simulation+6reject；原first4成功沿用，旧6compile列superseded。
原始及archive副本合计12份文本VVP永久保留，新6份成功产物已审查并删除。
实际197 IN加1 NEXTIN=198输入握手，其中186 fresh与11 aborted IN；完整输出162 normal
加24 reset-fresh=186行。HOLD33、FRAME14、OFFER2、PROBE4、RESETAT4、RESETEDGE12。
最后NEXTIN是未完成下一帧的首输入，不计作完整数值案例。

A/C没有HDL失败。A首次Git入库发现.raw被text规则归一化，保留原失败元数据后仅增加
两条storage-only raw属性；准备及HDL不重跑。root另保留执行前approval metadata-entry
错误（编译/仿真child为0）及未执行repair runner稿，补充history可恢复原54/135份输入。
其错误输出明确是exec-tool转录，不冒充原始simulator streams。B准备前PE扩展名、实际
libstdc++-6.dll导入名、LF及严格raw顺序修订均有未执行历史，唯一准备未重跑。

## 离线依赖与累计冻结

清单静态审查发现C原sealed外部divider未纳入B28导出。它属于原21000个受保护untracked
文件，保持原路径、字节和未跟踪身份。封装修复只把其1797-byte原字节复制到C包
`rtl/deps/integer_divider.v`，两个repo-root files.f各做一次路径替换；旧两个列表、143文件
inventory与PACKAGING_RELOCATION绑定记录保留。原141份其他文件（含计算RTL/TB、准备、
封印、receipt及raw）完全不变。副本继承Apache-2.0，不计新功能；未重跑任何准备/模型/HDL。
见[DELIVERY说明](../cores/image_processing/grayscale_anisotropic_diffusion/DELIVERY.md)。

本次package-local路径迁移另有8-path提交 `b38478b49d50f6f639d65a5c9e182102847d2244`（6新增、2列表修改），C最终149文件。
未执行的旧三份metadata脚本及C原143份文件事先完整保存在命名.git历史，静态阻断没有被
记成已执行metadata失败。修订绑定与结构脚本分别独审后各执行一次。

封装修复第一次入库在git add之前被原保护守卫拦下：它未涵盖两个已跟踪列表的授权修改。
HEAD及空索引未变，脚本、输入、原始stdout/stderr、diff/index/refs已保留；排除这两个
精确列表后，原始保护diff逐字节一致。独审后仅为两路径及已批准hash增加预暂存例外，
提交后仍用无例外保护检查。这是一次入库metadata失败，compiler/simulator/model child为0，
不增加前述两次HDL失败，也没有重跑封装builder或准备/HDL。

累计116包，其中115包有有限UNIT证据、一包继承LINT-only。B28原112个package对象、
9797包文件和13 support逐对象继承，9810路径mode/type/OID不变。
新增909包文件，累计10706包文件+13 support=10719冻结路径；support无新增。
新增交付字节已核raw SHA256、index原始blob和feature/delivery Git OID。
继承部分以B28封印及不变Git三元组传递，不批量重读旧blob，不重试B25终结失败。

|通道|Feature commit|原提交文件数|
|---|---|---:|
|a|`4b63f7a80207b79ef123490eabab99b9dde18184`|243|
|c|`13dc193edfffd226973f0cf350b8a40c302fe245`|143|
|root|`9bac9aa4b736ab6a84be6e69fade2ecfc4da7602`|253|
|b|`d5486c563c1e9bd3c230ef057ea6b0c4b07418cb`|264|

freeze `9465e5e07ff863279ab90b390c03dbd9c09f8766` 只增加累计manifest。结构核验检查243
个唯一显式源路径，将B28 RAM alias替为canonical后去重一次，得到242个源、
233个top、244个module declaration，无未解决名称冲突。
四个列表有精确字节hash约束的基准例外：继承simplex/graph-segmentation两份example列表
按列表目录解释；C当前两份列表按repository root解释。其余按包根解释。

**总库checker及隔离合编NOT_RUN，启动0次。** checker原脚本不支持本批多片段证据及
继承投影/include；B25非HDL Git-read终结失败未增加时限或重试。结构核验不替代HDL合编。

- [累计manifest](snapshots/source_20261105_b29.json)，SHA `260620629b9b73fb890dd379114f47556d7d788b494487e9d959a8abbb42b9f2`
- [结构核验](snapshots/source_20261105_b29_structure.json)，SHA `8caa1b8840b11378ff981ca10182cdd7515ac66b2e11605787a46b9ad5358199`
- [checker NOT_RUN](snapshots/source_20261105_b29_check.json)，SHA `19cada11fa63f1a49560684536bdb2b094dde7abe60f5964ef416596264ee03a`

release直接继承freeze，只提交本页、README入口及两份状态JSON，冻结资产不改。
原15项tracked改动、binary diff、goal.txt、21000非忽略untracked双hash与56旧refs保持。
本地快照不承诺比赛规则适用性，无push，Goal继续active。
