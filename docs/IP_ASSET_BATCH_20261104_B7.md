# 2026-11-04 第七批与累计二十八项源码快照

本批开发基线为 `f19addd5fec59ec6affee05af7195ca1758d40dc`，继续使用
`development/ip-assets-20261104`。稳定分支 `stable/source-20261104-b7`
和固定标签 `snapshot/source-20261104-b7` 绑定累计二十八项。前六批十二个
稳定引用保留原提交；B7清单的直接前批明确为B6。

| 功能包 | 独立能力与复用价值 | 功能提交 | 实际有限证据 |
| --- | --- | --- | --- |
| [ram_hash_table](../cores/storage/ram_hash_table/README.md) | 同步RAM持久键值GET/PUT/DELETE/CLEAR，完整线性探测、墓碑删除和满表替换 | `cb800e5` | 5配置7067条记录、7037响应、7067独立dict快照及545814次物理槽观察；singleton全部729种三命令序列；每配置7个即时阶段复位探针 |
| [block_vector_normalize](../cores/signal_processing/block_vector_normalize/README.md) | 可变长有符号L2归一化，复用旧迭代sqrt/divider，明确两步RNE及解析误差界 | `f11ab12` | 8配置455帧、3292输入/2164输出，含84个signed2长度1..3向量；336正常/16空/29零范数/74超容帧；96次阶段取消、2000个实际输入停顿周期 |
| [segment_box_clip](../cores/image_processing/segment_box_clip/README.md) | 有向线段与闭ROI矩形相交，精确有理端点，保留点接触和零面积矩形 | `db088ce` | 5配置5776线段；完整signed2平面全部256条有向线段×5种ROI、signed3全部4096条×1种ROI；独立Fraction几何边交点oracle；45次阶段取消 |
| [dijkstra_sssp](../cores/acceleration/dijkstra_sssp/README.md) | 非负有向图的精确源距离/可达性/前驱树，支持零权及平行边 | `966acae` | 7配置1044图、7787顶点结果、906次独立全对参考交叉；全部729个三节点off-diagonal absent/0/1矩阵各一个source；最大64节点/24位权实际仿真；77次阶段取消 |

本批25组实际仿真配置，90条工具记录，含27项预期非法参数拒绝，四包分别
9/8/4/6项。每工具子进程限时15或20秒。所有包有实际可综合RTL、完整依赖
清单和最小例、接口/数值/错误/复位/反压契约、独立有限测试、当前源hash、
只读语义去重与实际外源源码/许可证预检。临时向量和模拟器产物已清理。

## 主要调用边界与风险

- 哈希表SLOTS只支持1..256的二次幂，key/value为1..64位原始bit向量。PUT在
  首墓碑后继续找已有key，满表仍可替换；只有absent且全部LIVE才FULL，不驱逐
  其他绑定。响应给旧值与操作后精确count。状态在独立命令间保留于易失RAM，
  复位/CLEAR丢弃绑定，metadata逐槽清除，payload不并行复位。墓碑会延长miss
  延迟，无恒定时间、安全哈希或非易失保证。默认2048bit payload+64bit metadata，
  最大32768+512bit，风险LOW/MEDIUM。
- 归一化保留组件顺序、掩码/first-tag/帧尾，精确能量S=sum(x²)。输出按
  r=RNE(sqrt(S)*2^(F+2))、q=RNE(x*2^(2F+2)/r)计算；精确契约对应两步RNE，
  不宣称与直接理想RNE逐bit相同。相对理想单位向量的每分量误差≤9/14输出LSB，
  范数误差≤sqrt(K)*9/(14*2^F)，低精度结果不一定恰为单位范数。空帧发一个
  masked状态token，零范数发K个零，超容整帧拒绝并不发布prefix能量。默认/
  最大组件RAM为256/1536bit，共享旧sqrt/divider与一个采样平方乘法器，风险
  LOW/MEDIUM；未将旧库历史物理证据用于新组合。
- 裁剪输入八个坐标/ROI原子捕获，闭边界及点/线ROI合法，倒置矩形单独报错。
  不可见或错误返回canonical零分子/分母1；可见端点是未必约分的精确有理数，
  无像素舍入或定点近似。一个MW=W+2迭代shift/add乘法器共享交叉乘比较与
  端点计算，无数组/除法/外部依赖。默认/最大MW14/26，valid延迟≤26MW+40
  周期，即404/716；输出停顿另计。风险LOW/MEDIUM。静态ROI例仅编译，未
  虚构实际视频或光栅组合。
- 最短路输入边有32位端点，平行边取min、零权用present位保留。非法included
  edge忽略并置bit0，仍求有效边图；首source非法置bit1，整图返回不可达/零距。
  每图固定输出N个升序顶点，source与不可达无parent；严格改善及升序settle
  确定树，但不承诺词典序最小路径。parent指向已settled节点，以settlement
  rank保证零权情况下仍无环。无负权、动态更新或路径token重构。同步edge/node
  RAM默认4784bit、最大104896bit，单节点/邻居扫描，风险LOW/MEDIUM。最大
  63边全最大权链距离1056964545已实际验证，无数值截断/饱和。

四核心都是单时钟、同步高有效复位、无CE，需明确适配旧CE-qualified接口。
复位覆盖当前工作和held结果；源/汇需按各包契约重放或丢弃取消的事务。状态为
**LINT_PASS + UNIT_SIM_PASS + HW_UNVERIFIED**，组合/最小例为
**INTEGRATION_CANDIDATE**。例子证据是语法编译；归一化的实际有限核心仿真
还包含所实例化的旧算术模块。没有综合、布局布线、STA、上板或扩大回归，也
没有实测利用率、频率、功耗或器件适配结果。

## 独立审阅与证据范围

A审最短路、B审哈希表、C审归一化、root审精确裁剪，最终冻结版均无实质问题。
审阅覆盖存储所有权、位宽/符号、墓碑和满容量、零权树无环、两步舍入误差、
有理边界、held字段及阶段立即复位。所有阶段探针在观察到目标边界后立即
reset_now，没有额外active edge；这不构成任意周期复位证明。

归一化首轮driver留空拍，未真正产生输入停顿；已改为零gap立即offer，原八组
有限检查重跑后实际记录2000个source-stall周期，生产RTL未改。最短路追加了
行为延迟断言后原七组重跑：R取独立golden的可达数，tail类型来自输入，断言
不读取DUT visited/state推断期望周期。所有当前hash对应最终通过字节。

最短路参考用同步Bellman-Ford，小N再用独立all-pairs min-plus。前驱通过边与
距离证书、到source无环检查、手写tie结果及35次同图重排/重复回放核对，不另
写同构Dijkstra期望parent。裁剪参考收集几何边交点，不镜像半平面区间更新。
归一化参考用isqrt/平方midpoint/divmod，并以平方有理区间独立检验误差界。
哈希表用独立dict并逐记录观察物理LIVE集合、值、重复绑定和精确占用。

外源均只读，不复制实现或运行下载程序。固定版本、实际文件hash和许可决策
见各包SOURCES.md：ARP cache参考MIT，LAPACK及NetworkX参考BSD-3，
Boost.Geometry参考BSL-1.0。所有新RTL/测试/文档和复用本地算术按根
LICENSE/NOTICE记录，不依赖外部构建系统或在线源码获取。

## 累计冻结与离线恢复

[B7清单](snapshots/source_20261104_b7.json)绑定 **256个包内文本文件和10个
共享支持文件**。仅增加旧recip_div.sv作为共享依赖；旧sqrt已经在此前闭包，
两者字节与B6基线一致，未复制或改写。根LICENSE/NOTICE、旧backend说明与
许可记录继续导出。清单只覆盖本轮持续开发中审查的二十八项，不是整个历史
仓库或所有参数的重新验收。

最终冻结检查在 `9a98d1d000621c14c2636191de4163701dc5463d` 通过：**28个内核+
29个示例，共57个top、63个唯一生产源文件**，在仅含清单提交字节的隔离
目录中一次Icarus `-tnull` 编译成功。检查文件hash、源/依赖证据绑定、实际有限
记录、路径闭包与module重名；不重跑全部数值仿真或扩大证明范围。原始输出
直接写入[冻结记录](snapshots/source_20261104_b7_check.txt)。

成功编译仍有20条timescale继承警告，包括新复用divider文件中的两个模块；
均来自无数值延时的生产源码，没有其他编译诊断或错误。警告保留原文，不以
消除警告为由改写既有资产。前六批证据和固定引用均不改变。

```text
python -B scripts/check_source_snapshot.py --ref snapshot/source-20261104-b7 --manifest docs/snapshots/source_20261104_b7.json --compile
```

后续发布提交只补本记录、实际检查输出和README入口，冻结源码/清单/检查器
不再变化。root仅暂存本任务的精确路径并串行提交，无push；原有未提交修改、
删除及其他未跟踪资产保留。Goal继续active，此处为持续开发进展检查点。

前批：[第一批](IP_ASSET_BATCH_20261104.md)、[第二批](IP_ASSET_BATCH_20261104_B2.md)、
[第三批](IP_ASSET_BATCH_20261104_B3.md)、[第四批](IP_ASSET_BATCH_20261104_B4.md)、
[第五批](IP_ASSET_BATCH_20261104_B5.md)、[第六批](IP_ASSET_BATCH_20261104_B6.md)。
