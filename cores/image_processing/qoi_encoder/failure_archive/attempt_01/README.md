# qoi_encoder

原创、可综合的 RGB/RGBA 光栅到完整 QOI 文件编码器。实现 RUN、INDEX、DIFF、LUMA、RGB、RGBA 六类标准 chunk，按固定参考实现的优先级生成确定字节流。它新增无损压缩编码能力；已有 `qoi_decoder` 提供反向能力，已有 PNG encoder 的 stored DEFLATE 不提供同类颜色压缩。

本轮只允许源码级有限检查。硬件维度为 **HW_UNVERIFIED**，没有综合、布局布线、STA、板测、频率、功耗或资源实测。RTL 存在时可视为 RTL_CANDIDATE；只有当前源文件 seal 下的 `verification.json.status=UNIT_SIM_PASS` 才支持对应有限单元仿真成熟度。没有 receipt 或尚未执行的 child 均不得声称 PASS。

## 参数与端口

| 参数 | 合法域 / 默认 | 含义 |
|---|---|---|
| WIDTH / HEIGHT | 各 1..64 / 8 | 静态帧尺寸，N=WIDTH×HEIGHT |
| CHANNELS | 3 或 4 / 4 | 输入字节通道数 |
| TAG_W | 1..32 / 8 | 不透明事务 tag |
| BYTE_W | 派生 localparam | `max(1,clog2((CHANNELS+1)*N+23))` |

所有端口只有一个上升沿时钟 `clk`，没有 CE、CDC、器件原语或外部存储接口。`rst` 同步高有效；其高电平立即门控 ready、valid、SOF、LAST，活动边沿取消所有权。两个 RAM 及其同步 read-q 不复位；控制寄存器复位。若输出文件中途 reset，接收方须丢弃已收前缀。

输入为普通 `s_valid && s_ready` 传输。`s_pixel` 在 CHANNELS=3 时严格为 24 bit `{R,G,B}`，alpha 隐含 255；CHANNELS=4 时为 32 bit `{R,G,B,A}`，alpha 非预乘。第一拍接受 `s_tag` 和 1 bit `s_colorspace`；之后的 tag/colorspace 变化忽略。colorspace 0 表示 sRGB 与线性 alpha，1 表示全部通道线性；只写 header，不做颜色转换。

固定恰好 N 次接受构成一帧，没有输入 LAST。`s_sof` 只应在像素 0 为 1；`s_eol` 只应在每行末像素为 1。粘滞错误位 `[0]` 为 SOF 不匹配，`[1]` 为 EOL 不匹配，`[2]` 为接受到 `s_error`。错误不提前停止 capture，始终收满 N。缺少像素会等待到 reset；额外像素受 ready 背压，不能依靠 SOF 重同步。

纯文件通道 `m_valid/m_ready,m_byte,m_sof,m_last,m_index,m_tag` 输出标准 QOI 的 header14、payload、footer8。`m_index` 从 0 计数，SOF 只随首字节，LAST 只随 footer 最终 `01`。独立 `d_valid/d_ready,d_bytes,d_errors,d_tag,d_colorspace` 输出一个 held 摘要。好帧摘要只在最后文件字节退休之后出现；坏帧完全不输出文件字节，摘要 bytes=0，即使错误在最后一个像素也不会泄露文件前缀。输入在摘要退休前保持关闭，下一帧最早在随后一个边沿接受。

字节及摘要的 payload/metadata 在对应 valid 且 ready=0 时全部保持。源必须在 valid 且 ready=0 时保持完整输入 beat。接收方不消费字节或摘要时可无限等待，没有无条件完成保证。

## 格式与调度

previous 初始 `000000FF`，64×32 history 初始全透明零。等色先累计 RUN，达到 62、遇异色或帧尾时刷新；异色先刷新待发 RUN，再 INDEX，miss 更新 history 后按 alpha 相等时 DIFF→LUMA→RGB、alpha 改变时 RGBA。INDEX 优先于 alpha 判断。RUN 和 cache hit 不写 history。五个差分量均显式为 8 bit signed、按模 256 回绕解释；不存在连续相同 INDEX chunk。

hash 是 `(3R+5G+7B+11A) mod64`。完整加权和最大 6630，需 13 bit；先将各通道截为低 6 bit 后加权，和最大 1638，需 11 bit。移去各通道的 64 整数倍只改变总和的 64 整数倍，因此低 6 bit 相同。RTL 只用常数移位加法。

帧 RAM 为 N×(8CHANNELS)，history RAM 为 64×32，均单口同步读、无 reset。成功帧在编码前串行写零 history64 次，换取不使用 64 bit validity map；完整 capture 覆盖 raw RAM 后才可读取。40 bit packet buffer 在反压下保留最多 5 个字节；header/footer 由常数和小 case 生成。生产 RTL 无数据乘除、动态 modulo、输出 RAM、缓存展开比较阵列或厂商依赖。

13 状态为 CAPTURE/CHECK/CLEAR/HEADER/PIXEL_READ/CLASSIFY/IREAD/ICHECK/CHOOSE/NEXT/FOOTER/SEND/DONE。标量位数包含两 read-q，公式为 `135+A+X+8CHANNELS+BW+TAG_W`，其中 A=max(1,clog2N)、X=max(1,clog2WIDTH)、BW=BYTE_W。

| 配置 | RAM bit | 标量 bit | 最长文件 byte | 无反压尾延迟上界 |
|---|---:|---:|---:|---:|
| 默认 8×8 RGBA/T8 | 4096 | 193 | 342 | 816 edge |
| 最大 64×64 RGBA/T32 | 133120 | 232 | 20502 | 45168 edge |

这些是声明和纸面调度计数，不是综合面积。架构风险默认 LOW、最大 MEDIUM：最大 raw RAM 需要约 16 KiB，映射粒度和时序仍依器件/工具而定。

设 D 为相对 previous 异色像素数，M 为其中 history miss 数，Bp 为 payload byte 数。成功帧 raw reads=N、history reads=D、history writes=64+M；错误帧三者为零。capture writes 总为 N。最终输入接受后到 always-ready 摘要接受为 `112+3N+2D+M+Bp`，不超过 `112+(CHANNELS+7)N`。首文件字节在最终输入后第 66 个边沿成为 valid，最早第 67 个边沿接受。错误摘要在第 1 个边沿成为 valid，最早第 2 个边沿接受。每个字节或摘要暂停的一个边沿增加一个边沿；capture 间隔不计入尾延迟。

## 使用与有限证据

`files.f` 是核的完整 HDL 依赖；`example/files.f` 包含独立默认实例 `qoi_encoder_default`。两者只依赖本包文件。默认纯字节/LAST/tag 与已有 QOI decoder 的输入语义可衔接，但它最大只支持 16×16，不能宣称本核 64×64 域已与其集成验证。本包不修改、不导入、不重新运行旧 decoder HDL。

冻结的 MATRIX/TEST_PLAN 仍是首 RTL 前 ledger：8 profiles、470 main、210 reset owner 及 210 完整 fresh，78 jobs、167 children。默认覆盖全 50 reset 目标；最大 main 逐帧、reset 逐 ID 拆分。小域的语义不适用和有限范围未选检查分别记录。输入全在 TXT；JSON sidecar 保存独立 decode、canonical、输入/公开文件 hash、reset 退休前缀和已发 RAM 动作。错误帧的 canonical 证书忽略标志错误而证明完整像素文件；其实际公开字节为空，work 只含 capture 与 2-edge 拒绝路径。

`oracle.py` 原创编码选择来自合法 DIFF/LUMA 字段的解码表，再由独立反向 parser 还原全文件。8 手算 anchors、全 DIFF 三元组、LUMA green/relative 边界、hash collision/reuse、RUN62 分段及帧尾、两 colorspace、T32 全位变化、末拍错误抑制均在有限集合内。TB 还核对同步 RAM 行为、完整所有权、逐帧结构工作、queued 边界、held byte/summary、精确尾延迟和每个 reset 后完整 fresh。

`run_tests.py --seal` 只绑定最终源文件，不执行 HDL。root 审查并批准精确 SOURCE_SEAL hash 后，才允许 `--run --authorized-seal <hash>`。原167条命令、分组和20秒上限不变。TIMEOUT 为终局，不重试/缩减/拆分；普通 FAIL 完整归档 sources/seal/plan/receipt/NOT_RUN 后停止，等待 root 精确修复授权。`--audit` 仅核对离线证据，不调用 oracle、prepare、编译器或模拟器。没有综合、PnR、STA、板测或继承回归。
