# cnn_infer_138k — Tang Mega 138K Pro SOM 上的 INT8 CNN 推理 IP

目标板：GW5AST-LV138FPG676A（Tang Mega 138K Pro SOM），50MHz 时钟 P16。
主机链路：NanoDAP 调试 JST UART，115200 8N1（COM25）。

**实测引脚**：TX=P15（另有 U16/V22 同数据扇出），RX=N16
（由 projects/gw5a138_rxprobe 全引脚 sticky-mask 探测确认）。

## 网络结构（固定权重，免训练）

```
img 28x28x1 u8 -> conv1 3x3 p1 1->16  -> relu>>7 clamp127 -> pool2 -> 14x14x16
               -> conv2 3x3 p1 16->16 -> relu>>7 clamp127 -> pool2 -> 7x7x16
               -> fc 784->10 -> int32 scores
```

权重/偏置/输入图由 `host/cnn138k/gen_mems.py` 确定性生成（xorshift32，
seed=0x13820），全部 $readmemh 进片内 BSRAM/分布式 RAM。golden 输出见
`mem/golden.json`（digest=f0981d37, argmax=1）。

## 引擎

16 lane x 9 INT8 MAC = 144 乘法器（DSP 映射）。卷积按 ic 平面经 3 行行缓冲
流式扫描，3x3 窗广播到 16 lane；acc 512b 宽 RAM（16 x int32）流水 RMW；
池化/量化并行 16 lane；FC 复用同一 MAC 阵列。CRC32 覆盖两级 fmap 输出与
10 个分数，digest 用于主机比对。详见 SPEC.md。

## UART 协议（见 SPEC.md 表格）

PING / LOAD / RUN / STAT / RESC / DUMP / SELFTEST。
上电自动跑一遍默认图并通过 TX 打印 `CNN138K BOOT D=XXXXXXXX C=NNNNNN`。

## 流程

```powershell
python host\cnn138k\gen_mems.py          # 生成 mem/（已提交产物）
.\scripts\test_cnn_infer_138k_sim.ps1    # iverilog 引擎+全链路仿真
.\scripts\build_cnn_infer_138k.ps1       # yosys gw5a -> nextpnr -> gowin_pack
.\scripts\program_cnn_infer_138k.ps1     # openFPGALoader -c cmsisdap (SRAM)
python host\cnn138k\cnn_uart.py selftest # 板上验证: PASS D=F0981D37 ARG=1
```

## 状态

- [x] 引脚实测：TX P15，RX N16
- [x] golden 模型 + mem 生成
- [ ] RTL 仿真通过
- [ ] 板上验证通过
