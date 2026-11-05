# 2026-11-05 第二十七批与累计108包源码快照

基线 `548ecff2b34281ec7b6f3306ba1c8d3af07f246d`，开发分支
`development/ip-assets-20261104`。本地稳定分支 `stable/source-20261105-b27`，
附注标签 `snapshot/source-20261105-b27`。原52个稳定引用不变，无push，Goal继续active。

|新增功能包|独立能力|当前有限证据|
|---|---|---|
|[descriptor_drr_scheduler](../cores/system/descriptor_drr_scheduler/README.md)|多描述符队列、按费用扣减及跨访问保留信用的DRR服务|5配置、7仿真；1865命令响应、1685退休描述符、19复位；两段512退休公平性窗口|
|[gf2_squarefree_decomposition](../cores/signal_processing/gf2_squarefree_decomposition/README.md)|任意固定阶monic GF(2)多项式的全部平方自由重数组|4配置、12仿真；180主回放、58完整fresh、319退休因子与330精确延迟核对|
|[gif_lzw_decoder](../cores/image_processing/gif_lzw_decoder/README.md)|从实际GIF最小码长/子块字节解码真实8bit索引|3配置、9仿真；76主包、24复位完整恢复；29146主索引、9836取消前缀及96fresh索引|
|[dag_transitive_reduction](../cores/acceleration/dag_transitive_reduction/README.md)|保留DAG全部可达性且每条剩余边均必要的唯一传递约简|5配置、15仿真；182主图回放、77完整fresh、3329退休行|

本批17组固定参数，93条有效资格记录（A24/B21/C20/root28），含43次仿真与24项具名
参数拒绝。每个compiler/simulator进程树硬限20秒，最长7.829秒；有效回执无TIMEOUT或
NOT_RUN。四包均有LINT_PASS、有限UNIT_SIM_PASS，全部HW_UNVERIFIED。示例属于有限
编译/实例化检查；没有综合、PnR、STA、上板、功耗或继承/扩展数值回归。

## 接口、复用和结构边界

四核均单时钟、同步高有效reset和普通ready/valid，无CE/CDC。复位取消当前owner；
输入间隔与输出背压无界时，不保证无条件完成时限。各包files.f与全端口示例离线闭合。

DRR命令在接受边沿提交，response报告该边沿之前的count/quantum/deficit。满队列即使
同沿pop仍拒绝入队；配置仅空队列生效；最后一次pop同沿接受替代描述符时保持连续
非空访问。run_enable只暂停调度，已持有输出仍可退休。一个同步1W1R RAM存储完整
描述符，默认1664/最大57344 logical bits；COST_W+1信用范围有明确证明。公平性仅限
固定quantum和持续非空的费用服务；32份证书与两个512退休窗口不构成通用时延保证。

GF(2)核真实计算全部非单位平方自由F_e，满足P=product(F_e^e)、组间互素及加权次数D。
输出按(v2(e),oddpart(e))排序。共享GCD/精确商XOR引擎，显式pending Z在C/Y完成后才
公开，last基于已经提交的W/C。D1..64、重数64可表示；无RAM/整数乘除/DSP。主参考为
完整确定性Berlekamp分解及原P重复整除，另与特征2分解、小阶全monic因子枚举交叉。
标量声明157默认/567最大bit；纸面计算上界1763/22833拍，不含任意输出等待。

GIF核处理CLEAR、EOI、KwKwK、3..12bit增长与4096冻结字典；CLEAR不丢剩余位，EOI
之后仍解析子块到带s_last的零终止块。输出没有m_last；独立摘要给错误、退休计数和
first tag，接收方仅在成功摘要且像素数符合预期时提交图像。错误可能已有退休前缀。
计数溢出停止进一步输出并drain，计数不回绕。4096×20字典与4096×8逆序栈共114688
logical RAM bits，同步单口、payload/read-q不复位；最长4091字只作纸面容量证明。
三份独立手算LSB位宽边界/完整fresh证书随包保存，未宣称实测最大栈深。

DAG核实际实例化成熟directed_reachability后端，原RTL SHA
`f2d80d7a1e72f0048a028449c8156f20353468465c1ea1ecdd2a5b84b2a198cf`
不变，旧后端数值矩阵未运行。完整32bit端点先检查，赋值/删除last-wins，非法端点优先
拒绝，其次最终环/自环；错误仅一条keep0/last1零数值摘要。DAG全部约简完成后才回放N
行、行度数和全局计数，独立逐边删除BFS验证闭包与保留边必要性。含后端RAM声明
1664默认/22656最大bit，标量487/1487bit；首valid保守界7N²+12N+8。

上述均为源级声明、数学周期界和定性风险，不是映射资源、Fmax、功耗或板级证据。
默认/最大结构风险见各包README/COST成本说明；外部来源和完整许可证见SOURCES及LICENSE文件。

## 原始失败与限定修复

DRR原attempt01在ragged_main停止：3PASS/1FAIL/20NOT_RUN。TB在最后pop后又等一拍才
暂停，空队列cursor从1多走到2，事件参考仍停在1。原52文件加manifest的53项完整
归档永久保留。明确修复仅去掉TB run_enable action的这一个额外negedge，RTL、oracle、
夹具和数值条件不变。

attempt02前三仿真（含ragged的512退休窗口）通过，随后default_compile把后置-s当
文件名而停止：5PASS/1FAIL/18NOT_RUN。该次完整源码、12raw streams及2vvp另行归档。
第二项明确修复仅把同一-s descriptor_drr4移到首源文件之前，模块、参数、源文件集合、
其余23条argv与TEST_PLAN原字节保持；新独立seal及attempt03回执承载有效24项结果。
两次原失败合计10条已执行记录、38NOT_RUN独立保留，不并入有效PASS。没有自动重试、
更换刺激、放宽判据、重新准备或重跑oracle。执行前timeout/原始日志属性修订及未执行
seal原字节均有命名历史。

其余三包唯一固定矩阵一次通过。A→root、B→A、C→B、root→C均为实际raw日志、具体
复位谓词、工具/源字节与精确库存的环审。成功临时vvp在核hash后逐项删除；DRR原失败
vvp是Icarus文本汇编，按精确路径保留原字节。C被全库evidence忽略规则覆盖的107份
文本记录/源码副本由root明确枚举后加入，逐index rawSHA核对，没有加入成功临时产物。

## 累计封存与总库检查边界

累计108包，107份有限UNIT证据和1份继承LINT-only。B26原104个package对象、8074包
文件与12 support逐对象继承，8086路径mode/type/OID不变。新增634包文件，
累计8708包文件+12 support=8720冻结路径；新增路径均以工作区原始SHA256、
stage后index blob原字节及feature commit OID交叉核对。没有重读B25整批blob或重试旧checker。

|通道|Feature commit|文件数|
|---|---|---:|
|root|`abe90b2d21969e378e18ad684ee106c0d6563629`|89|
|c|`8f21cd44238eea7b86f37b2fc63614d8672d16bb`|175|
|b|`8ef3bc977868f6a550f6d8a7fd36595fbf8e0b22`|78|
|a|`cc369d9d8327eb718d60be8b3f299a52386ecd31`|292|

freeze `f9ea88c904eefefc1f1756e70071efa7622234c9` 只增加累计manifest。源码结构检查闭合
224个显式源、217个top与226个module declaration，
未见名称冲突；该审查不是HDL合编。

**总库checker及隔离合编NOT_RUN，实际启动0次。** 原checker不支持本批独立seal、路径raw
日志及C的children/source-copy schema，且继承投影/include仍不兼容；保持原脚本不变。
B25非HDL Git-read终结TIMEOUT及当时编译未启动的记录原样保留，没有增加时限或重试。

- [累计manifest](snapshots/source_20261105_b27.json)，SHA `b7ae1b0c6f05223a3949abe8d1ef6aea502e511d99d7d7b13ea70d2f5eddf094`
- [结构核验](snapshots/source_20261105_b27_structure.json)，SHA `5a77e34115cf05614ce6a371a5afe59da454c60c9eae09f6d1d3c11c4a9dda46`
- [checker NOT_RUN](snapshots/source_20261105_b27_check.json)，SHA `8ceb2ae36b9373b46fc326f8a0a6d36a7140500715bbec1ed10137c43f3d2321`

release直接继承freeze，只提交本页、README入口和两份状态JSON；所有冻结路径不改。
原15项tracked改动、binary diff、goal.txt、21000非忽略untracked双hash与52旧refs受保护。
无push，Goal继续active。
