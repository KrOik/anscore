# 旧 DVP RX 满环 BRAM 碰撞修复计划（尚未实施）

状态：**设计与临时副本综合估算完成，生产修复未实施，未做新方案功能验收，不计新增 IP 核。**

生产目录 `image/dvp_rx/` 未编辑。当前生产 RTL SHA256 为 `97460fa9f7e96eb83d2a4effedfc535431306556091bba7c297c3c40ace44f26`。本文件只规划后续经集成安排的修复；原始源码冻结、历史日志和验收记录须保留。

## 问题与设计选择

现实现逻辑容量 D=FIFO_DEPTH，物理 RAM 也是 D 个27位条目。满时 count=D、wp=rp；`pixel_event && full && read_en` 仍可接受传感器像素，同时旧头条目被同步读取。这使同拍跨端口同地址读写依赖硬件 read-old 行为。RTL 仿真非阻塞赋值返回旧值不等于 Gowin 物理碰撞性质已经证明。

DVP RX 没有输入 ready，不能照 TX 那样临时背压传感器，也不应减少既有 FIFO 容量。建议保留 count 的逻辑上限 D，物理 RAM 改为 P=D+1 个条目，并保留现有单独输出 holding register。总可用缓冲容量仍是 D 个 RAM 排队像素加一个已暴露输出像素，合计 D+1。

后续最小 RTL 修改边界：

- `AW = max(1, $clog2(FIFO_DEPTH+1))`。
- 物理数组 `mem[0:FIFO_DEPTH]`（27位数据及标记不变）。
- 读写指针地址范围均为0..FIFO_DEPTH，末地址 FIFO_DEPTH 后回0；这是模 P 的环，不是模 D。
- `full = (count == FIFO_DEPTH)`、pixel_event/push/read_en/pop 的既有逻辑容量与满时同时读写策略保持原意。
- 不更改每帧控制、错误码、CE语义、RGB565转换、输出标记、start/DONE 或 ERROR_DRAIN 首错保持契约。
- count 可沿用与 AW 关联的既有宽度（会在 D 为2的幂时增宽一位）；不依赖计数器自然溢出来回绕。

## 无同址与容量不变证明

稳定状态应维持：`0 <= count <= D`，`0 <= wp,rp < P`，以及 `wp = (rp + count) mod P`。

复位/清 FIFO 时 count=0、wp=rp=0。仅 push 时 count+1、wp按 P 增1；仅 read 时 count-1、rp按 P 增1；同时 push/read 时 count不变、两指针均按 P 增1。因此不变量归纳保持。

read_en 要求 count!=0。若同时 read_en 和 push，则 `1 <= count <= D < P`，所以 wp!=rp，硬件读写地址不同。空 FIFO 虽 wp=rp，但不会同步读取。逻辑满 count=D 时仍可同时读取头和写入剩余物理空槽：wp与rp相差D而不相等；逻辑 count保持D。因此既避免碰撞，又不丢掉旧满环可接受的传感器像素，也不改变溢出门限。

## 资源估算与上界

作者已有临时副本估算 `image/dvp_tx/rx_ring_proposal.json` 及对应 `rx_ring_proposal_1024.log`、`rx_ring_proposal_4096.log`。本审查独立核对这些日志 SHA、cell表和 LUT/BRAM 重计数，通过。该报告为 SYNTHESIS_ONLY_PROPOSAL，不是生产修复。作者候选源码 SHA 为 `b5fc14d4c490e7434fabb14aefb00a0a2f003bb69f41d2b3860b6c8fd1146ae7`。

| 逻辑容量 | 物理条目 | 旧 LUT / DSP / BRAM9 | 临时方案 LUT / DSP / BRAM9 | 增量 |
|---|---|---|---|---|
|1024|1025|564 / 0 / 4|587 / 0 / 6|+23 LUT、+2 BRAM9|
|4096|4097|630 / 0 / 12|879 / 0 / 14|+249 LUT、+2 BRAM9|

临时独立估算也得到相同资源；我方估算文件为本目录 `dvp_rx_collision_estimate.json`，脚本 `estimate_dvp_rx_collision.py` 只在 TemporaryDirectory 修改副本，运行前后检查生产源码字节未变。此估算在 root 去重通知到达前已结束，不再重复综合。

每种 RAM primitive（含 SP/SPX9/ROM）统一计2 BRAM9；LUT-class 是 LUT+ALU+MUX+4*RAM16SDP4。默认方案为3个 DPX9B，最大深度方案为7个 SDPX9B。已测最大配置14 BRAM9，低于46预算；此测量不能代替任意参数的最终综合。

若需与映射器无关的存储规划余量：P<=4097、宽27位，可按9位宽×2048深度的块配置成3个宽切片×3个深段，即至多9个18K级块、18 BRAM9的可实现保守 RAM 分配。它是实现可行的存储规划上界，不是所有 Yosys 自动映射结果的保证，也不限定额外地址译码 LUT。实际发布仍以选定参数的综合 cell表为准；尤其1024→1025和4096→4097跨越物理深度边界会产生块数跳变。

## 必须更新和补充的测试

1. 更新原 full-FIFO 同步读写定向用例：不再期待同地址 read-before-write，而应要求满逻辑 count=D 时 wp!=rp，push/read可同拍，count保持D，像素与标记逐一正确。D=3以及D=2必须各覆盖多圈完整回绕。
2. 在健康和错误边界均加入地址范围、count上限、环距离=count、不发生 push&&read_en&&wp==rp 的断言。模运算断言使用足够宽的整数，避免 testbench 自身截断；只在有效参数与复位释放后检查。
3. 独立 scoreboard 检查传感器已接受像素队列与输出，灰度/RGB565、双字节序、CE0/m_ready0情况下达到D+1总容量；第D+2个无法腾出槽的输入才按原定义溢出。相反，满时pop/read同时发生必须成功接收新像素且不溢出。
4. 比较修复前后健康接口轨迹和错误码：不改变逻辑容量，不增加输出气泡，不更改原来的 overflow、short/long line/frame、partial pixel、sync overlap、abort和ERROR_DRAIN保持。对错误帧按 provisional 契约丢弃，不能靠修改期望来掩盖有效输出变化。
5. 深度覆盖2、3、4、7、1023、1024、1025、4095、4096，分别覆盖空、1条、逻辑满、接近物理末地址、同时push/read、写/读独立回绕、reset/abort/错误清空。1024和4096均使物理深度非2幂，必须跑真实回绕，不能只靠小规模仿真推断。
6. 极性、sample_valid空隙、配置捕获、全部65536个RGB565值及两种字节序、4096宽/高轴边界均继续覆盖；相机320×240和640×480两模式完整比对。

## 回归和集成范围

只有获得独占旧核修改安排后才落地，先保存原冻结源码与历史证据供复现，不覆盖历史通过的事实记录。新冻结明确说明这是旧核 bug 修复与资源变化，不计一个新核，也不能继续声称该旧核生产文件哈希完全未变。

至少执行原 DVP RX 四项：`run_tests.py`、`test_protocol.py`、`test_numeric_limits.py`、`synth.py`，并执行新增 ring/capacity 定向测试。综合继续 `-nodsp; check -assert`，重计所有块RAM并核15K LUT/4 DSP/46 BRAM9预算。

随后重跑所有实际引用 DVP RX 的集成链（由全仓源清单与实例化检索确定），包括 DVP TX→RX 以及后续图像处理/视频桥链，并刷新其测试输入清单、源码绑定、source_freeze、manifest资源、最终只读审查。此前扩展批次祖先记录和已验收48工程原样保留，新发布检查点说明旧输入有意修复，而不是改历史hash或UART摘要。

完成完整扩展测试批次、audit-only、祖先/资源/peer检查后，才能声称离线修复已验证。若新改动被集成到板顶，则必须重新综合/布局布线并实际板测该链路，原板验收不能自动覆盖这项改动。目前本计划没有实施、仿真通过、P&R或上板的声明。
