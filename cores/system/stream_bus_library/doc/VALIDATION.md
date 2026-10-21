# 验证与交付记录

时间：2026-10-09T16:06:04.506009+00:00。新增16个独立原生核；与前批56核合计新增72核。
库存清点为129→185→201份封装清单；夹具、ROM、串口、参数变体与旧核复验不计新增核。
201是资产数量，各项目的成熟度须查看自己的验收记录。

**本批16/16核原生仿真、独立综合及25K板级功能验收PASS。** 原生测试18个配置；
9个适配profile的变量输入与背压仿真PASS。新核32个板级案例核对2548个原始响应；
采集演示2个案例核对18个响应。既有NTT标准回归及六条UART合同PASS，未编辑原NTT源码。

|Profile|受测内容|LUT|物理BSRAM|DSP|路由Fmax MHz|原始响应|板级结果|
|---:|---|---:|---:|---:|---:|---:|---|
|0|新增16核|6616|46|0|96.00|2548|PASS|
|1|原56核第1组|3490|29|0|76.69|2048|FAIL|
|2|原56核第2组|3725|29|0|112.42|2048|PASS|
|3|原56核第3组|3877|24|0|114.71|2048|FAIL|
|4|原56核第4组|3497|29|0|106.01|2048|FAIL|
|5|原56核第5组|3227|29|0|120.58|2048|PASS|
|6|原56核第6组|3519|29|0|53.75|2048|PASS|
|7|原56核第7组|3868|29|0|79.33|2048|FAIL|
|8|采集演示|3415|26|0|106.95|18|PASS|


以上9份镜像均通过50MHz布局布线，≤15000 LUT、≤4DSP、≤46物理BSRAM。
路由PASS与功能PASS分别记录。profile0恰好使用46个物理BSRAM；网表34个逻辑RAM
会被GW5A打包拆分，不能把34当作物理块数。profile8也为14逻辑/26物理块。
独立综合默认参数最多1195 LUT，全部0DSP；独立综合未执行物理路由，RAM原语数仅为估算。

## 原56核全速复验发现

本次CE=1复验为52/56核PASS，4核FAIL：`bcd8_encode, event_counter32, leb128_decode4, round_shift_even32`。
每核两组变量刺激，各128输入，一组无背压、一组每8周期背压2周期。
失败核保持模型失配，未改写期待值。具体逐拍刺激、实际值、期待值列在
ACCEPTANCE.json的profiles/mismatches中，全部原始UART二进制保留。
仅LUT4映射及下降沿结果采集的隔离实验仍有失配，尚不能确定根因。
原来的56核CE=1/16验收与发布包保持原样；它们不等于通过50MHz连续输入验收。
因此本交付没有将全部72核声明为50MHz量产签核完成。

## 物理链路与采集边界

远端192.168.31.176实测GW5A-25，ID0x1281b，用户确认按25K处理。
UART TX C3正常；主机TX→FPGA B3在独立pin诊断中始终高，无跳变、无接收字节。
用户反馈线路未改动；模式复位、B0位操作和官方IO属性复验未恢复接收。
UART命令协议仿真PASS，物理命令注入BLOCKED，不能由主机写串口成功声称FPGA已收到刺激。
默认JTAG速率曾出现DONE后旧镜像仍输出或新镜像无输出；1MHz配置后读到新镜像完整CRC帧。
该现象未确诊为具体硬件故障；DONE本身不作为验收依据。
所有本次镜像仅SRAM加载，没有写Flash。
诊断结束后恢复profile8采集演示并再次读取完整数据帧通过，记录为
`evidence/board_auto_20261009T160212256208Z/summary.json`；当前SRAM保持该镜像。

通过路径是主机生成输入→JTAG初始化刺激ROM→同步复制到真实replay RAM→
50MHz硬件回放→响应RAM→UART逐条CRC原始输出→独立主机模型核对。
ROM只有输入和长度描述，没有期待输出。每个案例显式复位DUT；UART加载/读回
不计入replay cycles。源文件和MEM、上传镜像、捕获数据均有SHA256绑定。

profile8演示四通道乱序epoch对齐、24位有符号Q2.14校准、64位时间戳、前4/后4触发窗口。
它使用数字样本，没有连接物理ADC。packet CDC板测采用同源同频时钟，独立时钟比仅有仿真证据。
校准为0DSP串行16次移位加法及3个收尾阶段，接受后19周期valid，无停顿时II20。
快核记录II1条件及实测回放周期；不同输入/输出条数不以统一吞吐或统一延迟描述。
stream_metrics只适用顺序1:1、未完成≤16的流；拆分、丢包、聚合、触发子窗口
仅使用输入/输出计数及replay周期，其队列溢出/不匹配显式记为errors，延迟不适用。

## 来源、文件与命令

本批新增与改动限于cores/system/stream_bus_library：rtl、ip规格/清单、模型、
原生/适配/协议测试、板级夹具、构建/远端/交付工具、诊断与验证文档。
原56核源码、前批发布包、原NTT源码/摘要/共享脚本及既有用户改动保持原样。
16核源文件SHA256、原生测试入口、原生参数边界见各manifest/SPEC和IP_ASSET_RECORDS.csv。
“知识产权可用”落实为可追溯可集成的工程源资产；未作出专利新颖性、法律权属或安全认证结论。
完整量产签核、长期温压、实际产线外设联调、CDC物理时序及安全证明不由本组测试替代。

```powershell
python cores/system/stream_bus_library/tools/verify.py
python cores/system/stream_bus_library/tools/board_sim.py --adapters --profiles 0,1,2,3,4,5,6,7,8
python cores/system/stream_bus_library/tools/board_sim.py --profiles 0
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 0,8
python cores/system/stream_bus_library/tools/board_sim.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/build.py --isolated --profiles 0,8
python cores/system/stream_bus_library/tools/build.py --profiles 1,2,3,4,5,6,7
python cores/system/stream_bus_library/tools/build.py --auto --profiles 0,1,2,3,4,5,6,7
python cores/system/stream_bus_library/tools/build.py --auto --profiles 8 --half-cycle-rom
python cores/system/stream_bus_library/tools/remote_auto.py --build cores/system/stream_bus_library/evidence/build_accepted_20261009T154403006936Z --profiles 0,8 --jtag-freq 1000000
.\scripts\test_hybrid_lattice_ntt_sim.ps1
```

命令模式9profile综合/路由PASS，auto的profile8原同边沿ROM版本hold检查FAIL，
因此最终profile8使用下降沿地址寄存的ROM；未跳过时序检查。所有失败日志原样保留。
原生证据：`evidence/sim_20261009T150748424724Z/summary.json`；适配证据：`evidence/adapter_sim_20261009T150748429259Z/summary.json`；
最终资源审计：`evidence/build_accepted_20261009T154403006936Z/summary.json`；完整验收依据：`doc/ACCEPTANCE.json`。
NTT回归是执行回执并附源码哈希，本轮全控制台输出未另存文件；前批基线全日志仍在原发布包。
主机核对程序已用单比特功能破坏验证严格拒绝；CRC、帧数、完成状态、计数与终止帧均校验。
当前结论：新增16核工程功能验收PASS；保留明确的UART接收阻塞及原4核全速失配。
