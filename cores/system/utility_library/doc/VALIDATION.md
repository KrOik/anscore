# 验证与交付记录

时间：2026-10-09T13:48:08.350517+00:00。新增56核；封装总量从129增至185。
目标：用户确认 Tang Primer 25K / GW5A-25，远端192.168.31.176。

**56/56 功能核独立仿真、错误注入拒绝、独立综合、8步边界SAT、板端验收全部通过。**
七组自检仿真及UART字节级仿真通过，附加APB适配层测试通过。板端逐笔比较
7168个响应，每组6帧UART一致，通过掩码FF，错误数0。

| 组 | LUT | FF | BSRAM | DSP | 路由 Fmax MHz | 板端结果数 | 摘要 |
|---|---:|---:|---:|---:|---:|---:|---|
| 0 | 2343 | 693 | 9 | 0 | 87.47 | 1024 | C2D31593 |
| 1 | 2587 | 609 | 9 | 0 | 133.44 | 1024 | BA9DD2D9 |
| 2 | 2667 | 560 | 8 | 0 | 86.45 | 1024 | 70E765EA |
| 3 | 2330 | 682 | 9 | 0 | 147.28 | 1024 | 76D06B3B |
| 4 | 2099 | 715 | 9 | 0 | 106.38 | 1024 | D3ECEDAC |
| 5 | 2503 | 915 | 8 | 0 | 70.72 | 1024 | 61329366 |
| 6 | 2748 | 817 | 9 | 0 | 87.72 | 1024 | B134C253 |

所有镜像以50MHz布局布线并通过时序，LUT≤15000、DSP≤4、BSRAM≤46。
板端功能/背压测试CE=1/16，使能节拍3.125MHz；不能由此宣称全速硬件吞吐。
单核II=1使能节拍，响应通常1使能节拍，BCD编码为2节拍。板端报告L=4为
包含主动响应背压的最大退休间隔，不是所有核的计算延迟。

原第一版BCD编码路径44.46MHz未通过50MHz门限。已改为两级弹性流水，独立
815LUT/73FF/0DSP，当前编码组时序通过。旧失败构建保留。
原构建报表没有识别GW5A的SPX9原语，错误报告BRAM=0；本次重新读取网表并与
nextpnr BSRAM逐组核对，正确值见表。旧报表保留，本记录及ACCEPTANCE.json
使用更正后的数据。

仿真证据：`evidence/sim_20261009T134109Z/summary.json`。
形式证据：`evidence/formal_20261009T134351Z/summary.json`，深度8，证明响应稳定/CE边界，
没有做不限深度、完整算术等价或安全证明。
构建证据：`evidence/build_20261009T133839Z/summary.json`。
远端证据：`evidence/board_20261009T134352Z/summary.json`，包含JTAG检测、上传哈希、烧录日志与
每组原始UART。当前板卡SRAM停留在第6组控制核镜像，未写Flash。

原ML-KEM/ML-DSA工程完整仿真回归已通过，记录在仓库
`artifacts/ip_expansion_20261009/baseline_sim.log`。既有源码、预期摘要、UART
字符串和基线日志均未修改；未重新烧录旧20K项目到25K。

## 具体边界

产出是可复用、有工程验收记录的IP候选系列，不是完成量产签核的整机。
通用算术/编码/报文微操作使用原生事务接口；完整物理接口控制器沿用既有IP。
APB模块单命令在途，只有本地仿真证据，未实例化到七份板级镜像中。
板端每核128条向量，仿真每核320条随机向量加边界/定向向量并运行3轮。
事件计数器饱和等极远状态目前只有模型边界校验，未用板端运行到该状态；
没有长时间老化、全温压角、实际产线外设联调、CDC/复位模拟时序或整机认证。
这些内容应按最终产品的集成约束关闭；不宣称专利新颖性或侧信道防护。

## 改动与命令

新增文件全部位于`cores/system/utility_library/`，另有基线和库存记录写入
`artifacts/ip_expansion_20261009/`。没有编辑原有RTL、共享脚本或用户改动。
关键命令均从仓库根运行：

```powershell
.\scripts\test_hybrid_lattice_ntt_sim.ps1
python cores/system/utility_library/tools/model_selftest.py
python cores/system/utility_library/tools/verify.py --board --uart --integration --mutations
python cores/system/utility_library/tools/build.py --isolated
python cores/system/utility_library/tools/build.py --isolated-core bcd8_encode
python cores/system/utility_library/tools/formal.py
python cores/system/utility_library/tools/remote_board.py --build cores/system/utility_library/evidence/build_20261009T133839Z
python cores/system/utility_library/tools/release.py
```

第一份全量独立综合保留55个未变核的当前资源数据；修订后的BCD核从第二份
综合提取。交付工具只接受与当前源码SHA256一致的记录，不能把旧结果混用。
最终判定：工程验收PASS，量产/专利/安全签核尚未作出。
