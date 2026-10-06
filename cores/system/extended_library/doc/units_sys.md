# wave2_ip_20k — Group G 单元记录 (idx30–34, system/infrastructure)

Agent G deliverables. 所有 EXP digest 由 `tools/golden_sys.py` 独立计算
(T1)；每个 `sim/dump_<unit>.txt` 与 `sim/golden_<unit>.txt` 已逐字节
`diff` 一致。判定全部 `===`/`!==` (T6)；所有寄存器 `clk_en` 门控 (T2)；
RAM 一律走 `w2_dpram` (T9)。

## 验证证据 (iverilog -g2012, 工程根目录执行)

```
iverilog -g2012 -I src -o sim/tb_st_<u>.vvp -s tb_st_<u> \
    src/<u>.v src/st_<u>.v [src/w2_dpram.v sim/gowin_bsram_sim.v] sim/tb_st_<u>.v
vvp sim/tb_st_<u>.vvp
```

| idx | TAG | module | W2TB 结果 | digest | cycles |
|-----|-----|--------|-----------|--------|--------|
| 30 | DMA  | dma_sg     | PASS | 92C91DF3 | 1427 |
| 31 | ILA  | ila_core   | PASS | 17852826 | 8242 |
| 32 | CRC  | crc32_eth  | PASS | CE9832E0 |   76 |
| 33 | PRBS | prbs31     | PASS | DBA2F926 |  308 |
| 34 | MBST | mem_bist   | PASS | C9D87DF5 | 5165 |

`python tools/golden_sys.py` 输出:
`DMA DIGEST=92C91DF3 / ILA DIGEST=17852826 / CRC DIGEST=CE9832E0 /
PRBS DIGEST=DBA2F926 (err_cnt=10, bit_cnt=269) / MBST DIGEST=C9D87DF5`。

## synth_gowin stat (yosys, `synth_gowin -top <u>; stat`)

| module | LUT1-4+MUX5 | DFF | ALU | BSRAM(DPX9B) | DSP |
|--------|------|-----|-----|------|-----|
| dma_sg     |  86 |  72 | 80 | 0 | 0 |
| ila_core   |  71 |  76 | 43 | 1 | 0 |
| crc32_eth  | 138 |  32 |  0 | 0 | 0 |
| prbs31     |  87 |  74 | 44 | 0 | 0 |
| mem_bist   | 117 |  48 | 12 | 1 | 0 |

全部 ≤1500 LUT4、0 DSP，达标。

## idx30 dma_sg — 简易 DMA

接口：寄存器写口 `reg_we/reg_addr/reg_data[15:0]`（0=src_addr,1=dst_addr,
2=len,3=ctrl{bit1=dir,bit0=go}，仅 busy=0 时接受）；两组 RAM 口
`a_*/b_*`（各含 write+read 通道，busy=0 时由外部 mux 走）；`busy/done`
电平 + `irq` 单拍脉冲。dir=0 A→B，dir=1 B→A；流水 1 word/clk_en
beat。len=0 直接 done+irq。

自测：A[i]=i*5+0x3C、B[i]=0xC3 → desc1 A[16:79]→B[100:163] → 回读
B[0:255] → desc2 B[200:215]→A[0:15] → 回读 A[0:15]；折叠 274 字节
含两次 {irq,done} 状态字节。

限制：len 按 word 计，须 ≤RAM DEPTH（超界地址自然回卷，文档级约束）；
寄存器写在 busy 期间被忽略。

## idx31 ila_core — 片内逻辑分析仪

8 通道 `probe[7:0]`，深度 `1<<AW`（默认 1024，AW≤10）进 `w2_dpram`
环形缓冲。触发 `match=(probe&mask)==(val&mask)`，mode 0 电平 / 1 上升
沿 / 2 下降沿；仅在已写 ≥`pre_trig` 个样本后才允许触发（保证 pre 窗
有效）。触发样本记为 `trig_ptr`，其后继续写 `DEPTH-pre_trig` 个 post
样本（触发样本为 post#1），然后 `done`。配置口
`cfg_we/cfg_addr/cfg_data`：0=mask,1=val,2=pre_trig(钳位 DEPTH-1),
3=mode。`arm` 脉冲重启。读出串行口 `rd_en+rd_addr→rd_q`（寄存储存，
1 拍延迟）。

自测激励 `probe = cnt[7:0] ^ {cnt[10:8],5'b0}`：
run1 mask=val=0xE0 level pre=200 → trig_ptr=224；
run2 mask=val=0x01 rising pre=50 → trig_ptr=51。
每 run 回读全部 1024 字节 + trig_ptr lo/hi + {fired,done}，
共 2054 字节。

限制：连续采样无 decimation；pre_trig>DEPTH-1 自动钳位（触发等价于
立即模式）。触发发生在 arm 后 <pre_trig 个样本时被门控延迟。

## idx32 crc32_eth — 流式 CRC

`mode`：0 = CRC-32/IEEE-802.3（poly 0xEDB88320 reflected，
init/xorout 0xFFFFFFFF）；1 = CRC-16/CCITT-FALSE（poly 0x1021
MSB-first，init 0xFFFF，xorout 0）。`init` 拍加载初值，`dv+din`
每拍 1 字节，`crc_out` 为含 final-XOR 的当前余数（组合读 state，
末字节后 1 拍有效）。

强制检查：CRC32("123456789")===0xCBF43926 与
CRC16("123456789")===0x29B1 均为 st 内独立判定（连同 20B/16B
参数化流的结果一起折叠 13 字节）。

限制：无双模同时运行；crc_out 组合输出在深时钟域需自行打拍。

## idx33 prbs31 — PRBS-31 发生+校验

固定多项式 **x^31 + x^28 + 1**（Fibonacci 形式）：输出 `r[0]`，
反馈 `r[30]^r[27]`，`r<={fb,r[30:1]}`，即输出流满足
`b[n]=b[n-28]^b[n-31]`。`seed_we+seed` 加载（禁止全 0 锁定态）。
校验器滑动 31-bit 窗：`chk_sync=1` 时装填（31 bit 后 `synced`），
否则预测 `w[30]^w[27]`、错则 `err_cnt++`（窗口自愈）；`bit_cnt`
计已校验位数，均 16-bit 饱和。

自测：seed=0x2AA55AA5，环回 300 bit（0..30 装窗，31..299 校验），
注入强制误码 {40,100,101,250}。因误码污染预测窗，golden 建模总
err_cnt=10（非 4）。折叠 32 字节码流（byte[j]=bit(8k+j)）+
err_cnt/bit_cnt/synced 共 37 字节。

限制：无失锁自动 re-sync 状态机（窗口自愈但 err_cnt 只增）；
`synced` 不会在重新装窗时自动清零——重新同步请配合复位或只用
err_cnt 判据。

## idx34 mem_bist — March 式 RAM BIST（硅探针）

内挂一个 `w2_dpram`（W=8，DEPTH≤1024，默认 256）。固定 March 序列：

```
P0 W  cb(a)=(a[0]?55:AA)          P3 W  wk(a)=01<<a[2:0]
P1 R  cb(a) ; W ~cb(a)            P4 R  wk(a) ; W ~wk(a)
P2 R  ~cb(a)                      P5 R  ~wk(a)
```

任意失配置 `fail` 并锁存首个 fail_addr/fail_exp/fail_got/fail_phase，
march 继续跑完；末态 RAM 内容 = `~wk(a)`。`fi_en+fi_addr` 为
**仅测试**故障注入钩（phase0 在 fi_addr 写数 XOR 0xFF → phase1 必然
在该址报错，用于验证检测通路本身）。busy=0 时 RAM 口 mux 给
`h_*` 宿主口（可预载/回读）。

自测：run1 净跑（期望 fail=0）+ 宿主读 {0,1,2,3,55,AA,FE,FF}；
run2 fi_addr=0x37 → 期望 fail@0x37 phase1 exp=55 got=AA（st 内 `===`
判定）。折叠 2×6 状态字节 + 8 回读字节 = 20 字节。

限制：单端口时序复用（busy 时宿主口不可用）；W 固定 8；模式覆盖
checkerboard + walking-1 及互补读，不含 retention/耦合 fault 模型。

## 文件清单

```
src/dma_sg.v src/ila_core.v src/crc32_eth.v src/prbs31.v src/mem_bist.v
src/st_dma_sg.v src/st_ila_core.v src/st_crc32_eth.v src/st_prbs31.v
src/st_mem_bist.v
sim/tb_st_{dma_sg,ila_core,crc32_eth,prbs31,mem_bist}.v
sim/golden_*.txt sim/dump_*.txt sim/tb_st_*.vvp
tools/golden_sys.py
doc/units_sys.md
```

已知共享文件问题：无。
