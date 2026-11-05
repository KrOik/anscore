# 2026-11-05 第二十六批与累计104包源码快照

本批基线 `da85338f8a22c454cce77f5b88dd7a803975deb6`，开发分支
`development/ip-assets-20261104`。本地稳定分支为 `stable/source-20261105-b26`，
附注标签为 `snapshot/source-20261105-b26`。旧50个稳定引用保持原样；无push，Goal继续active。

| 功能包 | 独立新增能力 | 当前有限证据 |
|---|---|---|
|[ram_ternary_rule_table](../cores/storage/ram_ternary_rule_table/README.md)|任意care mask规则、全匹配bitmap/count及最低slot动作|6配置、175次仿真、17675完成命令、205次复位、361897次live-row核验|
|[gf2_polynomial_irreducibility](../cores/signal_processing/gf2_polynomial_irreducibility/README.md)|GF(2)多项式精确不可约判定及失败checkpoint/delta/GCD见证|8配置、24次仿真、924次主输入回放及155次fresh结果|
|[binary_hu_moments](../cores/image_processing/binary_hu_moments/README.md)|实际二值光栅的全部七个精确有理Hu量|6配置、290次仿真、192主帧、218次复位后完整fresh、2330个完成输出|
|[cnf_sat_solver](../cores/acceleration/cnf_sat_solver/README.md)|一般signed CNF的精确SAT/UNSAT及完整满足赋值|5配置、10次仿真、234主公式、70次复位后完整fresh及真实下一事务|

本批25组有限参数配置，563条当前合格child记录（A191/B37/C306/root29），含499个仿真
子进程与24项具名预期参数拒绝。所有compiler/simulator child硬限20秒，当前最长0.985秒，
没有TIMEOUT或当前NOT_RUN。四包均有LINT_PASS与有限UNIT_SIM_PASS证据，全部HW_UNVERIFIED。
示例仅有语法/实例化检查；没有综合、PnR、STA、上板、继承数值矩阵或扩展回归。

## 接口、算法和资源边界

规则表提供QUERY/SET/DELETE/GET/CLEAR/STATUS；任意非连续care合法，value以value&care
规范化。相关slot以完整unsigned32校验后才窄化。一个同步packed单口RAM逐slot读取，
payload/read-q无reset；复位清live元数据并取消事务。全匹配bitmap/count和最低slot动作
属于同一查询结果，未将普通最长前缀表换名计数。

不可约核以monic最高项隐含的低D系数作为实际输入，D1下x与x+1都不可约。Rabin所需
checkpoint与最终Frobenius条件完整执行；GCD失败见证允许等于整个P。一个bit-serial
模平方和仅余数XOR欧几里得引擎完成计算，没有RAM或整数乘除器。独立squarefree+
Berlekamp主证书、完整平方/长除Rabin交叉证书与小阶因子枚举在封存前形成固定夹具。
当前实际1079条REC=924主回放+155fresh，155条PROBE，465次reset-high offer、8次真实
next offer与1095次首valid检查均从raw日志闭合。

Hu核接收完整WIDTH×HEIGHT二值光栅和SOF/EOL/error/tag，累积十个三阶以内raw moment。
Q=m·mu2、T=m²·mu3整数化后，用固定79指令DAG输出七个有符号分子/正分母；不做
浮点、开方、除法、约分、容差或log变换。空帧及marker错误完整drain后只发一条错误摘要。
45次乘法共享signed shift/add算子，32-word同步单口scratch无payload reset。
独立逐坐标Fraction中心化证书经交叉乘积核对所有输出，并单独检查规定分母。
当前410完成帧、2330输出、126条取消owner已退休prefix、120次queued、470次延迟检查
分别记账；取消prefix不能视作完整descriptor。面积、tag和错误元数据同响应保持。

SAT核串行unit propagation与chronological DPLL，先处理重言式再判断unit，使用两个同步
RAM保存clause和完整pending assigned/value快照。每次decision划分false/true两子树，
耗尽返回真实UNSAT；SAT补齐未赋变量为零。运行时变量/子句数、零变量/零子句及完整
unsigned32计数先校验，非法行按明确错误语义响应。234主公式包含108 SAT/58 UNSAT/
68错误，主测试实际1489行、10521次clause read、184 push/57 pop；五配置实测首valid
最大8/39/145/549/8349拍，pending深度最大0/1/3/7/15。每次reset后先完整装载新公式，
再发真实empty-CNF下一事务；不沿用被取消owner的结果。

| 源级声明预算 | 默认/最大RAM bit | 默认/最大scalar bit | 调度与定性风险 |
|---|---:|---:|---|
|ternary rules|1280/20480|277/933|同步逐slot扫描；LOW/MEDIUM|
|GF(2) irreducibility|0/0|175/637|D(D+2)+omega(D)(3D+2)，全域纸面上界4806拍；LOW/MEDIUM|
|binary Hu|3744/6048|1325/2246|首valid=45·WORK_W+464，最大8969拍；宽carry及RAM粒度MEDIUM|
|CNF SAT|384/2560|117/220|保守尾界默认164039/最大292681551拍；结构LOW/MEDIUM，最大服务时间HIGH|

这些是声明数量、纸面周期界和定性判断，未经LUT/FF/BRAM/DSP/Fmax/功耗测量。SAT最坏
服务时间为指数级，当前8349拍只对应固定有限测试。Hu反射仅对真实未裁剪坐标变换保证
前六量保持/H7反号，不宣称任意离散重采样不变。四核均为单时钟、同步高有效reset、普通
ready/valid，无CE/CDC；外部输入间隔与背压无界时，不保证无条件完成。复位丢弃所有
owner，输出keep/last仅在valid下有效。生产files.f及实例化依赖可离线使用，固定来源和
许可证见各包SOURCES；未导入许可证不明源码。

## 原始失败、明确修复与包装投影

A原矩阵一次通过。root首次启动命中失效Chocolatey shim，真正Icarus没有启动；原1条
失败启动记录及28 NOT_RUN、33文件原档保留。明确修复仅指定OSS CAD Suite真实可执行
文件及bin/lib PATH，同29 argv、DUT/TB/oracle/fixtures/plan不变，独立attempt02全通过。
其后stage rawSHA守卫在提交前发现LICENSE/NOTICE的CRLF正规化；仅改两处.gitattributes
和runner的audit()，三份原测试字节保存在history。POSTQUAL_BINDING严格绑定原seal、
PASS receipt、三路径投影与当前71源映射，没有重跑HDL或修改原PASS回执。

B原第14child vvp exit0并产生两条正确REC和PASS摘要，但整段regex的$锚点不能处理
Windows CRLF残留CR，故原13 PASS/1 OBSERVED/23 NOT_RUN及78文件完整原档永久保留。
明确修复仅将REC/PROBE改为splitlines逐行fullmatch，所有数值、计数、marker、延迟
条件与37 argv保持。新seal执行前又修正两处回执source-map key，保留原SOURCE_FREEZE
与新REPAIR_SEAL各自hash；未执行旧修复seal/runner完整保存在history。新精确seal获
审后唯一attempt02全37通过，原失败没有覆盖。8份归档.vvp为Icarus文本汇编，原CR字节
保留；stage仅对这8个已审查路径显式纳入，逐index rawSHA核验。成功临时8文件在提交
后逐项核hash、unlink及空目录rmdir，未递归清理。

C原第4child example lint退出0但有继承timescale warning，严格stderr守卫停止；原
3 PASS/1 OBSERVED/302 NOT_RUN，没有任何原仿真，606项原档完整保留。只为example加
timescale并添加独立attempt02记账/守卫，原DUT/TB/oracle/580fixtures及306命令不变。
新seal逐hash审查后唯一attempt02全通过。首次HDL前修正的tree-kill runner及未执行
seal也保存在history；每child硬限20秒，首次失败停止，没有自动重试。

三包原始失败共19条执行/启动记录和353 NOT_RUN单独保留，不能并入当前PASS。
A→root、B→A、C→B、root→C实际证据环审均CLOSED PASS；root包装投影另经C闭合审查。
发布阶段只读证据，不重跑数值矩阵、不修改PASS实现或冻结刺激。

## 累计封存、结构核验与未运行的合并检查

累计104包为103份有限UNIT证据和1份继承LINT-only候选。B25原100个package对象、
5748包文件、12份support及依赖映射逐对象继承；新增2326包文件，合计8074包文件+
12 support=8086冻结路径。原100包5760路径mode/type/OID保持。新增2326路径由精确
stage逐index blob rawSHA验证，并独立以原始文件SHA256和Git blobOID对照当前提交。

| 通道 | Feature commit | 文件数 |
|---|---|---:|
|a|`8cbbb24444db9aee1520301740321f908a48958a`|749|
|root|`cdd6d99a59e48c62724eec4219d6454f298f7971`|132|
|c|`7a2022424cf4e213a05ce513e27e9b1ba933ec9d`|1216|
|b|`91af9dc0aa17b44f0656781ee9fc42ec6d2efd7b`|229|

freeze提交 `10b96b7c7fb5f1fe2af352952c9197c47e4df468` 只增加累计manifest。其静态闭包含216个显式编译源、
209个top、218个module declaration及1份Hu include，未发现名称冲突。源清单、include、
receipt/seal/plan和root包装投影形成明确依赖闭包。继承rawSHA的有效性来自B25已发布
证据与相同mode/type/OID的传递性，并未重读全部B25 blob或重试旧checker。

**本批总库checker及合并隔离编译为NOT_RUN，checker实际启动0次。** 既有checker
假定每份receipt具有source_sha256、stdout/stderr是内联文本，并不支持本批独立seal/
raw-log路径/包装投影schema和+incdir+指令。因此新manifest显式声明不兼容；没有修改
checker、伪造成功回执或把源码结构审核称为HDL合编通过。B25非HDL Git-read的终结
TIMEOUT和当时编译未启动的记录原样保留，没有增加时限、重试或替换该检查。

- [本批checker NOT_RUN记录](snapshots/source_20261105_b26_check.json)，SHA256 `f259fb66a3eebe833412e088c06648af875707fb4c36d4fe57cf8750226310d3`
- [独立源码结构核验](snapshots/source_20261105_b26_structure.json)，SHA256 `f759771c31931bde62c41e0a5191ae63db34627ccf62b0b032b94db0af743b66`
- [累计manifest](snapshots/source_20261105_b26.json)，SHA256 `6cbc8dcf9b3b7fbfad7bb3a4c3ccd567657873fefbac8e6a38c7f3f30d0ffc7e`
- A seal/receipt：`7d009371e019d0825845a558e00a3b7ca2594f323bba31ccfb852c71ebaf5a81` / `68ebcdb76756b6166fa9c8fec9401e18ff12459d68b57af973f816a68dba7b08`
- B repair seal/attempt02：`d2c64673ac1925bf5b96a433ef4f6d96299a0562a2675ec75d5ba3f77c6c9f7b` / `e7d3d7ce95ba42a10f98fd99c7fcb3eca5c0a2a6e320f7c68178893c7747bba3`
- C repair seal/attempt02：`5abb933d06b68e12268da9d9008bcf4b17425d5b9514905a5a030ed84743b904` / `ff83eadd82f540c44218950326206d9eea47f3498ba9769ef1835441cce01bd7`
- root repair seal/attempt02：`396964ad4580611224043d13ce31f996e3d62c25d4a560e9e141e605e4a6a561` / `3a9959ff869429a047c190e4d2f3788ccea9aec27885528f73ca62fc82936d70`
- root postqualification binding：`c4f46ec0fbb3c9e2f2dfd54f5e39f9daf27970d8ec4a87c48b0db361a836bbff`

release直接继承freeze，只提交本页、README入口与上述两份状态JSON；8086冻结路径不改。
新stable分支和附注tag指向release，旧50refs raw/type/peeled保持。原15项tracked改动、
binary diff、goal.txt及21000非忽略untracked的NUL/LF双hash受保护；无push，Goal继续active。
