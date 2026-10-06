# wave2_ip_20k — Group F 单元记录 (idx25–29, comm/motor)

Agent F deliverables. 所有 EXP digest 由 `tools/golden_comm.py` 独立计算
(T1)；每个 `sim/dump_<unit>.txt` 与 `sim/golden_<unit>.txt` 已逐字节
`diff` 一致。判定全部 `===`/`!==` (T6)；所有寄存器 `clk_en` 门控 (T2)。
CAN CRC15 与 Ethernet CRC32 在 RTL 和 Python 中各自独立实现，无共享代码。

## 验证证据 (iverilog -g2012, 工程根目录执行)

```
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
    src/<u>.v src/st_<u>.v sim/tb_st_<u>.v sim/gowin_bsram_sim.v
vvp sim/tb_st_<u>.vvp
```

| idx | TAG | module      | W2TB 结果 | digest   | cycles |
|-----|-----|-------------|-----------|----------|--------|
| 25  | CAN | can_ctrl    | PASS      | DC301204 | 9639   |
| 26  | MAC | eth_mac_mii | PASS      | 7DC3E176 | 773    |
| 27  | PWM | pwm_gen     | PASS      | 89356055 | 144    |
| 28  | QEI | qei_dec     | PASS      | 6E057083 | 261    |
| 29  | STP | step_drv    | PASS      | AAF87DCF | 499    |

`python tools/golden_comm.py` 输出:
`CAN DIGEST=DC301204 / MAC DIGEST=7DC3E176 / PWM DIGEST=89356055 /
QEI DIGEST=6E057083 / STP DIGEST=AAF87DCF`，并写出
`sim/golden_{can_ctrl,eth_mac_mii,pwm_gen,qei_dec,step_drv}.txt`。

## synth_gowin stat (yosys, `synth_gowin -top <u>; stat`)

| module      | LUT1-4+MUX5 | DFF | ALU | BSRAM | DSP |
|-------------|-------------|-----|-----|-------|-----|
| can_ctrl    | 455         | 307 | 77  | 0     | 0   |
| eth_mac_mii | 368         | 243 | 68  | 0     | 0   |
| pwm_gen     | 30          | 96  | 112 | 0     | 0   |
| qei_dec     | 73          | 70  | 64  | 0     | 0   |
| step_drv    | 231         | 132 | 144 | 0     | 0   |

全部 ≤1500 LUT4、0 DSP、0 BSRAM，达标。

## idx25 can_ctrl — CAN 2.0A 控制器

接口：`rx_pin/tx_pin/loopback`（loopback=1 时内部 wired-AND
`tx_wire & rdrv` 回馈 RX）；TX 命令口 `tx_req/tx_id[10:0]/tx_rtr/
tx_dlc[3:0]/tx_data[63:0]`（byte0 在 [63:56]，MSB 先发）+
`tx_busy/tx_done/tx_ack`；RX 监视 `rx_mon_v/rx_mon_b`（每个采样到的
wire bit 含 stuff 位）与结果 `rx_frm_v/rx_busy/rx_id/rx_rtr/rx_dlc/
rx_data/rx_crc/rx_crc_ok/rx_stuff_err/rx_form_err`。参数 `TQ_DIV`
（每 tq 的 clk_en 拍数）、`SEG1`、`SEG2`；每 bit = 1+SEG1+SEG2 tq，
采样点在 SEG1 末。

功能：TX 发 SOF + 11-bit ID + RTR + IDE/r0 + DLC + 0..8 数据字节 +
CRC15(0x4599) + stuff 位 + ACK 槽检查 + EOF；RX 在 SOF 下降沿硬同步，
去填充、CRC15 校验、CRC delim 后 ACK 槽驱动 dominant 一个整 bit。

自测：内部 loopback 连发 4 帧（DLC=8 全数据、DLC=3、RTR 空帧、
stuff-heavy 00/FF/AA/55/F0/0F 图样）。折叠流 = 监视 wire bit 打包
(MSB 先，尾字节 1 填充) + {id,rtr,dlc,data,crc} + 状态
{form_err,stuff_err,crc_ok,tx_ack}。

限制：单缓冲 TX（tx_req 仅在 !tx_busy 接受）；无总线仲裁/错误帧
（单节点 loopback 假定）；无 SJW 重同步，仅 SOF 硬同步；
ACK 槽采样点按 lpos==ndb+36 判定。

## idx26 eth_mac_mii — MII 以太网 MAC

接口：MII 侧 `mii_tx_en/mii_txd[3:0]`、`mii_rx_dv/mii_rxd[3:0]`、
`loopback`；TX 字节流口 `tx_start/tx_len[10:0]/tx_bidx[10:0]/tx_byte`
（tx_byte 组合供给 tx_bidx 索引的字节）+ `tx_busy/tx_done`；RX
`rx_bv/rx_byte/rx_frm_v/rx_crc_ok/rx_match/rx_len`。参数
`MAC_ADDR`（默认 48'h021122334455）。

功能：TX 发 7×0x55 preamble + SFD 0xD5 + 帧体（目的/源/类型/载荷）
+ 0 填充至 60 字节 + CRC32 FCS + 12 字节 IFG，每 clk_en 一拍一个
nibble（低 nibble 先）。RX 检测 preamble/SFD、nibble 拼字节、
CRC32 残余校验（好帧 = 32'hDEBB20E3）、目的 MAC 过滤
（MAC_ADDR 或广播 FF:FF:FF:FF:FF:FF）。

CRC 约定：IEEE 802.3 反射多项式 0xEDB88320，init FFFFFFFF；FCS 发送
~crc[7:0]..~crc[31:24]（LSB 字节先），每字节线上 LSB 先。

自测：loopback 连发 4 帧（含短帧填充路径与广播帧），折叠监视到的
字节流 + {rx_len, crc_ok, match} 状态。M_NEXT 等 !tx_busy（IFG 结束）
后才发下一帧。

限制：半双工单帧缓冲；tx_byte 必须对 tx_bidx 组合有效；无 PAUSE/
VLAN/错误恢复；rx_byte 流含 FCS 4 字节。

## idx27 pwm_gen — 四通道 PWM

接口：寄存器写口 `reg_wr/reg_addr[2:0]/reg_data[15:0]`（addr0=period，
addr1..4=ch0..3 duty）；`en` 使能；`pwm[3:0]` 输出。参数
`PERIOD_D`/`DUTY_D`（复位默认）。`pwm[i]=en&&(cnt<duty[i])`；
duty=0 恒低，duty=period 恒高；!en 时计数器清零。

自测：写 period 与四路 duty → 使能后跨多个 PWM 周期采样输出，统计
每通道上升沿数与高电平拍数 → 换第二组配置重复；折叠
{rise_cnt, hi_lo, hi_hi}×4ch×2cfg + 末态 nibble。末次寄存器写与采样
使能之间插入一拍 settle（P_SETL），避免首样本采到旧 duty。

限制：duty/period 为 16 bit；寄存器写在任意时刻接受（运行中改值在
下一周期生效）；无量化抖动/死区。

## idx28 qei_dec — 正交编码器 x4 解码

接口：`qa/qb` 正交输入、`qidx` 索引脉冲、`idx_rst`；输出
`count[31:0]`、`dir`（最近一步方向，1=正向）、`step_v`（每步一拍）、
`idx_latch[31:0]`、`idx_evt`。

功能：A/B 每沿都计（每正交周期 4 步），A 超前 B 递增、反之递减；
qidx 上升沿把 count 锁入 idx_latch 并拉 idx_evt，idx_rst=1 时同时
清零 count。与索引沿重合的步进被丢弃（文档级限制）。

自测：合成正向/反向 A/B 波形 + 两次索引脉冲（其中一次带 idx_rst），
折叠 count 历史、dir、idx_latch、idx_evt 计数；末沿后留 3 拍
（Q_IDXH/Q_IDXW/Q_IDXF）再折叠，保证最后一沿与索引锁存稳定。

限制：输入无毛刺滤波/同步器（假定外部已同步）；count 为自由
回绕 32 bit。

## idx29 step_drv — step/dir 梯形脉冲发生器

接口：寄存器写口 `reg_wr/reg_addr[1:0]/reg_data[15:0]`
（0=tgt 目标步数，1=tstart 起步间隔，2=tmin 最小间隔=vmax，
3=tdec 每步间隔减量的加速度）；`dir_in`+`go`（一拍脉冲）启动；
输出 `step/dir/pos[15:0]/cur_interval[15:0]/busy/done`。

功能：每个发出 step（pos→k）后按规则更新间隔：
`(tgt-k <= acnt)` 减速 `interval+=tdec`；否则 `interval>tmin` 加速
`interval-=tdec`（不低于 tmin）且 `acnt++`；否则巡航。长行程对称
梯形、短行程三角。step 脉冲宽度 1 个 clk_en 拍。

自测：写 {tgt,tstart,tmin,tdec} → go，逐个 step 折叠
`cur_interval`（发出 step 时已为控制下一间隔的后更新值，
即折叠序列 i_2..i_tgt，i_1=tstart）、dir、pos；校验单调梯形包络
与总步数 == tgt。

限制：tgt=0 直接 done 不发脉冲；间隔为 16 bit，tstart 必须 ≥tmin
（否则立即进入巡航/减速分支）；运行中改寄存器对当前 move 生效，
建议 busy=0 时写。

## 文件清单

```
src/can_ctrl.v      src/st_can_ctrl.v      sim/tb_st_can_ctrl.v
src/eth_mac_mii.v   src/st_eth_mac_mii.v   sim/tb_st_eth_mac_mii.v
src/pwm_gen.v       src/st_pwm_gen.v       sim/tb_st_pwm_gen.v
src/qei_dec.v       src/st_qei_dec.v       sim/tb_st_qei_dec.v
src/step_drv.v      src/st_step_drv.v      sim/tb_st_step_drv.v
tools/golden_comm.py
sim/golden_{can_ctrl,eth_mac_mii,pwm_gen,qei_dec,step_drv}.txt
sim/dump_{can_ctrl,eth_mac_mii,pwm_gen,qei_dec,step_drv}.txt
```
