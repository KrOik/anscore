# 常用外设 IP

提供 9 个功能 RTL 入口：GPIO、PWM、timer、IRQ、UART、SPI master、I²C master、QSPI SDR 和 SD-SPI。串行入口已替换原先的全拒绝占位逻辑；它们通过真实引脚发送/接收数据。此目录独立开发，未接入密码顶层或开发板。

| 模块 | 实现范围 |
|---|---|
| `common_gpio` | 双级输入采样、方向/输出寄存器、原子置位/清位/翻转 |
| `common_pwm` | 单路边沿对齐、0–100% 占空比、范围检查 |
| `common_timer` | 单次/周期倒计时、粘滞 W1C 中断 |
| `common_irq` | 上升沿采集、屏蔽、待处理中断、W1C |
| `common_uart` | 全双工 8N1、可配置波特分频、单字节 RX mailbox、溢出/帧错锁存 |
| `common_spi_master` | 四种 CPOL/CPHA、MSB-first 字节传输、多个 CS、跨字节 CS 保持 |
| `common_i2c_master` | 开漏字节传输、START/重复 START/STOP、ACK/NACK、时钟延展、有界超时、发送 1 时仲裁丢失检测 |
| `common_qspi_controller` | 单线命令、0–4 字节地址、dummy clocks、单线/四线 SDR 读写、128 字节缓冲 |
| `common_sd_spi` | SD v2 SPI 初始化、SDSC/SDHC 寻址、512 字节读写、CRC7/CRC16、自定义命令；详见独立寄存器说明 |

机器清单为 `manifest.json`。SPI 和 SD 共用 `rtl/common_serial_spi_byte.v`。旧 `common_periph_unsupported.v` 与旧验证用例留作历史记录，当前五串行入口不再引用全拒绝端点。

## 公共 native CSR 契约

- `clk` 上升沿；`rst_n` 低有效异步复位，中止事务和未消费的应答。
- `cmd_addr[7:0]` 是完整的字节地址，`cmd_wdata`/`rsp_rdata` 为 32 位，不支持 byte-enable。命令按 `clk_en && cmd_valid && cmd_ready` 接收；应答按 `clk_en && rsp_valid && rsp_ready` 消费。
- 一项 native CSR 应答缓冲，`rsp_valid` 有效后数据/错误保持到消费，消费当拍不接收替换命令。SD 在长操作期间可通过独立 CSR 轮询状态，并显式拒绝冲突配置；SD 的 START 写响应表示操作已接受，完成状态另行查询。
- **串行引脚时序持续按物理 `clk` 前进**，不因 CSR `clk_en=0` 而暂停。UART RX 同步器、TX/RX 位计数、SPI/QSPI/I²C/SD 的传输及超时均如此。CE 暂停期间可以形成新完成应答，形成后保持。GPIO/PWM/timer/IRQ 延续原有按 CE 有效节拍更新的契约。
- 除 SD 外通用错误码 `0=OK`、`1=UNSUPPORTED`（未知地址）、`2=BAD_ACCESS`（错误读写方向）、`3=BAD_CONFIG`（非法配置、忙冲突或协议失败）。SD 的既定错误编码为 1=无效地址/值、2=忙/状态或缓冲不可用，协议失败另由 STATUS 的原因码报告，详见其寄存器说明。
- 除明确说明的传输读回外，成功写返回 0；错误写不修改配置。未知/非对齐地址有限错误，不启动电气传输。

## GPIO、PWM、timer、IRQ

四核功能及原有寄存器保持：

| 核 | 地址/寄存器 | 行为 |
|---|---|---|
| GPIO | `00 INPUT` R；`04 OUTPUT` RW；`08 OE` RW；`0c SET` W；`10 CLEAR` W；`14 TOGGLE` W | 输入双级采样；WIDTH=1..32；原子输出操作 |
| PWM | `00 CONTROL` RW；`04 PERIOD` RW；`08 DUTY` RW；`0c COUNTER` R | CONTROL bit0 enable；`0<=DUTY<=PERIOD`，PERIOD 非零；配置写重启相位 |
| timer | `00 CONTROL` RW；`04 RELOAD` RW；`08 REMAINING` R；`0c STATUS` R/W1C | CONTROL bit0 enable、bit1 periodic；STATUS bit0 pending；新到期优先于清除 |
| IRQ | `00 MASK` RW；`04 PENDING` R/W1C；`08 LEVEL` R；`0c ACTIVE` R | 双级采样后捕获上升沿；新边沿优先于清除；ACTIVE=PENDING&MASK |

GPIO/IRQ 无去抖、优先级或电平中断；PWM 无死区、互补/故障关断或影子配置；timer 无独立预分频/捕获比较。PWM/timer 周期以 CE 有效节拍计，不能当作独立于 CE 的实时时基。GPIO/IRQ 同步器不能替代物理 CDC 验证。

## UART 8N1

| 地址 | 权限 | 行为 |
|---|---|---|
| `00 TXDATA` | W | 低 8 位开始发送，其他位需 0；忙返回 BAD_CONFIG；响应表示已接受，TX 随后独立完成 |
| `04 RXDATA` | R | 取出 mailbox 低 8 位并清 valid；空读 BAD_CONFIG |
| `08 STATUS` | R/W1C | bit0 TX busy、bit1 RX valid、bit2 overflow、bit3 framing、bit4 RX busy；仅 bit2/3 可写 1 清除 |
| `0c DIVISOR` | RW | 每位物理时钟数，最小 4；TX/RX 忙时禁止修改 |

复位分频为 `max(4,CLOCK_HZ/BAUD)`，默认 27 MHz/115200，整数取整。RX 经两级同步后在起始位中点验证、逐位中心采样。错误停止位置 framing 并丢弃该字节；mailbox 满时保留旧字节、丢弃新字节并置 overflow。读取旧 mailbox 与接收完成同拍时保留新字节。无 FIFO、奇偶校验、硬件流控或自动波特率。

## SPI master

| 地址 | 权限 | 行为 |
|---|---|---|
| `00 MODE` | RW | bit0 CPOL、bit1 CPHA、bit2 KEEP_CS；其他位 0；CS 断言期间禁止改模式 |
| `04 DIVIDER` | RW | 非零半周期物理时钟数；SCLK=`clk/(2*DIVIDER)` |
| `08 CS_INDEX` | RW | `0..NUM_CS-1`，默认 0；CS 断言时禁止切换 |
| `0c TXRX` | RW | 写低 8 位启动 MSB-first 字节传输；**完成后**返回收到字节；读取得到上次 RX |
| `10 STATUS` | R | bit0 shifter busy、bit1 CS asserted |
| `14 CS_ASSERT` | RW | bit0 手动断言/释放当前 CS；其他位 0 |

NUM_CS 为集成参数（1..32）。四模式 CPHA=0 在 leading edge 采样、CPHA=1 在 trailing edge 采样；空闲电平由 CPOL 决定。普通传输自动断言 CS，KEEP_CS=0 时完成后释放；KEEP_CS=1 使多次 TXRX 保持同一 CS，最终写 CS_ASSERT=0 释放。单次 native 传输等待期间不接受新 CSR。无 DMA/FIFO。

## I²C 字节 master

板级按 `pad = drive_low ? 0 : Z` 连接并安装上拉，输出没有主动驱动高电平。SCL/SDA 输入持续双级采样。CLOCK_DIV 是每个最小低/高阶段的物理时钟数，默认 67，最小 2；同步与等待会额外延长位周期，因此无需假设恰好 `clk/(2*DIVIDER)`。

| 地址 | 权限 | 行为 |
|---|---|---|
| `00 EXEC` | W | bit0 START、bit1 STOP、bit2 READ、bit3 READ_NACK、bit4 STOP_ONLY；bit5 以上必须为 0 |
| `04 TXBYTE` | RW | 下一字节（写传输由 host 自行构造地址/RW 位）；高 24 位必须 0 |
| `08 DIVIDER` | RW | 最小 2；总线 active 期间不允许修改 |
| `0c RESULT` | R | 低 8 位上次读字节；bit8 NACK、bit9 arbitration lost、bit10 stretch timeout、bit11 bus stuck/busy |
| `10 STATUS` | R | bit0 busy、bit1 bus active、bit2 last NACK、bit3 synchronized SCL、bit4 synchronized SDA |

EXEC 完成后返回同样的 RESULT 格式；任一错误位令 rsp_error=3。START 在已有 active 总线时生成重复 START。不带 START 的字节仅允许在 active 总线上执行。不带 STOP 时传输完成后保持 SCL 低，允许下一字节；READ_NACK=1 发送读末尾 NACK，=0 发送 ACK。STOP_ONLY 仅允许 bit4=1 且总线 active。

典型写寄存器：TXBYTE=设备地址写，EXEC=START；TXBYTE=寄存器号，EXEC=0；TXBYTE=数据，EXEC=STOP。读末尾 EXEC=READ|READ_NACK|STOP。写地址/字节收到 NACK 会显式返回错误，仍按请求生成 STOP。START 等待空闲、SCL 延展等待及 STOP 均有界；超时/仲裁丢失释放总线。STRETCH_TIMEOUT_TICKS 为等待状态的物理 clk 上限（最小按 1）；未实现完整多主时钟同步、自动重试或九脉冲 bus recovery。

## QSPI SDR 事务

| 地址 | 权限 | 行为 |
|---|---|---|
| `00 OPCODE` | RW | 低 8 位单线命令 |
| `04 ADDRESS` | RW | 0–4 字节地址，低 N 字节按 MSB-first 发送 |
| `08 CONFIG` | RW | bit2:0 地址字节数 0..4、bit3 四线数据、bit4 读数据、bit15:8 数据字节数 0..128；其余 0 |
| `0c DIVIDER` | RW | 非零半周期物理时钟数 |
| `10 EXEC` | W | 写 1 执行；命令+地址+dummy+数据保持同一 CS；完成应答返回数据长度 |
| `14 DUMMY` | RW | 低 8 位 dummy 完整 SCLK 周期数 |
| `18 STATUS` | R | bit0 busy、bit8:1 已完成的数据字节数 |
| `40..bc BUFFER` | RW | 32 个小端字寄存器，128 字节缓冲；发送/接收均从字节 0 开始 |

命令和地址固定单线 DQ0。单线数据读 DQ1、写 DQ0；四线数据按高 nibble 再低 nibble 走 DQ3:0。SDR leading edge 采样（CPHA=0），默认 CPOL=0；无 DDR、DQS、XIP、自动 flash 初始化或跨页 program 策略。dummy/read 阶段释放所有 DQ，因此单线器件 WP#/HOLD# 应在板级上拉。host 必须根据目标器件手册设置 QPI/QE、命令、dummy 及写使能等；本核不暗中替换命令。

未初始化发送字节使 EXEC 返回 BAD_CONFIG。读操作开始会清除缓冲 valid，完成后可读全部返回字节；最后不足 4 字节的读字以 0 填充未返回字节。完全无有效字节的 BUFFER 读取返回 BAD_CONFIG。读取不提供页映射，也不声称 flash program/erase 完成轮询已自动执行；可用零数据命令及后续 status 命令完成这些明确事务。

## SD-SPI

独立寄存器、初始化步骤、读写/CRC/错误状态及 host 操作顺序见 [SD_SPI_REGISTERS.md](SD_SPI_REGISTERS.md)。512 字节 buffer 为同步读取存储，块传输不依赖外部逐字节重放。仅 SPI 总线协议及块设备操作；无 SD 四位总线、文件系统、DMA 或多块传输。

## 分组开发检查

```powershell
python cores/system/common_scaffold/peripherals/run_tests.py
```

默认检查把全部外设 RTL 一起编译，然后运行两个短组级引脚协议仿真（四串行核组与 SD 卡模型组）。四核组以独立 UART 数据源/接收器、SPI slave、I²C 开漏从机与 QSPI flash 模型检查数据；覆盖四种 SPI 模式、I²C ACK/NACK/延展/超时、QSPI 单线/四线/dummy、响应背压、复位释放和运行时 CE 暂停。SD 组的实际覆盖见其 PASS 输出和 evidence。

脚本仅用 Python 标准库和 Icarus Verilog，自动补全 OSS CAD Suite bin/lib；每次在 `evidence/<UTC时间戳>/` 新建日志、实际命令、源码 SHA-256 与 summary，不覆盖旧记录。`sim/tb_common_peripherals.sv`、`run_tests_legacy.py` 以及先前 `functional=4 placeholder=5` 记录保持为历史基线，旧占位期望不再代表当前 RTL，也不作为当前默认检查。

此阶段完成代码开发和上述短组仿真。未综合、未布局布线、未上板，LUT/DSP/BSRAM 资源未知；不宣称这些外设与图像算法同时装入 20K 器件。部署时仍需独立约束引脚、时钟、IO 电平、资源和时序。
