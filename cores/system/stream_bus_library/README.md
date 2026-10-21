# Tang Primer 25K 通用系统 IP 系列

在第一批56个通用核基础上新增16个具有原生接口的系统核，并提供可加载变量刺激、全时钟回放、原始输出读回的验收平台。板卡为远端USB上的GW5A-25，50MHz；使用SRAM配置。项目独立于既有NTT顶层，不修改其UART验收合同。

核目录见 [CATALOG.md](doc/CATALOG.md)，参数边界见各核SPEC。最终验证证据及资源见 [VALIDATION.md](doc/VALIDATION.md) 和 `doc/ACCEPTANCE.json`。同一套回放平台复验之前56核；这些复验和板级夹具不重复计入IP数量。

在仓库根目录运行：

```powershell
python cores/system/stream_bus_library/tools/verify.py
python cores/system/stream_bus_library/tools/board_sim.py --adapters --profiles 0,1,2,3,4,5,6,7,8
python cores/system/stream_bus_library/tools/board_sim.py --profiles 0
python cores/system/stream_bus_library/tools/build.py --isolated --profiles 0,1,2,3,4,5,6,7,8
python cores/system/stream_bus_library/tools/remote_board.py --build <build目录> --profiles 0,1,2,3,4,5,6,7,8
.\scripts\test_hybrid_lattice_ntt_sim.ps1
```

实测发现远端USB-UART的主机→B3方向无跳变，串口模式复位和官方IO电气属性复验均未恢复。UART命令路径的板级状态为BLOCKED；未把串口发送成功当作刺激已经抵达FPGA。已提供替代的JTAG载入实测路径：

```powershell
python cores/system/stream_bus_library/tools/auto_vectors.py
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 0,8
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/build.py --auto --profiles 0,1,2,3,4,5,6,7
python cores/system/stream_bus_library/tools/build.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/remote_auto.py --build <对应自动回放build目录> --profiles <对应profile> --jtag-freq 1000000
```

JTAG镜像只预置主机生成的刺激与长度描述，不含期待输出。控制器把刺激写入真实capture_replay RAM、复位DUT、全时钟回放、测量、逐条读回响应RAM，经带CRC的UART输出；主机独立模型核对所有有效输出字段。两个主机刺激集分别无背压和有背压。该路径与UART命令注入的物理覆盖不同，报告分开记载。

本批16核的32个板级案例全部通过，逐条核对2548个原始响应；采集演示另核对18个响应。原56核CE=1复验中52核通过，round_shift_even32、bcd8_encode、leb128_decode4、event_counter32四核存在实际失配，未声明全速通过。原CE=1/16验收与旧发布包保留。profile8同边沿ROM版本未通过hold检查，使用上述半周期地址版本；资源预算按nextpnr物理BSRAM计算。具体失败刺激和限制见VALIDATION与ACCEPTANCE。

依赖本地OSS CAD Suite、Python、cocotb2、paramiko、pyserial；远端须有openFPGALoader和pyserial。SSH密码取环境变量P25_PASSWORD或本地已有连接脚本；不包含在交付包。完整二进制协议见 [PROTOCOL.md](doc/PROTOCOL.md)。

profile0包含16核测试夹具；profile1～7对应原56核的7组，每组8核，CE恒为1；profile8演示数字四通道样本的对齐、串行校准、时间戳与触发前后窗口。每核使用两个不同主机刺激集，分别无背压和周期性输出背压。物理ADC、电气跨域时序、长期温压漂移和安全认证没有由这组测试覆盖。

每个镜像单独受限于15K LUT、4DSP、46BSRAM，并要求布局布线达到50MHz。整个IP目录不要求同时实例化在一个FPGA中。1:1的快核验证II1；串行校准、March、整包提交和触发捕获按其原生速率计量。UART只负责加载/读回，硬件回放吞吐不等于UART带宽。

`evidence`目录保留失败、终止及成功记录。交付报告将通过和失配分别列出，并绑定源代码与原始数据；仿真、综合、物理测试及专利权状态分别记录。本批交付是具有明确验证条件的工程候选IP。
