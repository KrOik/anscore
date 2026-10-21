# 通用产线 IP 系列，Tang Primer 25K

新增 **56 个独立功能核**，每核独立 RTL、规格、manifest、文件清单、
参考模型分支和自检 testbench。七组各八核：算术、位操作、编码、报文、
诊断、数据流、控制。目录见 [CATALOG](doc/CATALOG.md)，接口见
[INTERFACE](doc/INTERFACE.md)。这些核补充已有工程外设，可按需接到原有
UART/SPI/总线/算法流水线上。

用户最初指定 20K，随后根据 JTAG 实测确认改为 **25K**。
板级目标为 GW5A-LV25MG121NES / GW5A-25A，50 MHz，UART C3，115200 8N1。
预算沿用仓库硬门：每份验证镜像 LUT-class≤15000、DSP-class≤4、BSRAM≤46。
原 hybrid_lattice_ntt_20k 工程源码和 UART 期望值不作修改。

## 复现

从仓库根目录运行：

```powershell
python cores/system/utility_library/tools/generate.py
python cores/system/utility_library/tools/generate_board.py
python cores/system/utility_library/tools/model_selftest.py
python cores/system/utility_library/tools/verify.py --board --uart --integration --mutations
python cores/system/utility_library/tools/build.py --isolated
python cores/system/utility_library/tools/remote_board.py --build <完整build证据目录>
```

本地使用现有 OSS CAD Suite。远端 SSH 使用 `P25_PASSWORD`，或读取已有本地
`tools/_remote/sshrun.py` 的凭据；凭据不进入包或报告。JTAG 检测必须同时
匹配 GW5A-25 和 0x1281b。每组先检查镜像哈希和资源预算，再上传、校验远端
SHA256、在硬件锁下烧录 SRAM 并采集 UART。程序不会擦写 Flash。

## 验证设计

Python 模型使用独立整数/字符串/序列算法。期望值从模型生成，禁止从仿真
回填。逐核测试包含边界和种子固定的随机数据，三轮分别覆盖满速逻辑节拍、
随机背压/CE 暂停、取消待发响应后重放。每核还运行响应位错误注入，必须被
同一个原始测试拒绝。模型自检包括 CRC 固定校验值、BCD/LEB128/Gray 逆关系，
以及全部 256 个 SECDED 数据字的所有单比特和双比特翻转。

七份板级镜像逐核比较前 128 条独立模型向量，每组 1024 条；每个响应都比较
`result/aux/fault`，不是仅验证常量签名。每组还有错误注入仿真，必须报告
一个失败核。板端主动插入 0..3 个响应背压节拍，因此最大响应退休延迟为
4 个使能节拍，累计背压通常 1536 节拍，编码组因 BCD 两级流水为 1440。
UART 同时报告通过掩码、错误数、结果数、
实际结果滚动摘要、退休延迟和背压计数。

板级逻辑 CE=1/16，50 MHz 物理时钟对应 3.125 MHz 使能节拍。
此测试证明该节拍条件下的功能和握手；不能把它写成所有核 50 MHz 吞吐实测。
独立核无背压时的 RTL II=1 指一个使能节拍，物理频率需要单核时序约束验证。
仿真、综合、布局布线、上板状态分别保存，失败不能自动变成 PASS。

## 交付与使用边界

这是具有可复现证据的工程候选 IP 系列。源码不导入第三方 RTL；工具链是
外部构建依赖。`ip/<name>/manifest.json` 记录源码与向量 SHA256、接口、版本、
状态语义、模型位置、板级分组。使用一个核只需该核 `rtl/prod_<name>.v`，
验证 ROM、板级 UART 和参考模型不属于生产依赖。

本系列没有宣称安全认证、侧信道防护、专利新颖性或量产签核。功能核可以
作为项目内自有源码和后续知识产权材料的技术资产；原理算法和协议名称本身
不等同独占权。集成到产品前应完成目标频率/复位/时钟域/板级接口评审、
真实外设与长时间系统负载测试、所需形式验证，以及项目权属与许可证确认。
范围、验收状态与具体未关闭事项见最终 `doc/VALIDATION.md`。
