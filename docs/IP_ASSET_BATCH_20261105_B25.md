# 2026-11-05 第二十五批与累计一百包源码快照

本批基线 `d35d71be3bfc76f272809ae250d19cba92dbb18c`，开发分支
`development/ip-assets-20261104`。本地稳定分支为 `stable/source-20261105-b25`，
附注标签为 `snapshot/source-20261105-b25`。此前48个稳定引用保持原样；无push，Goal继续active。

| 功能包 | 新增能力 | 当前有限证据 |
|---|---|---|
|[ram_interval_set](../cores/storage/ram_interval_set/README.md)|持久精确byte集合的并、差、覆盖计量与规范区间枚举|6配置，13268主命令、258取消owner、5246完整fresh命令|
|[exact_integer_charpoly](../cores/signal_processing/exact_integer_charpoly/README.md)|任意运行时signed整数方阵的完整精确特征多项式|6配置，168主帧、290立即取消与完整fresh，2160完成系数/错误响应|
|[qoi_encoder](../cores/image_processing/qoi_encoder/README.md)|RGB/RGBA光栅到六类chunk的标准完整QOI文件编码|8配置，470主帧、210立即取消与完整fresh，680742完成文件byte|
|[directed_minimum_arborescence](../cores/acceleration/directed_minimum_arborescence/README.md)|带原始边序号见证的指定根最小费用有向生成树|5配置，884主帧、250立即取消与完整fresh，496合法最优树见证|

本批25组有限参数配置，1105条当前合格工具记录（A268/B369/C167/root301），
含971个仿真子进程、28项具名预期参数拒绝。另实际执行原失败记录314条（B6+303/C5），
故包内矩阵共1419次实际工具执行；原591项NOT_RUN不算执行。当前最长child为C的
2.032秒，所有compiler/simulator child均硬限20秒，没有TIMEOUT。四包均有有限UNIT证据，
全部HW_UNVERIFIED。示例只有语法/实例化证据；没有综合、PnR、STA、上板、继承数值重跑或扩展回归。

唯一合并隔离检查在非HDL的Git读取阶段超时，Icarus尚未启动，因此本批合并隔离编译
为 **NOT_RUN**。原始失败完整保存，没有重试或增加时限；不把单包UNIT证据写成全库合编通过。

## 接口、数值及结构边界

区间集合保留半开byte集合，ADD合并相接分量，REMOVE可拆分分量，COVER精确计量，
ENUM给出唯一升序最大分量。请求完整unsigned64 base与unsigned65 bytes先以66bit求和
校验，再窄化到A位地址；A64下整个2^64-byte域和最后一byte均合法。候选在另一RAM bank
完整构造后才原子发布，容量不足保留原集合；reset丢弃整个集合。一个同步packed单口RAM
服务两个逻辑bank，没有payload reset或组合全表比较。原矩阵共19642完成命令（含1128
setup及5246fresh）、24616退休记录（含取消owner的12条前缀）、19025真实下一命令接受、
19708首valid检查和156722行核验。取消owner的完整数学输出不能计作完成。

特征多项式按迭代Berkowitz处理尾部主子矩阵，用A、两个V、G、两个Q共六个同步单口bank，
复用一个WORK_W×COEFF_W shift/add算子及宽加法器。完整产品、每个累加前缀和sign恢复
均由合法域界覆盖，只有完成的系数才窄化；没有数据除法、浮点或饱和。默认WORK/COEFF
为41/34bit，最大118/105bit。独立主子式排列展开、Fraction Newton恒等式、完整
Cayley-Hamilton及尾部多项式证书不复制DUT控制。当前458完成帧、105真实queued、
12实际next offers、870 reset-high offers、528首valid检查、262705 bank、102720 dot和
2472392逐bit乘法检查闭合。取消owner退休前缀38条另计。N8主job逐帧，不宣称内部queued。
错误帧只写已接受的kept输入，不进入求解；全masked SHORT的bank/dot/mul严格为零。

QOI首拍锁存tag/colorspace，固定收满W×H后验证SOF/EOL/upstream错误。错误帧不泄露任何
文件前缀，只发零byte摘要。好帧产生14-byte header、canonical payload、8-byte footer，
最后文件byte退休后才发held摘要。一个raw帧RAM及64×32 history RAM均同步单口、无reset；
编码前串行清history。六类chunk优先级、signed8模差分、低6bit hash及RUN62边界与独立
canonical/decode证书一致。680精确tail、445真实queued、210原始reset OBS、331793 capture
writes、206194 raw reads、135487 history reads、184719 history writes均从原stdout闭合。
完成文件680742byte；取消owner已退休前缀2585byte不能当作完整文件。生产闭包不导入旧decoder，
没有宣称64×64域与旧16×16 decoder完成集成。

有向树核保留parallel/self边的原ordinal，完整unsigned32 root/endpoints先验证再窄化。
串行Chu-Liu/Edmonds选择入边、收缩前驱环，两个同步packed历史RAM支持反向展开；
最终按child升序输出原始parent/ordinal/cost，再发summary。只保证任一最优见证，
不保证全局字典序最小。自环占容量但不入树，不可行正常；N1空树可行。独立穷举原始
parent选择与返回见证的根连通、无环、费用逐项检查闭合。实际1134完整结果、848真实
queued、496合法树证书/2325原边、250取消、600次收缩；最大实际层5、首valid2763拍。
取消owner的43条已退休前缀须由接收方丢弃，不能计作完成树。

| 源级声明预算 | 默认/最大RAM bit | 默认/最大scalar bit | 无反压调度及风险 |
|---|---:|---:|---|
|interval set|2080/16512|530/912|首响应界6N+16；LOW/MEDIUM|
|charpoly|1001/5608|399/1109|默认/最大完整退休1462/28482拍；LOW/MEDIUM|
|QOI encoder|4096/133120|193/232|尾界112+(CHANNELS+7)N，默认816/最大45168拍；LOW/MEDIUM|
|directed arborescence|3904/13824|123/178|保守尾界默认5952/最大16960拍；LOW/MEDIUM|

charpoly冻结最大计算配置TAG_W8为1085 scalar bit；1109是合法TAG_W32参数包络，
不把T8配置说成全参数笛卡尔覆盖。这些都是声明/纸面周期预算和定性风险，并非LUT、
FF、BRAM、DSP、Fmax或功耗实测。四核都是单时钟、同步高有效reset、普通ready/valid，
没有CE/CDC；无界外部停顿不保证无条件完成。生产files.f与实例化闭包无需网络或Python。
完整固定来源、许可证、安装版SymPy的远程核验边界及语义去重见各SOURCES。

## 原始失败与精确修复

root测试台的真实queued首token和next-offer reset目标在首source seal、首HDL前经A环审
修正；冻结刺激与301命令未改，没有对应的工具失败或PASS后改源。

B首个未执行seal因C原诊断揭示的同类二维fscanf风险，在任何child前只改标量扫描目标并
重新封存。实际attempt01第6child于Time0因末尾检查失败：5 PASS、363 NOT_RUN；
724文件原档保留全部源码、seal、receipt与p0.vvp。353个TXT按原语法恰好消费；末尾
fscanf具体返回码未记录，未把推测写成实测。root精确批准TB只改ASCII空白到EOF扫描、
runner守卫与沿革。attempt02第303child的vvp exit0且PASS，但runner对全masked SHORT
误要求bank>0：原302 PASS、1 OBSERVED、66 NOT_RUN及730文件档全部保留。
root随后只批准all-error main的精确capture-bank计数与dot/mul=0，其他数值、marker、
latency和正bank条件不变；明确批准后的attempt03全369通过。原DUT及冻结刺激从未修改。
B七个原始.vvp均是含CR的Icarus文本汇编；包内既有精确artifact属性为-text，stage时
只对白名单七路径显式纳入，并逐index blob raw SHA256核对，没有改写归档字节。

C原第5child在metadata扫描时遭Icarus二维fscanf目的地错误：原4 PASS、162 NOT_RUN，
175文件原档与原verification.json的FAIL永久保留。root只批准两个扫描循环使用已有
标量k、runner守卫和沿革，原DUT、162冻结源与167命令不变。修复证据及root审查记录
在包内形成离线闭包，唯一attempt02全167通过。有效证据是独立的
`verification_attempt02.json`；原FAIL没有覆盖或改标。两包所有修复均在新精确seal
经root只读复核后才执行，TIMEOUT没有重试入口。

四向只读环审A→root、B→A、C→B、root→C均CLOSED PASS。发布不重跑任何数值矩阵，
不修改已PASS实现、测试、原失败或冻结刺激。

## 累计封存与本地发布

累计100包为99份有限UNIT证据加1份继承LINT-only候选。B24原96个package对象、2109
包文件、12份support和依赖映射逐对象保持；本批新增3639包文件，合计5748包文件+
12 support=5760冻结文件。历史终止TIMEOUT及compile-only边界保持。

| 通道 | Feature commit | 文件数 |
|---|---|---:|
|root|`fd7789205153c6e4511a77014bd07fc2199b7343`|586|
|a|`93d00ae334354057d324a4fded9e074160a83a20`|522|
|c|`7a9a3f22e477ee544ee298b5ab9b5734191d1cb3`|353|
|b|`48ed3a3e3c2a3a1b6345c6532ce969b641e69838`|2178|

每次只stage精确包路径，完整核对index blob raw SHA256后提交并恢复空index。
源码freeze提交 `4f0e990889351f15b82d94e8de4140b536fa9657` 只增加累计manifest，既有checker未改。
唯一隔离检查为：

```text
python -B scripts/check_source_snapshot.py --ref 4f0e990889351f15b82d94e8de4140b536fa9657 --manifest docs/snapshots/source_20261105_b25.json --compile
```

实际退出1，总计30.266秒，stdout为空。错误发生在checker第108行
`git cat-file --batch` 的15秒读取时限，早于任何package检查输出和Icarus启动。
完整argv、退出码、时间、原stderr traceback和空stdout保存在
`source_20261105_b25_check.json`，原始空stdout另保存为对应check.txt。
此次是非HDL Git读取TIMEOUT；没有改变checker、增加时限、重试、拆分或替换本轮检查。

因此201个top、208个生产文件只是当前清单的静态闭包数量，**未取得本批合并隔离编译证据**，
也没有本批诊断与B24相等的结论。全部5760 committed raw SHA、原2121路径mode/type/OID、
四feature精确新增范围与原96对象继承已由B独立只读核验；该离线结构核验通过不替代HDL编译。
四包各自的当前语法、数值矩阵及成熟度不受这一未启动编译影响；不继承旧合编结果给新包。

- 累计manifest SHA256：`0c6814d3b35ec46b6334155993fc0bfe05d2490b228fe01aa8cb2b220e0799a5`
- 原始check log SHA256：`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- 完整失败记录SHA256：`4234a856db83b994edd360b5dc7f270d233ee2fa62a91fef850f3d9586449b01`
- A seal / receipt：`6267ecbef5da10d1971f2c210c51d6ed380a26241cf9104d3c68dce21d3ec833` / `78c2df1eff4ba7938354edf3a639528bf62c604f185aef09a4489a8e219b5d0c`
- B seal / receipt：`1d3b3cc5e68cf9b7c1e9c45c13df07aae430b5c0f232b89a2e9d8e56da210be0` / `a12af6c53c7773de639992e723f16e2995d399cc2221fd49cd691191ff052105`
- C repair seal / attempt02：`c612358096895861e632c721bf1977b20d400882817f8af437a60fd5401a3335` / `9c2f5b3b73fd9c0424fd7a6b36a1a4cb4a7ae557bddcc39e7642ad4858151ae7`
- Root seal / receipt：`dc23b1162b2ca4dcde01237026a45ce37e25f322a69edb6ba4d4b86607140c73` / `e1652029e8323f4f1b88597b01504457649e5c75bf7b8d08850e1dc3e87af0a1`

release直接继承freeze，只增加本页、README入口、原始空check log和完整失败JSON。新stable分支及附注tag
指向release；旧48refs raw/type/peeled及原5760闭包OID保持。原15项tracked改动、binary
diff、goal.txt和21000非忽略untracked的NUL/LF双hash受保护；无push，Goal继续active。
