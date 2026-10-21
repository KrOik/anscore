# 外部设计参考与适用边界

访问日期：2026-10-16  
用途：记录迭代除法器结构和 Gowin 工具链公开案例，供当前 GW5A 分频器板级异常排查时参考。这里的资料用于提出可验证假设；它们没有定位或修复本项目故障。

## 迭代结构参考

**Project F：显式初始化周期的 restoring divider。** [`div.sv`](https://github.com/projf/projf-explore/blob/main/lib/maths/div.sv#L43-L114) 将操作拆成 `IDLE → INIT → CALC → DONE`：在 `IDLE` 接受并锁存操作数、绝对值及符号；下一拍 `INIT` 独立清零部分余数和商并设置迭代计数；之后逐位迭代，最后做符号修正。独立 `INIT` 周期避免依赖开始运算时各寄存器的旧值，适合作为控制时序的参考。其无符号整数版本 [`divu_int.sv`](https://github.com/projf/projf-explore/blob/main/lib/maths/divu_int.sv#L22-L64) 也输出余数。源文件使用 SystemVerilog，包含自身的位宽和接口约定，不能不经适配直接替换本仓库的 Verilog 模块。

**ZipCPU：移位除数的迭代实现。** [`div.v`](https://github.com/ZipCPU/zipcpu/blob/master/rtl/core/div.v#L280-L359) 展示了另一种成熟路线：预处理符号后，通过移位除数和逐轮比较/减法完成迭代。它可用于比较状态编码、移位方向、符号处理和边界情况；它与 Project F 的部分余数组织方式不同，也不是已验证适用于当前器件的实现。

对当前故障，优先在 B 操作被接受后、避开同一时钟沿非阻塞赋值造成的旧值观测，记录实际 remainder、divisor、移位后的 remainder 及首轮减法决策。显式 `LOAD/INIT/ITERATE/DONE` 值得作为候选结构评估，但只有取得这些板端观测并做 RTL/网表/板端对照后，才能判断它是否相关。

## 综合与器件案例：相关性有限

Yosys Gowin 综合流程的 [`synth_gowin` 选项处理](https://github.com/YosysHQ/yosys/blob/main/techlibs/gowin/synth_gowin.cc#L340-L349) 显示 `-noalu` 会跳过 Gowin `arith_map.v` 中的 ALU 映射；后续仍执行 [ABC9 LUT 映射](https://github.com/YosysHQ/yosys/blob/main/techlibs/gowin/synth_gowin.cc#L374-L386)。本机 v30 使用 `synth_gowin -noalu`，所以“默认 ALU 映射直接造成当前问题”并非现有配置下可直接成立的解释。此选项也不能排除其他综合、映射或物理实现因素。

| 公开记录 | 记录内容 | 与本次 GW5A 的边界 |
| --- | --- | --- |
| Apicula [#514](https://github.com/YosysHQ/apicula/issues/514) | Tang Nano 20K / GW2AR-18C 的 ALU 推断曾出现 RTL 与门级仿真通过、硅上异常的报告；讨论提及 `-noalu` 对早期复现有帮助，也有后续更大结构仍有问题的反馈。 | 器件与配置不同；本机已用 `-noalu`。只能说明有过相似类别的报告，不能据此判定本故障同源。 |
| Apicula [#541](https://github.com/YosysHQ/apicula/issues/541) | GW2A-18C 有 placement 相关的硅上异常报告；报告称相同设计在 Tang Primer 25K / GW5A-25A 上正常。 | 目标器件相反且实现上下文不同，不是 GW5A 分频器故障证据。 |
| Yosys [#5693](https://github.com/YosysHQ/yosys/issues/5693) | Gowin BSRAM 输出寄存器的 CE/OCEB 连接问题；相关修复位于 nextpnr Gowin [BSRAM 打包代码](https://github.com/YosysHQ/nextpnr/blob/5281b8d8afe33d35810c74c129b01124f1ac30ed/himbaechel/uarch/gowin/pack_bsram.cc#L481-L486)。 | 问题范围是 BSRAM 打包，不能外推为通用 divider 寄存器、异步复位或时钟使能缺陷。 |
| Yosys [#6361](https://github.com/YosysHQ/yosys/issues/6361) | GW2A-18C 宽 LUT 映射的面积/速度报告。 | 性能与资源结果，不是功能错误报告，也不是当前 GW5A 设计的实证。 |

## 当前结论边界

已有代理报告：新版 divider-only 网表仿真 4 组向量通过，新版全帧 RTL 仿真 15 例通过；板端曾观察到商全 1、余数为 `N+9`，且用 A 的余数 `0x3C4E` 作为 B 的初始 remainder 可复现该结果。它们缩小了排查范围，但不能证明故障由比较器、ALU、复位、初始化周期或布局布线中的任何单一因素导致。v30 仍没有已完成的布线位流和对应板测结果；不得将放置频率估算或未完成路由当作最终时序证据。

### 来源

- Project F divider 源码，访问日期 2026-10-16：[`div.sv`](https://github.com/projf/projf-explore/blob/main/lib/maths/div.sv)、[`divu_int.sv`](https://github.com/projf/projf-explore/blob/main/lib/maths/divu_int.sv)。
- ZipCPU divider 源码，访问日期 2026-10-16：[`div.v`](https://github.com/ZipCPU/zipcpu/blob/master/rtl/core/div.v)。
- Yosys Gowin 综合脚本，访问日期 2026-10-16：[`synth_gowin.cc`](https://github.com/YosysHQ/yosys/blob/main/techlibs/gowin/synth_gowin.cc)。
- Apicula / Yosys 问题记录及 nextpnr 修复链接见上表，访问日期 2026-10-16。

## router2 常量网络撤线修复（2026-10-16 核对）

网络检索找到 nextpnr [PR #1763](https://github.com/YosysHQ/nextpnr/pull/1763)，随后由维护者以官方提交 [`90b9be4`](https://github.com/YosysHQ/nextpnr/commit/90b9be48590762c8a1dfff1fab79351c71920af7) 修复。该提交时间为 2026-08-01，修改 `common/route/router2.cc` 中 `ripup_arc` 的循环条件：常量网络应继续撤线直到走到常量源，原来的 `==` 条件写反了。PR 自身未合并；采用的是维护者说明中的正式修复提交。

本机 `nextpnr-himbaechel --version` 为 `nextpnr-0.10-55-g211cb570`，对应 2026-05-04 的提交。已读取[该版本源码](https://github.com/YosysHQ/nextpnr/blob/211cb5703ca4d93b80991e20247466f0105aa2d6/common/route/router2.cc#L450-L451)，确认仍使用有缺陷的 `==` 条件。v30 router2 在 170 余轮后仍有 700 余条资源冲突，且路由线数持续增加；2026-10-16 主动停止该尝试，保留日志和独立失败状态，并准备在隔离目录获取官方新版 nextpnr 做对照。

这是已确认的**工具版本缺陷**，但尚未取得本设计冲突线的内部追踪，不能断言当前拥塞完全由它引起，更不能据此解释 v29 的板端除法错误。新版工具只有完成路由、时序门槛、位流打包和真实 UART 核对后才能形成新的验证结论。

## 精简 v31 的实际板测（2026-10-16 23:33 本地时间）

v31 保留 v30 算法，精简诊断 UART 并增加启动后的实际 B 状态观测。它通过 6 像素完整帧 RTL 核对，随后以原工具 router1 在 42.3 秒内完成路由（8,189 LUT、1,430 DFF、10 BSRAM、0 DSP，路由后最低频率报告 107.70 MHz）。本机 JTAG 识别 `0x1281b`、SRAM 加载正常，但板测仍失败：

```text
DHRF FAIL D=375F0722 E=02 A=000000764791 B=00007FFFFFFF
RBN=00000002407CA726 RBD=0000000000000009
BN=00000002407CA726 BD=0000000000000009 BR=0000000000000000 BS=0
BQ=000000007FFFFFFF BF=FFFFFFFFC07CA72F
```

它证明该次实现的 B 初始分子、分母和余数均正确，首轮不减，后续迭代仍出现错误。正确参考第 34 轮首次执行减法，最终商 `400DD9AE`、余数 `8`。必须注意：按板端商 `7FFFFFFF` 计算 `N-D*Q mod 2^64`，应为 `FFFFFFFDC07CA72F`，与实测余数相差 `2^33`；两者仅低 32 位一致。因此最终值尚不支持完整 64 位的“首次商位为 1 后每轮均减”路径，仍需逐轮采样。

后续受控实验分别为保持算法不变的逐轮 RAM 跟踪，以及同一 RTL 的 `-nowidelut` 映射对照。网络检索没有发现直接匹配本次 GW5A LUT5/比较器异常的公开已确认问题；`-nowidelut` 是缩小变量的实验选项，而不是已有事实支持的修复结论。

## SPX9 时序模型重复检查（2026-10-17 核对）

检索到 nextpnr [issue #1803](https://github.com/YosysHQ/nextpnr/issues/1803) 和
[PR #1786](https://github.com/YosysHQ/nextpnr/pull/1786)。截至核对时，两者仍为 open，
PR 没有合并。报告指出 `gowin_arch_gen.py` 的 DP 循环将 CLKB/ADB setup/hold
附加给上一循环的 `sp`，使 SPX9 的同一检查重复四次，并遗漏 DP 的 B 口地址检查；
另外指出 DP 读输出 `DO` 应为 `DOB`，RAM16SDP4 数据输入名称缺少 `]`。

已读取实际新版 nextpnr 对应的
[`44a6c739` 源码](https://github.com/YosysHQ/nextpnr/blob/44a6c739/himbaechel/uarch/gowin/gowin_arch_gen.py)：
第 2053 行仍为 `add_bram_bus_input(sp, "CLKB", "ADB", ...)`，第 2049 行仍为
`add_bram_bus_output(dp, "CLKB", "DO", ...)`。下载源码 SHA-256 为
`6bf448d2ba790bf3e6c26b132c71cd75d390da9896fa994a3529b2a341dac7a4`。
本机 BASIC8 首次 PNR 出现地址路径到达 0.58 ns、打印 hold 0.12 ns，却报告违例，
同一端点重复打印，与公开复现的诊断形态相符。它支持对生成器和派生 chipdb 做隔离
修复实验；没有授权忽略时序错误，也不能解释去雾的算术故障。

## 后续实验边界（2026-10-17）

- 新版 nextpnr 单独替换，以及新版 nextpnr 与新版 Apicula 配套，均未修复 v31 板端
  B 除法；新版工具配置的商为 `3FFFFFFF`、余数 `007CA72F`。
- v32 的 64 条板端跟踪含符号位/减法选择矛盾及状态递推不一致，不能直接据此定位
  divider 的第一处算法错误。独立 64×258 位同步双端口 RAM 的六模式板测通过，只覆盖
  该独立候选，不能外推为完整设计中的所有 RAM/观测路径正确。
- v33 冻结综合网表结合 OSS LUT/DFF 模型及经过独立定向测试的窄 SDPX9B 功能模型，
  仿真 UART 前缀为 `DHRF PASS D=69B9F759 E=0`。该证据未复现板端错误，但自写 RAM
  模型不包含官方物理时序或所有碰撞行为，不能当作硅上原语保证。

## LUT1～LUT3 时序弧遗漏（2026-10-17 新检索）

nextpnr [PR #1850](https://github.com/YosysHQ/nextpnr/pull/1850) 于
2026-10-16T15:09:23Z 提交，核对时 open、未合并。其说明指出只有 LUT4 定义了
时序弧，而 Yosys 也会输出 LUT1/2/3；这些小 LUT 的端口被归入 `TMG_IGNORE`，
相关路径无法完整参与时序分析与驱动布局。报告给出 GW5A-25A 的八级 LUT2 链：
修复前报告 1024 MHz，补全时序弧后为 166 MHz。补丁按实际共用 BEL 输入，将
LUT4 `a_f`/`b_f`/`c_f` 延迟应用于 LUT1/2/3 的相应输入。

已通过 GitHub API 读取 PR 正文和实际 diff，不以搜索标题代替源码证据。
隔离 chipdb 修复任务已纳入该独立补丁。此前 v31/v33/v38/v41 等旧频率报告只保留为
历史报告值，须用修正模型重新核验；不能再单凭旧 Fmax 签核 50 MHz。CE4 的三次
真实小帧 PASS 不受记录变更影响，但该现象和模型缺陷尚未形成单一根因证明。

直接统计冻结综合网表：v31 的 LUT1/2/3 为 4,742 / 8,189（57.9%），v41 为
4,864 / 8,282（58.7%），CCM/Gamma v40 为 2,993 / 4,912（60.9%）。这些数量
说明该模型缺口确实涉及当前设计；它们没有给出修正后的临界路径或真实 Fmax。

另检索到 Yosys [issue #6163](https://github.com/YosysHQ/yosys/issues/6163)：
GW1N-9C 的 SPX9 同步读数据在 idle 分支清零时出现仿真/硅上差异，报告称 idle
保持读寄存器可规避。该记录仍 open，器件与当前 GW5A 不同；v41 的三类系数/输入
RAM 读寄存器本来就没有 idle 清零分支，故暂未发现可直接应用的代码差异。
