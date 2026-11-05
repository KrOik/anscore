# 2026-11-05 第二十八批与累计112包源码快照

基线 `8f8e49a2cb9c3e48ecfaecb811f2d313058979b8`，开发分支
`development/ip-assets-20261104`。本地稳定分支 `stable/source-20261105-b28`，
附注标签 `snapshot/source-20261105-b28`。原54个稳定引用不变，无push，Goal继续active。

|新增功能包|独立能力|当前有限证据|
|---|---|---|
|[vector_banked_scratchpad](../cores/storage/vector_banked_scratchpad/README.md)|混合读写向量、全32bit预检查、多bank并行及同bank按lane重放|6配置、6仿真；1124接受向量、1106响应、18取消；330向量最终回读覆盖2344字|
|[exact_simplex_projection](../cores/signal_processing/exact_simplex_projection/README.md)|原序输出精确有理单纯形投影及公共分母|4配置、12仿真；100具名输入两次回放、4696主行；65复位与1505 fresh行|
|[general_weighted_matching](../cores/acceleration/general_weighted_matching/README.md)|允许奇环、未匹配点与有符号边权的一般图精确最大权匹配|5配置、8仿真；102主帧、494主行、1064输入token；20复位与136 fresh行|
|[grayscale_graph_segmentation](../cores/image_processing/grayscale_graph_segmentation/README.md)|稳定权序的四邻域整数FH分割、最小区域后处理及canonical标签|6配置、17仿真；44主案例两次回放、20394主行；43复位、2843 fresh行|

本批21组固定配置，104条有效资格记录（A25/B23/root23/C33），含43次仿真、28项具名
参数拒绝。实际执行114条记录，包含4条原始失败及6条因TB修改而被新编译取代的历史成功
编译记录；91个历史NOT_RUN槽位独立保留。
有效证据由具体receipt的成功片段组成，原始失败回执不会改写成PASS。各compiler/simulator
进程树硬限20秒，最长有效child为9.953秒。四次准备各执行一次，没有重跑。
四包当前均有LINT_PASS、有限UNIT_SIM_PASS，全部HW_UNVERIFIED。

包内README/COST/author状态保留执行前冻结原字节，其中NOT_RUN描述的是当时状态。
当前证据以本页、累计manifest的effective_segments及所列原始receipt为准；这些证据只覆盖
固定输入和具名参数，不能推成全参数证明或硬件签核。

## 调用与结构边界

四包具备RTL、files.f、全端口示例、参数和接口说明、固定TB/夹具、参考来源及许可证。
均为单时钟普通ready/valid，无CE/CDC；scratchpad为异步低有效复位，其余三核同步高有效。
输入暂停或输出背压无界时，没有无条件完成时间保证。

scratchpad先检查所有active lane完整32bit字地址，任一非法时整向量零物理访问；合法
混合读写按每bank最小pending lane发射，同地址遵守lane顺序。reset取消响应但保留已经
接受的写入，未写RAM内容明确unspecified。它复用原cip_sync_sp_ram原字节：
`cores/system/common_scaffold/memory/src/cip_sync_sp_ram.v` 与本地
`rtl/deps/cip_sync_sp_ram.v` 均2055字节，SHA
`04c0fe8416308c7e9a295d582dc7fee5fd8bbadf2fe4e745632543588c4f7619`。
两个路径独立存在。B27导出未含canonical RAM；B28将其原有已提交路径加入第13个support，
旧12个support及其hash全部保留。累计结构清单把A本地alias替换为canonical路径一次，
如实记录原始导出没有重复声明、仓库有一个精确副本。不把RAM副本计为新增能力。
各独立包files.f可照常使用。

simplex核支持N1..64、signed W2..24，质量为首输入携带的unsigned值。通过串行active-set
删除求精确分子和公共active-count分母，零质量返回全零/分母1。一个同步样本RAM、共享
signed乘法/加法，RAM256默认/1536最大logical bits；默认/最大始终ready保守界849/12609拍。
独立参考为descending-sort与Fraction KKT，固定输入才做小支持交叉检查。

一般图匹配支持N1..12、signed W1..32；完整端点预检查、last-wins赋值、零/负边不选。
子集DP以未匹配优先、partner升序固定同权选择，支持奇环；同步边RAM和分数/选择bank，
logical RAM默认6464/最大160400 bits。独立参考枚举互不相交边子集，不共用RTL递推。

灰度分割支持1..64宽高，通过两次生成图、256bin直方/前缀和稳定scatter，只保留一份
边RAM，权重相同时按source及right-before-down排序。精确交叉乘积避免有理阈值舍入，
共享一个乘法器；区域输出最小像素标签、面积及全局区域数。原DSU源码SHA
`a80d32edd4a02186e698ba62053ad2d9794b2a76c35cf8518dc3af46e67cc3ad`
不变，旧DSU数值矩阵未运行。payload RAM默认21984/最大406144 logical bits，独立参考
为显式component set与Fraction判据。最大配置只运行原定主案例，未扩展reset或参数矩阵。

以上存储及周期为源声明与数学预算；LOW/MEDIUM等架构风险见包内说明，不是实测
BRAM/DSP、面积、Fmax、功耗或硬件吞吐。未做综合、PnR、STA或上板。

## 原失败、限定修复与证据保留

root原attempt01前三项通过，第四项example lint返回0但有172字节继承timescale告警，
按严格空诊断判据失败，其余19项NOT_RUN。53份原文件完整归档。仅在example SPDX后
加入timescale；RTL、输入、参考与判据不变。独立批准attempt02只执行原children[3:]20项，
全部通过/按预期拒绝；前三项成功记录沿用，没有重跑。

C原attempt01前四项通过，首compile_p0触发Icarus内部string-case断言，28项NOT_RUN；
135份文件及60192字节partial VVP完整归档。仅将TB的11个string case分支改为等价if/else，
其余字节与所有判据不变。attempt02的六个profile compile全部通过，随后首vvp以
0xC0000135和空stdout/stderr退出，22项NOT_RUN；84份源/流/六个VVP及receipt另行归档。
本地静态PE依赖检查发现PATH缺suite/lib。独立seal与A/B/root静态复核后，attempt03
仅把bin+lib前置PATH，逐字节复用六个成功VVP，批准原children[10:]的23项。首main_p0_0
已能启动vvp，但在DUT输出前因四个二维数组$fscanf目标不可赋值而返回1，后22项NOT_RUN；
65源码副本、六VVP、两raw、LOCK和receipt共75项另行完整归档。没有DUT数值完成。
attempt03首稿在执行前因VPI额外DLL依赖未封印而被静态门退回；四份未执行稿保存在
history/attempt03_pre_vpi_closure，补齐8DLL守卫后重新冻结。它不增加实际失败或执行次数。

随后仅在TB read_case加入四个integer标量接收扫描结果，通过原返回值检查后赋回原数组
索引；格式、循环、判据、RTL和固定夹具均不变。attempt04经新seal和独立门后批准原
children[4:]29项：六个profile必须因TB修改重新编译，再运行原17仿真和6拒绝，全部通过。
原first4成功检查沿用；准备及oracle没有重跑。旧六个成功compile仅列superseded历史，
不冒充当前TB证据。实际17流含23237条REC、131个完整FRAME、43个PROBE、129个RESETEDGE、
5个NEXTHANDSHAKE和4条取消前缀ABORTREC。三次C失败、原始流及26份历史VVP保持原字节。

A准备后的LICENSE raw属性与audit语法收紧有命名metadata_history/pre_rebind历史，
原准备回执及数值payload保留，未重新准备。B准备前修订历史及原始计划按包记录保存。
root五份成功临时VVP由sealed runner核hash后删除，B随后核验记录与目录缺席；A/B/C成功
临时产物按实际hash审查与清理记录追溯。C三次失败的26份文本VVP/partial副本
永久保留，未当作成功临时产物清理。实际raw流、tested-copy、工具/源hash与复位谓词均已环审。

## 累计源码封存

累计112包，111份有限UNIT证据和1份继承LINT-only。B27原108个package对象、8708包文件
与12 support逐对象继承，8720路径mode/type/OID不变。新增1089包文件，
累计9797包文件+13 support=9810冻结路径。新增support为B27已经
提交且OID不变的canonical RAM。新增包路径已核工作区raw SHA256、
index原始blob字节与feature commit OID；不重读B25批量blob或重试原checker。

|通道|Feature commit|文件数|
|---|---|---:|
|a|`57c4bd3b7bf2879190362c82cfc1e9dbf3d22a89`|120|
|b|`86de386f3e3b0ff73495b03996a05946e3e912fe`|84|
|root|`093b2b69d21aae945aba99e436551d7afc682263`|152|
|c|`4c11e84bf910f1eba3df9af46d02abd49135ef97`|733|

freeze `ebcc10470fd2f4386f1c7cb3c02a8cd523776144` 只增加累计manifest。结构审查读取
233个显式源路径，替换一个精确RAM副本路径后为
233个源、225个top、235个module declaration；
无未解决名称冲突。这是元数据与源码结构检查，没有执行HDL合编。

结构metadata首轮在B的example/files.f相对路径解析处失败；静态审查另发现C有同类契约。
原脚本、输入hash与实际报错保留。独立审查后仅对B/C两份清单增加精确hash约束的目录基准，
其他186份仍按包根解析；限定修复后的第二轮结构核验通过。该过程没有启动HDL或数值工具，
也没有改变manifest、功能包或既有资格判据，单列于结构JSON的metadata_audit_history。

**总库checker及隔离合编NOT_RUN，实际启动0次。** 原脚本对本批多receipt证据和继承
投影/include不兼容，保持不变；B25非HDL Git-read终结TIMEOUT没有增加时限或重试。

- [累计manifest](snapshots/source_20261105_b28.json)，SHA `f43bd71e5e6ad99582e05c2b39ab6c46daf730739339386b7460a0db1d6e2858`
- [结构核验](snapshots/source_20261105_b28_structure.json)，SHA `ddace150ad0d598263ef29f0b37251562e92cc1d33ff5d72757ef7cdd45b3df2`
- [checker NOT_RUN](snapshots/source_20261105_b28_check.json)，SHA `38107bba701086781a50862b9a51fa4c5870759bb7256593ffb21f8b2abee344`

release直接继承freeze，只提交本页、README入口及两份状态JSON；所有冻结路径不改。
原15项tracked改动、binary diff、goal.txt、21000非忽略untracked双hash与54旧refs受保护。
本地快照不包含比赛规则适用性承诺，无push，Goal继续active。
