# B50 新增能力与保留证据

B50 开发基线为 c9117a22459e954d496dfa66dd94d6f67188c862。
四通道完成了实际 RTL、组合例、离线参考模型、有限 TB 和独立审查。
当前为已验证源码、待安全 Git 集成状态；B49 稳定快照保持冻结。
所有 IP 均 HW_UNVERIFIED；未运行综合、PnR、STA、上板、PPA 或历史回归。

## 实际门禁结果

| 包 / 门禁 | 内层准备 | HDL 进程结果 | 仿真 / 保留镜像 | 外层结果 |
|---|---:|---|---:|---|
| Winograd 首次 | 1次 FAIL，模型括号 SyntaxError | 0，均 NOT_RUN | 0 / 0 | FAIL_STOP，exit1 |
| Winograd additive followup01 | 1次 PASS | 12 PASS | 4 / 4 | PASS，15.531s含捕获 |
| timestamp_event_replay | 1次 PASS | 12 PASS + 6真实非零预期参数拒绝 | 5 / 5 | PASS，19.469s含捕获 |
| known_phase_tone_fit | 4次 PASS | 8 PASS + 3真实非零预期参数拒绝 | 4 / 4 | TIMEOUT / FAIL_STOP，20.906s含捕获与清理 |
| rgb_screen_matte | 1次 PASS | 6 PASS | 2 / 2 | PASS，8.109s含捕获 |

四份最终计划实际执行54个内层进程：7次准备、47次HDL。
HDL 原始结果为38个 PASS 和9个实际 FAIL；后者均为计划中的非法参数拒绝，
独立 validated 记录确认了非零退出和指定诊断，未将原 FAIL 改为 PASS。
另保留首次 Winograd 的1个准备失败；合计55个内层进程。
15次仿真和15个镜像只是有限观察计数；不消除 tone-fit 的外层超时。

Winograd 修复仅把模型 formatter 的一行拆为构造12字段 tuple 和 join 两行。
原源码、第一次报告、捕获和两个门禁均未改。新门禁经过 root 与 worker_b
完整审查后执行一次，逐项比较2084输出、521次模型变换恒等式检查；原失败
未被重试覆盖。编译时间单位提示保留。

回放核的四组参数检查797行输入/预期状态，另有实际双路 MoldUDP64/ITCH
四事件组合见证；包含背压、pause、abort、reset、回退时间、窄时间溢出和
held-output归属。六个非法参数检查保留真实 exit1。时间单位提示保留。

信号拟合内层报告完整结束，四次仿真产生65个fixture结果、85条命令、1809个
实际采样握手（含32个reset probe采样）。但外层20秒期限触发了清理；最终
观察目标exit0，taskkill返回128（找不到目标进程），目标和helper均已退出。
记录支持期限附近退出与清理的竞态，不能重构精确完成时刻或宣称按时通过。
整个门禁维持 FAIL_STOP，未更改期限、结果、输入或重跑。

抠像和实际 source-over 各比较1262行，覆盖全部256个alpha、210个非法窗口、
6个精确半值用例。核/组合分别观察1107/1383个held周期、各5个live-reset，
组合另有2个未配对reset探针。旧Porter-Duff依赖的 always_* constant-select
敏感列表提示保留，准备和仿真stderr为空。执行前仅规范新审核记录LF并重新
封存控制，原17个源文件和runner不变；原CRLF候选留在仓库本地.git。

每次执行均在完整root+独立peer源码/精确元数据审查后进行；每个target20s，
必要tree-kill helper5s，终止后唯一target观察2s。每个仿真的image SHA和
prechecked标志在Popen前以exclusive/fsync initial sidecar落盘。所有raw、
terminal、validated和镜像保留，任何失败不自动重试。实际执行与证据审计
分别记录，源码审查不冒充工具PASS。当前没有未确认的活动target/helper。

## 固定证据入口

| 包 | 内层报告（包内相对路径） | SHA256 |
|---|---|---|
| Winograd 首次 | reports/20261106T201511289779Z/results.json | eb4c8f17b0c758c3129c0eabf8448262e14ccbf25c822c667888662ab364f2a6 |
| Winograd 修复 | reports/followup01_20261106T202707954860Z/results.json | 6ec6ff0c557f2a1266739d667a8af5277a10061ea85f9f49fd48f6380f28697d |
| 回放 | reports/20261106T203507904088Z/results.json | c439cb9b7d28684baee9e14086a438c8de1c91427828c28c9d3252b3bc0c0ac0 |
| 相位拟合 | reports/20261106T203014567938Z/results.json | 1a778e1b5c5aa50de620ca70a5eb2eb3bae668f05e813bf1c414ede764e33c84 |
| 抠像 | work/20261106T203545506685Z/results.json | 016aba9267f2589723d6e89b3ed0fa2344c4ed57689fb26329cc8d77b7440fc7 |

各包 QUALIFICATION.md 给出具体计数、源版本和限制。外层原始证据仍在任务
专属 .git/anscore-b50-*-launch/。42个原始报告、捕获、launcher文本和门禁
已按字节复制到 docs/snapshots/b50/outer/，映射见该快照的
outer_evidence_manifest.json；独立复核确认全部原件/副本的大小与SHA一致。
Git集成前还需完成源码闭包/命名冲突与精确文件集审查。
本页不表示已经产生B50提交。

源码入口见 [B50增量索引](IP_INDEX_20261107_B50.md)。
